/*
 * RK3576 userspace C2H receiver and phase-1 LZ77 decoder.
 *
 * The FPGA C2H stream is exposed by the Anlogic driver as
 * /dev/ANLOGIC-PCI0_c2h_0. read(2) may return arbitrary fragments, therefore
 * this program keeps a byte accumulator and only commits a frame after the
 * LZ77 footer and its payload CRC have been checked.
 *
 * Build on RK3576:
 *   gcc -std=c11 -O2 -Wall -Wextra -pthread -o rk3576_lz77_rx rk3576_lz77_rx.c
 *
 * Test with a file instead of the device:
 *   ./rk3576_lz77_rx -d test_frame.lz77 -o decoded -n 1
 */
#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <pthread.h>
#include <stdatomic.h>

#define MAGIC "LZ77"
#define END_MAGIC "END!"
#define BLOCK_MAGIC 0x314b4c42u /* BLK1 in little-endian header reserved */
#define HEADER_SIZE 16u
#define FOOTER_SIZE 20u
#define MAX_FRAME (256u * 1024u * 1024u)
/* Keep requests at 4 KiB with the current synchronous ST C2H driver.
 * Board captures with the same 16 KiB-EOP bitstream lost payload/header
 * bytes at early-EOP completion with 64/16 KiB requests. The 4 KiB control
 * capture preserved both complete frames, including CRC and RGB24 geometry.
 * Larger requests need a driver completion-path fix and fresh validation.
 * FPGA packets may span several reads; do not weaken frame validation. */
#define READ_SIZE (4096u)
#define CAPTURE_LIMIT (1024u * 1024u)
#define RX_VERSION "lz77-rx-video-perf-20261009"
#define RX_FEATURES "rx-pipeline-20261016"
#define RX_OPTIMIZATIONS "rx-blk1-match-pipe-20261025"
#define RX_RING_CAPACITY (4u * 1024u * 1024u)
static volatile sig_atomic_t stop_signal;
static atomic_int pipeline_failed;

#include "rx_read_pipeline.h"

static void stop_handler(int signo)
{
    const char msg[] = "STOP requested; waiting for current read to return\n";
    stop_signal = signo;
    (void)write(STDERR_FILENO, msg, sizeof(msg)-1);
}

static double monotonic_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

typedef struct {
    uint16_t width, height;
    uint32_t flags, frame_id, raw_len, comp_len, tokens, crc32;
} lz77_meta_t;

typedef struct {
    uint64_t bytes_read, frames, crc_errors, format_errors, decode_errors;
    uint64_t raw_bytes, compressed_bytes;
    struct timeval start, end;
} rx_stats_t;

#include "rx_crc.h"

static int profile_enabled;
static double crc_seconds, decode_seconds, read_seconds, output_seconds;
static double assemble_seconds, output_wait_seconds;
static int scalar_match_copy;
static void report_profile(const rx_stats_t *s, double started)
{
    static double previous_time;
    static uint64_t previous_frames;
    double now = monotonic_s();
    double sec = now - started;
    double interval = now - (previous_time ? previous_time : started);
    double interval_fps = interval > 0 ? (s->frames - previous_frames)/interval : 0;
    double denom = s->frames ? (double)s->frames : 1.0;
    fprintf(stderr, "PERF frames=%" PRIu64 " fps=%.3f read_wait_ms=%.3f crc_ms=%.3f decode_ms=%.3f output_ms=%.3f compressed_MBps=%.3f interval_fps=%.3f assemble_ms=%.3f output_wait_ms=%.3f\n",
            s->frames, sec > 0 ? s->frames/sec : 0,
            1000*read_seconds/denom, 1000*crc_seconds/denom,
            1000*decode_seconds/denom, 1000*output_seconds/denom,
            sec > 0 ? s->compressed_bytes/sec/1e6 : 0, interval_fps,
            1000*assemble_seconds/denom, 1000*output_wait_seconds/denom);
    previous_time = now; previous_frames = s->frames;
}

static uint16_t rd16(const uint8_t *p)
{ return (uint16_t)p[0] | ((uint16_t)p[1] << 8); }
static uint32_t rd32(const uint8_t *p)
{ return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24); }

static int ensure_capacity(uint8_t **buf, size_t *cap, size_t need)
{
    size_t ncap;
    uint8_t *tmp;
    if (need <= *cap) return 0;
    if (need > MAX_FRAME) return -1;
    ncap = *cap ? *cap : (1u << 20);
    while (ncap < need) {
        if (ncap > MAX_FRAME / 2u) { ncap = MAX_FRAME; break; }
        ncap *= 2u;
    }
    tmp = (uint8_t *)realloc(*buf, ncap);
    if (!tmp) return -1;
    *buf = tmp; *cap = ncap;
    return 0;
}

static int find_magic(const uint8_t *p, size_t n)
{
    size_t i;
    if (n < 4) return -1;
    for (i = 0; i + 4 <= n; ++i)
        if (memcmp(p + i, MAGIC, 4) == 0) return (int)i;
    return -1;
}

/* Caller has checked distance against the current block and len against the
 * destination bound. An overlapping LZ match repeats the seed; memcpy alone
 * is invalid and memmove would not generate the newly repeated bytes. */
static void copy_match(uint8_t *dst, size_t distance, size_t len)
{
    if (scalar_match_copy) {
        for (size_t j=0;j<len;++j) dst[j]=dst[(ptrdiff_t)j-(ptrdiff_t)distance];
    } else if (distance==1) {
        memset(dst,dst[-1],len);
    } else if (distance>=len) {
        memcpy(dst,dst-distance,len);
    } else {
        memcpy(dst,dst-distance,distance);
        size_t copied=distance;
        while(copied<len) {
            size_t n=len-copied;
            if(n>copied) n=copied;
            memcpy(dst+copied,dst,n);
            copied+=n;
        }
    }
}

static void configure_output_pipe(size_t requested)
{
    struct stat info;
    if (fstat(STDOUT_FILENO,&info)<0 || !S_ISFIFO(info.st_mode)) return;
#if defined(F_SETPIPE_SZ) && defined(F_GETPIPE_SZ)
    int before=fcntl(STDOUT_FILENO,F_GETPIPE_SZ), after=before, code=0;
    /* Never shrink an existing pipe. Failure leaves the original pipe usable. */
    if(requested && before>=0 && requested>(size_t)before) {
        after=fcntl(STDOUT_FILENO,F_SETPIPE_SZ,(int)requested);
        if(after<0) {code=errno;after=before;}
    }
    fprintf(stderr,"PIPE_OUTPUT requested=%zu before=%d actual=%d resize_errno=%d\n",
            requested,before,after,code);
#else
    fprintf(stderr,"PIPE_OUTPUT requested=%zu resize=unsupported\n",requested);
#endif
}

static int parse_frame(const uint8_t *f, size_t n, lz77_meta_t *m,
                       uint8_t **raw_out, size_t *raw_capacity,
                       size_t *raw_n, int expect_rgb24)
{
    size_t payload_pos, payload_end, pos;
    uint8_t *raw;
    size_t out = 0, token_n = 0;
    uint32_t crc;
    double timer = 0;
    if (n < HEADER_SIZE + FOOTER_SIZE || memcmp(f, MAGIC, 4) != 0)
        return -1;
    if (memcmp(f + n - FOOTER_SIZE, END_MAGIC, 4) != 0)
        return -1;
    m->width = rd16(f + 4); m->height = rd16(f + 6);
    m->flags = rd32(f + 8);
    m->frame_id = rd32(f + 12);
    payload_pos = HEADER_SIZE;
    payload_end = n - FOOTER_SIZE;
    m->raw_len = rd32(f + payload_end + 4);
    m->comp_len = rd32(f + payload_end + 8);
    m->tokens = rd32(f + payload_end + 12);
    m->crc32 = rd32(f + payload_end + 16);
    if (expect_rgb24 && (!m->width || !m->height ||
        (uint64_t)m->width * m->height * 3u != m->raw_len)) {
        fprintf(stderr, "RGB24 length mismatch: %ux%u expected=%" PRIu64
                " footer_raw=%" PRIu32 " (frame boundary invalid)\n",
                m->width, m->height, (uint64_t)m->width * m->height * 3u,
                m->raw_len);
        return -4;
    }
    if (m->comp_len != payload_end - payload_pos || m->comp_len > MAX_FRAME)
        return -1;
    if (profile_enabled) timer = monotonic_s();
    crc = ~crc32_update(0xffffffffu, f + payload_pos, m->comp_len);
    if (profile_enabled) crc_seconds += monotonic_s() - timer;
    if (crc != m->crc32) return -2;
    if (m->raw_len > MAX_FRAME) return -1;
    if (profile_enabled) timer = monotonic_s();
    if (m->raw_len > *raw_capacity) {
        size_t capacity = *raw_capacity ? *raw_capacity : (1u << 20);
        while (capacity < m->raw_len) {
            if (capacity > MAX_FRAME / 2u) { capacity = MAX_FRAME; break; }
            capacity *= 2u;
        }
        raw = (uint8_t *)realloc(*raw_out, capacity ? capacity : 1u);
        if (!raw) return -3;
        *raw_out = raw;
        *raw_capacity = capacity;
    }
    raw = *raw_out;
    pos = payload_pos;
    if (m->flags == BLOCK_MAGIC) {
        while (pos < payload_end) {
            uint32_t block_raw, block_stored;
            uint8_t kind;
            if (payload_end - pos < 8) return -1;
            kind = f[pos];
            block_raw = (uint32_t)f[pos + 1] | ((uint32_t)f[pos + 2] << 8) |
                        ((uint32_t)f[pos + 3] << 16);
            block_stored = rd32(f + pos + 4);
            pos += 8;
            if (kind > 1 || !block_raw || block_stored > payload_end - pos)
                return -1;
            if (block_raw > m->raw_len - out) return -1;
            if (kind == 0) {
                if (block_stored != block_raw || out + block_raw > m->raw_len)
                    return -1;
                memcpy(raw + out, f + pos, block_raw);
                out += block_raw;
                pos += block_stored;
            } else {
                size_t block_end = pos + block_stored;
                size_t block_start = out, block_raw_end = out + block_raw;
                if (!block_stored || (block_stored & 1u) || block_stored >= block_raw)
                    return -1;
                while (pos < block_end) {
                    uint8_t control, value;
                    uint32_t len, distance;
                    if (block_end - pos < 2) return -1;
                    control = f[pos++]; value = f[pos++]; ++token_n;
                    if (control == 0) {
                        if (out >= block_raw_end) return -1;
                        raw[out++] = value;
                    } else if (control & 0x80u) {
                        len = control & 0x7fu; distance = value;
                        if (len < 3 || distance == 0 || distance > out - block_start ||
                            out + len > block_raw_end) return -1;
                        copy_match(raw+out,distance,len);
                        out+=len;
                    } else return -1;
                }
                if (out != block_raw_end) return -1;
            }
        }
    } else if (m->flags == 0) while (pos < payload_end) {
        uint8_t control, value;
        uint32_t len, distance;
        if (payload_end - pos < 2) return -1;
        control = f[pos++]; value = f[pos++]; ++token_n;
        if (control == 0) {
            if (out >= m->raw_len) return -1;
            raw[out++] = value;
        } else if (control & 0x80u) {
            len = control & 0x7fu; distance = value;
            if (len < 3 || distance == 0 || distance > out || out + len > m->raw_len) {
                return -1;
            }
            copy_match(raw+out,distance,len);
            out+=len;
        } else return -1;
    } else return -1;
    if (out != m->raw_len || token_n != m->tokens) return -1;
    if (profile_enabled) decode_seconds += monotonic_s() - timer;
    *raw_out = raw; *raw_n = out;
    return 0;
}

static int frame_complete(const uint8_t *f, size_t n, size_t *frame_len,
                          size_t *scan_pos, int expect_rgb24)
{
    size_t pos;
    if (n < HEADER_SIZE) return 0;
    if (memcmp(f, MAGIC, 4) != 0) return -1;
    if (expect_rgb24) {
        uint64_t raw = (uint64_t)rd16(f + 4) * rd16(f + 6) * 3u;
        if (!rd16(f + 4) || !rd16(f + 6) ||
            raw > (MAX_FRAME - HEADER_SIZE - FOOTER_SIZE) / 2u)
            return -4;
    }
    if (rd32(f + 8) == BLOCK_MAGIC) {
        /* Raw blocks may contain arbitrary END!/LZ77 bytes, even a forged
         * footer. Follow explicit block lengths; never search raw contents. */
        pos = *scan_pos;
        while (n - pos >= 8) {
            uint32_t block_raw, stored;
            if (memcmp(f + pos, END_MAGIC, 4) == 0) {
                if (n - pos < FOOTER_SIZE) break;
                if (rd32(f + pos + 8) != pos - HEADER_SIZE) return -1;
                *frame_len = pos + FOOTER_SIZE; return 1;
            }
            block_raw = (uint32_t)f[pos+1] | ((uint32_t)f[pos+2] << 8) |
                        ((uint32_t)f[pos+3] << 16);
            stored = rd32(f + pos + 4);
            if (f[pos] > 1 || !block_raw || !stored ||
                (f[pos] == 0 ? stored != block_raw :
                 ((stored & 1u) || stored >= block_raw)) ||
                stored > MAX_FRAME - HEADER_SIZE - FOOTER_SIZE - 8 ||
                pos > MAX_FRAME - 8 - stored) return -1;
            if (n - pos - 8 < stored) break;
            pos += 8 + stored;
        }
        *scan_pos = pos;
        return n > MAX_FRAME - READ_SIZE ? -1 : 0;
    }
    if (rd32(f + 8) != 0) return -1;
    /* Legacy tokens are aligned to two bytes. */
    for (pos = *scan_pos; pos + FOOTER_SIZE <= n;
         pos += 2) {
        if (memcmp(f + pos, END_MAGIC, 4) == 0) {
            uint32_t comp = rd32(f + pos + 8);
            if (comp == pos - HEADER_SIZE && comp <= MAX_FRAME) {
                *frame_len = pos + FOOTER_SIZE;
                return 1;
            }
        }
    }
    /* Resume here after the next short read; keep incomplete footers. */
    *scan_pos = pos;
    /* A literal costs two bytes, and a match expands to at least three.
     * A valid RGB24 payload can therefore never exceed 2 * width * height
     * * 3 bytes. Stop a missing-footer frame well before the old 256 MiB
     * accumulator limit. Check AFTER scanning so another complete frame
     * in the same DMA read is not included in this frame's size bound. */
    if (expect_rgb24 && n > HEADER_SIZE + FOOTER_SIZE +
        (uint64_t)rd16(f + 4) * rd16(f + 6) * 6u)
        return -4;
    return 0;
}

static int write_frame(const char *prefix, uint32_t id, const uint8_t *raw, size_t n)
{
    char path[512]; int fd; ssize_t w; size_t off = 0;
    if (!prefix) return 0;
    snprintf(path, sizeof(path), "%s_%06" PRIu32 ".bin", prefix, id);
    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { perror(path); return -1; }
    while (off < n) {
        w = write(fd, raw + off, n - off > (1u << 20) ? (1u << 20) : n - off);
        if (w < 0 && errno == EINTR) continue;
        if (w <= 0) { close(fd); return -1; }
        off += (size_t)w;
    }
    close(fd); return 0;
}

static double elapsed_s(const struct timeval *a, const struct timeval *b)
{ return (double)(b->tv_sec - a->tv_sec) + (double)(b->tv_usec - a->tv_usec) / 1e6; }

#include "rx_output_pipeline.h"

int main(int argc, char **argv)
{
    const char *device = "/dev/ANLOGIC-PCI0_c2h_0", *out_prefix = NULL;
    const char *capture_path = NULL;
    FILE *capture = NULL;
    rx_source_t source;
    int source_started = 0, pipeline_mode = -1, output_started=0;
    output_queue_t output;
    uint64_t submitted_frames=0;
    size_t captured = 0, scan_pos = HEADER_SIZE;
    uint64_t reads = 0, headers = 0, discarded = 0;
    int in_frame = 0, failed = 0;
    int expect_rgb24 = 0;
    int stdout_rgb24 = 0, test_crc = 0;
    const char *crc_mode = "auto";
    size_t pipe_bytes=1024u*1024u;
    FILE *log_output;
    struct stat device_stat;
    double report_at, profile_start = 0, profile_at = 0;
    struct sigaction sa;
    uint64_t want_frames = 0; int fd, i, verbose = 0, input_flags;
    uint8_t *acc = NULL, *read_buf = NULL, *raw_workspace = NULL;
    size_t acc_n = 0, acc_cap = 0, raw_capacity = 0;
    rx_stats_t st; memset(&st, 0, sizeof(st));
    for (i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "-d") && i + 1 < argc) device = argv[++i];
        else if (!strcmp(argv[i], "-o") && i + 1 < argc) out_prefix = argv[++i];
        else if (!strcmp(argv[i], "-n") && i + 1 < argc) want_frames = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "-v")) verbose = 1;
        else if (!strcmp(argv[i], "--capture") && i + 1 < argc) capture_path = argv[++i];
        else if (!strcmp(argv[i], "--expect-rgb24")) expect_rgb24 = 1;
        else if (!strcmp(argv[i], "--stdout-rgb24")) stdout_rgb24 = 1;
        else if (!strcmp(argv[i], "--profile")) profile_enabled = 1;
        else if (!strcmp(argv[i], "--pipeline")) pipeline_mode = 1;
        else if (!strcmp(argv[i], "--serial")) pipeline_mode = 0;
        else if (!strcmp(argv[i], "--crc") && i+1<argc) crc_mode=argv[++i];
        else if (!strcmp(argv[i], "--match-copy") && i+1<argc) {
            const char *mode=argv[++i];
            if(strcmp(mode,"fast") && strcmp(mode,"scalar")) {
                fprintf(stderr,"--match-copy must be fast or scalar\n");return 2;
            }
            scalar_match_copy=!strcmp(mode,"scalar");
        }
        else if (!strcmp(argv[i], "--pipe-bytes") && i+1<argc) {
            char *end;const char *value=argv[++i];errno=0;
            unsigned long n=strtoul(value,&end,10);
            if(errno || !*value || *value=='-' || *end || n>16u*1024u*1024u) {
                fprintf(stderr,"--pipe-bytes must be 0..16777216\n");return 2;
            }
            pipe_bytes=(size_t)n;
        }
        else if (!strcmp(argv[i], "--self-test-crc")) test_crc=1;
        else if (!strcmp(argv[i], "--version")) { puts(RX_VERSION); return 0; }
        else if (!strcmp(argv[i], "--build-info")) { puts(RX_FEATURES); return 0; }
        else if (!strcmp(argv[i], "--optimization-info")) { puts(RX_OPTIMIZATIONS);return 0; }
        else { fprintf(stderr, "usage: %s [-d device|file] [-o prefix] [-n frames] [-v] [--capture new-file] [--expect-rgb24] [--stdout-rgb24 (1920x1080)] [--profile] [--pipeline|--serial] [--crc auto|table|slice8|arm] [--match-copy fast|scalar] [--pipe-bytes 0..16777216] [--self-test-crc]\n", argv[0]); return 2; }
    }
    crc32_init();
    if (crc_select(crc_mode)<0) return 2;
    if (test_crc) return crc_self_test()!=0;
    log_output = stdout_rgb24 ? stderr : stdout;
    if (stdout_rgb24) { expect_rgb24 = 1; signal(SIGPIPE, SIG_IGN); }
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = stop_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    fprintf(stderr, "START %s device=%s read_size=%u (waiting for read)\n", RX_VERSION, device, READ_SIZE);
    /* Inspect input type BEFORE open: O_RDONLY | O_TRUNC truncates regular
     * files on Linux. O_TRUNC is only needed for the Anlogic streaming
     * C2H character device, whose driver uses it to enable EOP/TLAST flush.
     * Checking with fstat after an unconditional O_TRUNC is too late. */
    if (stat(device, &device_stat) < 0) {
        fprintf(stderr, "stat %s: %s\n", device, strerror(errno)); return 1;
    }
    input_flags = O_RDONLY | O_CLOEXEC;
    if (S_ISCHR(device_stat.st_mode)) input_flags |= O_TRUNC;
    fd = open(device, input_flags);
    if (fd < 0) { fprintf(stderr, "open %s: %s\n", device, strerror(errno)); return 1; }
    if (fstat(fd, &device_stat) < 0) {
        perror("fstat input"); close(fd); return 1;
    }
    /* Real camera captures are RGB24. Keep generic file-vector decoding
     * compatible with the small non-image protocol fixtures. */
    if (S_ISCHR(device_stat.st_mode)) expect_rgb24 = 1;
    fprintf(stderr, "INPUT expect_rgb24=%d\n", expect_rgb24);
    fprintf(stderr, "CRC backend=%s verification=full\n", crc_backend);
    fprintf(stderr, "FEATURES %s\n", RX_FEATURES);
    fprintf(stderr,"OPTIMIZATIONS %s match_copy=%s\n",RX_OPTIMIZATIONS,
            scalar_match_copy ? "scalar":"fast");
    fprintf(stderr, "PROTOCOL legacy,BLK1-lengths-20261017\n");
    if(stdout_rgb24) configure_output_pipe(pipe_bytes);
    /* SGDMA commonly requires a naturally aligned userspace buffer. */
    if (posix_memalign((void **)&read_buf, 4096, READ_SIZE) != 0) {
        fprintf(stderr, "cannot allocate aligned DMA read buffer\n");
        close(fd); return 1;
    }
    if (capture_path) {
        /* Never truncate an existing input, device, or earlier diagnostic. */
        int cfd = open(capture_path, O_WRONLY | O_CREAT | O_EXCL, 0644);
        if (cfd < 0) { perror(capture_path); close(fd); free(read_buf); return 1; }
        capture = fdopen(cfd, "wb");
        if (!capture) { perror("fdopen capture"); close(cfd); close(fd); free(read_buf); return 1; }
        setvbuf(capture, NULL, _IONBF, 0);
    }
    if (pipeline_mode == 1 || (pipeline_mode < 0 && S_ISCHR(device_stat.st_mode))) {
        if (rx_source_start(&source, fd) < 0) {
            fprintf(stderr, "cannot start bounded DMA/read pipeline\n");
            if (capture) fclose(capture);
            close(fd); free(read_buf); return 1;
        }
        source_started = 1;
    }
    if (source_started) {
        if (output_start(&output,&st,stdout_rgb24,out_prefix,verbose,log_output)<0) {
            perror("output pipeline");rx_source_stop(&source);
            if(capture) fclose(capture);
            free(read_buf);return 1;
        }
        output_started=1;
    }
    fprintf(stderr, "PIPELINE enabled=%d ring_bytes=%u raw_reuse=1\n", source_started, RX_RING_CAPACITY);
    gettimeofday(&st.start, NULL);
    report_at = monotonic_s();
    while (!stop_signal && !failed && !atomic_load(&pipeline_failed)) {
        double read_start = profile_enabled ? monotonic_s() : 0;
        const uint8_t *fragment = read_buf;
        ssize_t got = source_started ? rx_source_acquire(&source, &fragment)
                                     : read(fd, read_buf, READ_SIZE);
        if (profile_enabled && profile_start) read_seconds += monotonic_s() - read_start;
        size_t used = 0;
        if (got < 0 && (stop_signal || errno == EINTR)) continue;
        if (got < 0) { fprintf(stderr, "read %s: errno=%d %s\n", device, errno, strerror(errno)); failed=1; break; }
        if (got == 0) break;
        if (profile_enabled && !profile_start) {
            profile_start = monotonic_s(); profile_at = profile_start + 1.0;
        }
        ++reads;
        st.bytes_read += (uint64_t)got;
        if (capture && captured < CAPTURE_LIMIT) {
            size_t n = (size_t)got;
            if (n > CAPTURE_LIMIT-captured) n = CAPTURE_LIMIT-captured;
            if (fwrite(fragment, 1, n, capture) != n) { perror("capture write"); failed=1; break; }
            captured += n;
        }
        if (verbose && reads <= 8) {
            size_t k, n = (size_t)got < 32 ? (size_t)got : 32;
            fprintf(stderr, "READ %" PRIu64 " got=%zd first=", reads, got);
            for(k=0;k<n;++k) fprintf(stderr, "%02x%s", fragment[k], k+1==n ? "\n" : " ");
        }
        double assemble_start=profile_enabled ? monotonic_s():0;
        if (ensure_capacity(&acc, &acc_cap, acc_n + (size_t)got) < 0) { fprintf(stderr, "frame accumulator overflow\n"); failed=1; break; }
        memcpy(acc + acc_n, fragment, (size_t)got); acc_n += (size_t)got;
        if(profile_enabled) assemble_seconds+=monotonic_s()-assemble_start;
        if (source_started) rx_source_release(&source);
        while (used < acc_n) {
            int off = find_magic(acc + used, acc_n - used); size_t flen; int complete, rc;
            uint8_t *raw = raw_workspace; size_t raw_n = 0; lz77_meta_t m;
            if (off < 0) { if (acc_n - used > 3) { discarded += acc_n-used-3; used = acc_n - 3; } break; }
            discarded += (size_t)off;
            used += (size_t)off;
            if (!in_frame) {
                in_frame=1; ++headers; scan_pos=HEADER_SIZE;
                if(verbose) fprintf(stderr, "HEADER %" PRIu64 " offset=%" PRIu64 "\n", headers, st.bytes_read-(acc_n-used));
            }
            assemble_start=profile_enabled ? monotonic_s():0;
            complete = frame_complete(acc + used, acc_n - used, &flen, &scan_pos, expect_rgb24);
            if(profile_enabled) assemble_seconds+=monotonic_s()-assemble_start;
            if (complete < 0) {
                ++st.format_errors;
                fprintf(stderr, "invalid frame geometry or missing footer: buffered=%zu %ux%u\n",
                        acc_n-used, acc_n-used >= 8 ? rd16(acc+used+4) : 0,
                        acc_n-used >= 8 ? rd16(acc+used+6) : 0);
                failed=1; break;
            }
            if (!complete) break;
            output_frame_t *slot=NULL;
            size_t *capacity=&raw_capacity;
            if(output_started) {
                double wait_start=profile_enabled ? monotonic_s():0;
                slot=output_acquire(&output);
                if(profile_enabled) output_wait_seconds+=monotonic_s()-wait_start;
                if(!slot) {failed=!stop_signal;break;}
                raw=slot->raw;capacity=&slot->cap;
            }
            rc = parse_frame(acc + used, flen, &m, &raw, capacity,
                             &raw_n, expect_rgb24);
            if(slot) slot->raw=raw;
            else raw_workspace = raw;
            if (rc == -2) { ++st.crc_errors; fprintf(stderr, "frame CRC error at stream frame %" PRIu64 "\n", output_started ? output_frames(&output) : st.frames); if (stdout_rgb24) { failed=1; break; } }
            else if (rc == -4) { ++st.format_errors; failed=1; break; }
            else if (rc != 0) { ++st.decode_errors; fprintf(stderr, "frame format/decode error at stream frame %" PRIu64 "\n", output_started ? output_frames(&output) : st.frames); if (stdout_rgb24) { failed=1; break; } }
            else {
                if(output_started) {
                    if(stdout_rgb24 && (m.width!=1920 || m.height!=1080)) {
                        fprintf(stderr,"Video output requires 1920x1080 RGB24\n");
                        ++st.format_errors;failed=1;break;
                    }
                    output_submit(&output,slot,&m,raw_n);
                    ++submitted_frames;
                } else {
                if (stdout_rgb24) {
                    size_t sent = 0;
                    double output_start = profile_enabled ? monotonic_s() : 0;
                    if (m.width != 1920 || m.height != 1080) {
                        fprintf(stderr, "Video output requires 1920x1080 RGB24\n");
                        ++st.format_errors; failed=1; break;
                    }
                    while (sent < raw_n && !stop_signal) {
                        ssize_t w = write(STDOUT_FILENO, raw + sent, raw_n - sent);
                        if (w < 0 && errno == EINTR) continue;
                        if (w <= 0) { perror("RGB24 output"); failed=1; break; }
                        sent += (size_t)w;
                    }
                    if (profile_enabled) output_seconds += monotonic_s() - output_start;
                    if (failed || stop_signal) break;
                }
                if (write_frame(out_prefix, m.frame_id, raw, raw_n) < 0) { failed=1; break; }
                ++st.frames; st.raw_bytes += raw_n; st.compressed_bytes += m.comp_len;
                if (verbose) fprintf(log_output, "frame=%" PRIu32 " %ux%u raw=%" PRIu32 " compressed=%" PRIu32 " tokens=%" PRIu32 " crc=%08" PRIx32 "\n", m.frame_id, m.width, m.height, m.raw_len, m.comp_len, m.tokens, m.crc32);
                }
                if (profile_enabled && monotonic_s() >= profile_at) {
                    if(output_started) output_profile(&output,&st,profile_start);
                    else report_profile(&st, profile_start);
                    if(source_started) rx_source_profile(&source);
                    profile_at = monotonic_s() + 1.0;
                }
                if (want_frames && (output_started ? submitted_frames : st.frames) >= want_frames) { used = acc_n; break; }
            }
            used += flen;
            in_frame=0; scan_pos=HEADER_SIZE;
        }
        if (used) { memmove(acc, acc + used, acc_n - used); acc_n -= used; }
        if (verbose && (reads==1 || monotonic_s() >= report_at)) {
            fprintf(stderr, "PROGRESS reads=%" PRIu64 " bytes_read=%" PRIu64 " headers=%" PRIu64
                    " discarded=%" PRIu64 " buffered=%zu state=%s frames=%" PRIu64 "\n",
                    reads, st.bytes_read, headers, discarded, acc_n,
                    in_frame ? "WAIT_FOOTER" : "SEEK_HEADER", output_started ? output_frames(&output) : st.frames);
            report_at=monotonic_s()+1.0;
        }
        if (want_frames && (output_started ? submitted_frames : st.frames) >= want_frames) break;
    }
    if(output_started) output_stop(&output,failed || stop_signal || atomic_load(&pipeline_failed));
    if(atomic_load(&pipeline_failed)) failed=1;
    gettimeofday(&st.end, NULL);
    if (profile_enabled && profile_start) {
        report_profile(&st, profile_start);
        if(source_started) rx_source_profile(&source);
    }
    if (source_started) rx_source_stop(&source);
    else close(fd);
    free(read_buf); free(acc); free(raw_workspace);
    if (capture && fclose(capture) != 0) { perror("capture close"); failed=1; }
    fprintf(stderr, "END reads=%" PRIu64 " headers=%" PRIu64 " discarded=%" PRIu64
            " buffered=%zu captured=%zu stop_signal=%d\n", reads, headers, discarded, acc_n, captured, (int)stop_signal);
    {
        double sec = elapsed_s(&st.start, &st.end);
        double ratio = st.raw_bytes ? (double)st.compressed_bytes / (double)st.raw_bytes : 0.0;
        fprintf(log_output, "frames=%" PRIu64 " bytes_read=%" PRIu64 " raw=%" PRIu64 " compressed=%" PRIu64 " compression_ratio=%.6f crc_errors=%" PRIu64 " decode_errors=%" PRIu64 " format_errors=%" PRIu64 " elapsed_s=%.6f fps=%.3f\n", st.frames, st.bytes_read, st.raw_bytes, st.compressed_bytes, ratio, st.crc_errors, st.decode_errors, st.format_errors, sec, sec > 0 ? st.frames / sec : 0.0);
    }
    if (stop_signal) return 128 + stop_signal;
    return (failed || !st.frames || (want_frames && st.frames < want_frames) ||
            acc_n || st.crc_errors || st.decode_errors || st.format_errors) ? 1 : 0;
}
