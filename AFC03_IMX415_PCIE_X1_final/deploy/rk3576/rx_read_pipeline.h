/* One DMA read fills one aligned slot directly. The consumer borrows the
 * tail until release; no producer-to-ring or ring-to-consumer memcpy. */
#define RX_RING_SLOTS (RX_RING_CAPACITY / READ_SIZE)
typedef struct {
    int fd, eof, error_code, stop;
    uint8_t *ring;
    size_t lengths[RX_RING_SLOTS];
    size_t head, tail, used, high_water;
    double dma_seconds, dma_first_seconds, full_wait_seconds;
    double report_time;
    uint64_t dma_reads, dma_bytes, report_bytes;
    pthread_t thread;
    pthread_mutex_t lock;
    pthread_cond_t can_read, can_write;
} rx_source_t;

static void queue_wait(pthread_cond_t *cond, pthread_mutex_t *lock)
{
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_nsec += 100000000;
    if (deadline.tv_nsec >= 1000000000) {
        ++deadline.tv_sec; deadline.tv_nsec -= 1000000000;
    }
    (void)pthread_cond_timedwait(cond, lock, &deadline);
}

static void *rx_source_thread(void *arg)
{
    rx_source_t *s = arg;
    /* All queue locks and shared-buffer updates are cancellation-disabled.
     * Only read() may be cancelled, with no lock held. */
    pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
    for (;;) {
        pthread_mutex_lock(&s->lock);
        struct timespec wait_a,wait_b;
        int was_full=s->used==RX_RING_SLOTS;
        if(was_full) clock_gettime(CLOCK_MONOTONIC,&wait_a);
        while (s->used == RX_RING_SLOTS && !s->stop && !stop_signal && !atomic_load(&pipeline_failed))
            queue_wait(&s->can_write, &s->lock);
        if(was_full) {
            clock_gettime(CLOCK_MONOTONIC,&wait_b);
            s->full_wait_seconds+=(wait_b.tv_sec-wait_a.tv_sec)+
                                 (wait_b.tv_nsec-wait_a.tv_nsec)/1e9;
        }
        if (s->stop || stop_signal || atomic_load(&pipeline_failed)) {
            s->eof = 1; pthread_cond_broadcast(&s->can_read);
            pthread_mutex_unlock(&s->lock); break;
        }
        size_t index = s->head;
        pthread_mutex_unlock(&s->lock);
        struct timespec a, b;
        clock_gettime(CLOCK_MONOTONIC, &a);
        pthread_setcancelstate(PTHREAD_CANCEL_ENABLE, NULL);
        ssize_t got = read(s->fd, s->ring + index * READ_SIZE, READ_SIZE);
        int code = errno;
        pthread_setcancelstate(PTHREAD_CANCEL_DISABLE, NULL);
        clock_gettime(CLOCK_MONOTONIC, &b);
        pthread_mutex_lock(&s->lock);
        double elapsed=(b.tv_sec-a.tv_sec)+(b.tv_nsec-a.tv_nsec)/1e9;
        s->dma_seconds+=elapsed;
        if (got > 0 && got <= READ_SIZE) {
            s->lengths[index] = (size_t)got;
            s->head = (index + 1) % RX_RING_SLOTS;
            ++s->used; ++s->dma_reads;s->dma_bytes+=(size_t)got;
            if(s->dma_reads==1) s->dma_first_seconds=elapsed;
            if (s->used > s->high_water) s->high_water = s->used;
        } else if (got < 0 && code == EINTR && !s->stop && !stop_signal) {
            pthread_mutex_unlock(&s->lock); continue;
        } else {
            s->eof = 1;
            if (got < 0 && !stop_signal) s->error_code = code;
            if (got > READ_SIZE) s->error_code = EIO;
        }
        pthread_cond_broadcast(&s->can_read);
        int done = s->eof;
        pthread_mutex_unlock(&s->lock);
        if (done) break;
    }
    return NULL;
}

static int rx_source_start(rx_source_t *s, int fd)
{
    int rc;
    memset(s, 0, sizeof(*s)); s->fd = fd;
    if ((rc=posix_memalign((void **)&s->ring, 4096, RX_RING_CAPACITY)) != 0) {
        errno=rc; return -1;
    }
    if ((rc=pthread_mutex_init(&s->lock, NULL)) != 0) goto free_ring;
    if ((rc=pthread_cond_init(&s->can_read, NULL)) != 0) goto free_lock;
    if ((rc=pthread_cond_init(&s->can_write, NULL)) != 0) goto free_read_cond;
    if ((rc=pthread_create(&s->thread, NULL, rx_source_thread, s)) == 0) return 0;
    pthread_cond_destroy(&s->can_write);
free_read_cond:
    pthread_cond_destroy(&s->can_read);
free_lock:
    pthread_mutex_destroy(&s->lock);
free_ring:
    free(s->ring); s->ring=NULL; errno=rc; return -1;
}

static ssize_t rx_source_acquire(rx_source_t *s, const uint8_t **data)
{
    pthread_mutex_lock(&s->lock);
    while (!s->used && !s->eof && !s->stop && !stop_signal && !atomic_load(&pipeline_failed))
        queue_wait(&s->can_read, &s->lock);
    if (stop_signal || atomic_load(&pipeline_failed) || !s->used) {
        int code = s->error_code;
        pthread_mutex_unlock(&s->lock);
        if (code) { errno=code; return -1; }
        return 0;
    }
    *data = s->ring + s->tail * READ_SIZE;
    size_t n=s->lengths[s->tail];
    pthread_mutex_unlock(&s->lock);
    return (ssize_t)n;
}

static void rx_source_release(rx_source_t *s)
{
    pthread_mutex_lock(&s->lock);
    s->tail=(s->tail+1)%RX_RING_SLOTS; --s->used;
    pthread_cond_signal(&s->can_write);
    pthread_mutex_unlock(&s->lock);
}

static void rx_source_profile(rx_source_t *s)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC,&ts);
    double now=ts.tv_sec+ts.tv_nsec/1e9;
    pthread_mutex_lock(&s->lock);
    uint64_t reads=s->dma_reads,bytes=s->dma_bytes,previous=s->report_bytes;
    double dma=s->dma_seconds,first=s->dma_first_seconds,wait=s->full_wait_seconds;
    double interval=s->report_time ? now-s->report_time:0;
    size_t used=s->used,high=s->high_water;
    s->report_time=now;s->report_bytes=bytes;
    pthread_mutex_unlock(&s->lock);
    fprintf(stderr,"PERF_DMA reads=%" PRIu64 " bytes=%" PRIu64
            " read_avg_us=%.3f first_read_ms=%.3f ring_full_wait_s=%.6f"
            " ring_used=%zu/%u ring_high_water=%zu interval_MBps=%.3f\n",
            reads,bytes,reads>1 ? 1e6*(dma-first)/(reads-1):0,first*1000,
            wait,used,RX_RING_SLOTS,high,interval>0 ? (bytes-previous)/interval/1e6:0);
}

static void rx_source_stop(rx_source_t *s)
{
    pthread_mutex_lock(&s->lock); s->stop=1;
    pthread_cond_broadcast(&s->can_write); pthread_cond_broadcast(&s->can_read);
    pthread_mutex_unlock(&s->lock);
    pthread_cancel(s->thread);
    pthread_join(s->thread, NULL);
    /* Join before close/free: a blocked read can hold its own fd reference. */
    close(s->fd);
    fprintf(stderr, "PIPELINE_READ dma_reads=%" PRIu64
            " dma_read_s=%.6f ring_high_water=%zu/%u\n",
            s->dma_reads, s->dma_seconds, s->high_water, RX_RING_SLOTS);
    pthread_cond_destroy(&s->can_read); pthread_cond_destroy(&s->can_write);
    pthread_mutex_destroy(&s->lock); free(s->ring); s->ring=NULL;
}
