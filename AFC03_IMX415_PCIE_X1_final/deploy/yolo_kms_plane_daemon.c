#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#include <drm.h>
#include <drm_fourcc.h>
#include <drm_mode.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

static volatile sig_atomic_t stopping;

static void stop_handler(int signo)
{
    (void)signo;
    stopping = 1;
}

static uint32_t find_prop(int fd, uint32_t object, uint32_t type, const char *name)
{
    drmModeObjectPropertiesPtr props = drmModeObjectGetProperties(fd, object, type);
    if (!props) return 0;
    uint32_t result = 0;
    for (uint32_t i = 0; i < props->count_props && !result; ++i) {
        drmModePropertyPtr p = drmModeGetProperty(fd, props->props[i]);
        if (p) {
            if (!strcmp(p->name, name)) result = p->prop_id;
            drmModeFreeProperty(p);
        }
    }
    drmModeFreeObjectProperties(props);
    return result;
}

static int add(drmModeAtomicReqPtr req, int fd, uint32_t plane,
               const char *name, uint64_t value)
{
    uint32_t id = find_prop(fd, plane, DRM_MODE_OBJECT_PLANE, name);
    if (!id) {
        fprintf(stderr, "missing plane property: %s\n", name);
        return -1;
    }
    return drmModeAtomicAddProperty(req, plane, id, value) < 0 ? -1 : 0;
}

static int set_plane(int fd, uint32_t plane, uint32_t crtc, uint32_t fb,
                     uint32_t width, uint32_t height, int enabled)
{
    drmModeAtomicReqPtr req = drmModeAtomicAlloc();
    if (!req) return -1;
    int bad;
    if (!enabled) {
        bad = add(req, fd, plane, "FB_ID", 0) || add(req, fd, plane, "CRTC_ID", 0);
    } else {
        bad = add(req, fd, plane, "FB_ID", fb) ||
              add(req, fd, plane, "CRTC_ID", crtc) ||
              add(req, fd, plane, "SRC_X", 0) || add(req, fd, plane, "SRC_Y", 0) ||
              add(req, fd, plane, "SRC_W", (uint64_t)width << 16) ||
              add(req, fd, plane, "SRC_H", (uint64_t)height << 16) ||
              add(req, fd, plane, "CRTC_X", 0) || add(req, fd, plane, "CRTC_Y", 0) ||
              add(req, fd, plane, "CRTC_W", width) || add(req, fd, plane, "CRTC_H", height) ||
              add(req, fd, plane, "alpha", 65535) ||
              add(req, fd, plane, "pixel blend mode", 0) ||
              add(req, fd, plane, "zpos", 2);
    }
    int rc = bad ? -1 : drmModeAtomicCommit(fd, req, 0, NULL);
    drmModeAtomicFree(req);
    return rc;
}

static int read_frame(int fd, void *dst, size_t size)
{
    uint8_t *p = dst;
    size_t done = 0;
    while (done < size) {
        ssize_t n = read(fd, p + done, size - done);
        if (n == 0) return done == 0 ? 0 : -2;
        if (n < 0) {
            if (errno == EINTR && stopping) return 0;
            if (errno == EINTR) continue;
            return -1;
        }
        done += (size_t)n;
    }
    return 1;
}

int main(int argc, char **argv)
{
    const char *device = argc > 1 ? argv[1] : "/dev/dri/card0";
    uint32_t connector_id = argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 0) : 188;
    uint32_t plane_id = argc > 3 ? (uint32_t)strtoul(argv[3], NULL, 0) : 108;
    const uint32_t width = 1280, height = 800;
    int fd = -1, exit_code = 1, active = 0;
    drmModeResPtr resources = NULL;
    drmModeConnectorPtr connector = NULL;
    drmModePlanePtr plane = NULL;
    drmModePlaneResPtr planes = NULL;
    uint32_t crtc_id = 0, crtc_index = UINT32_MAX;
    struct drm_mode_create_dumb create = {0};
    struct drm_mode_map_dumb map_req;
    struct drm_mode_destroy_dumb destroy;
    uint32_t fb = 0, handle = 0, pitch = 0;
    void *map = MAP_FAILED;
    uint8_t *row = NULL;
    unsigned allocated = 0, updates = 0;

    struct sigaction sa = {0};
    sa.sa_handler = stop_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    fd = open(device, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open DRM card"); goto done; }
    if (drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1) ||
        drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1)) {
        fprintf(stderr, "DRM atomic/universal planes unavailable: %s\n", strerror(errno));
        goto done;
    }
    resources = drmModeGetResources(fd);
    connector = drmModeGetConnector(fd, connector_id);
    if (!resources || !connector || connector->connection != DRM_MODE_CONNECTED || !connector->encoder_id) {
        fprintf(stderr, "connector %u not active\n", connector_id); goto done;
    }
    drmModeEncoderPtr enc = drmModeGetEncoder(fd, connector->encoder_id);
    if (enc) { crtc_id = enc->crtc_id; drmModeFreeEncoder(enc); }
    for (int i = 0; i < resources->count_crtcs; ++i)
        if (resources->crtcs[i] == crtc_id) crtc_index = (uint32_t)i;
    if (!crtc_id || crtc_index == UINT32_MAX) { fprintf(stderr, "connector has no active CRTC\n"); goto done; }
    planes = drmModeGetPlaneResources(fd);
    if (!planes) { perror("get planes"); goto done; }
    plane = drmModeGetPlane(fd, plane_id);
    if (!plane || !(plane->possible_crtcs & (1u << crtc_index))) {
        fprintf(stderr, "plane %u cannot use CRTC %u\n", plane_id, crtc_id); goto done;
    }
    int argb = 0;
    for (uint32_t i = 0; i < plane->count_formats; ++i)
        if (plane->formats[i] == DRM_FORMAT_ARGB8888) argb = 1;
    if (!argb) { fprintf(stderr, "plane lacks ARGB8888\n"); goto done; }

    create.width = width; create.height = height; create.bpp = 32;
    if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &create)) { perror("create dumb fb"); goto done; }
    allocated++;
    handle = create.handle; pitch = create.pitch;
    if (pitch != width * 4) {
        fprintf(stderr, "unsupported dumb framebuffer pitch=%u expected=%u\n",
                pitch, width * 4);
        goto done;
    }
    memset(&map_req, 0, sizeof(map_req)); map_req.handle = handle;
    if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &map_req)) { perror("map dumb fb"); goto done; }
    map = mmap(NULL, create.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, map_req.offset);
    if (map == MAP_FAILED) { perror("mmap dumb fb"); goto done; }
    memset(map, 0, create.size);
    uint32_t handles[4] = {handle,0,0,0}, pitches[4] = {pitch,0,0,0}, offsets[4] = {0,0,0,0};
    if (drmModeAddFB2(fd, width, height, DRM_FORMAT_ARGB8888, handles, pitches, offsets, &fb, 0)) {
        perror("add framebuffer"); goto done;
    }
    if (set_plane(fd, plane_id, crtc_id, fb, width, height, 1)) {
        fprintf(stderr, "initial atomic plane enable failed: %s\n", strerror(errno)); goto done;
    }
    active = 1;
    row = malloc((size_t)width * 4);
    if (!row) { perror("malloc patch row"); goto done; }
    fprintf(stderr, "KMS_PLANE_READY connector=%u crtc=%u plane=%u size=%ux%u single_scanout=1 patch_updates=1\n",
            connector_id, crtc_id, plane_id, width, height);

    while (!stopping) {
        uint32_t patch[4];
        int rr = read_frame(STDIN_FILENO, patch, sizeof(patch));
        if (rr == 0) { exit_code = 0; break; }
        if (rr < 0) { fprintf(stderr, "overlay patch header read failed (%d)\n", rr); goto done; }
        uint32_t x = patch[0], y = patch[1], w = patch[2], h = patch[3];
        if (!w || !h || x >= width || y >= height || w > width - x || h > height - y) {
            fprintf(stderr, "invalid overlay patch x=%u y=%u w=%u h=%u\n", x, y, w, h); goto done;
        }
        size_t row_bytes = (size_t)w * 4;
        for (uint32_t yy = 0; yy < h; ++yy) {
            rr = read_frame(STDIN_FILENO, row, row_bytes);
            if (rr != 1) { fprintf(stderr, "overlay patch data read failed (%d)\n", rr); goto done; }
            memcpy((uint8_t *)map + (size_t)(y + yy) * pitch + (size_t)x * 4,
                   row, row_bytes);
        }
        __sync_synchronize();
        updates++;
    }
    fprintf(stderr, "KMS_PLANE_STOP updates=%u atomic_updates=0\n", updates);
    exit_code = 0;

done:
    if (active && fd >= 0 && set_plane(fd, plane_id, crtc_id, 0, width, height, 0))
        fprintf(stderr, "overlay plane cleanup failed: %s\n", strerror(errno));
    if (fb && fd >= 0) drmModeRmFB(fd, fb);
    if (map != MAP_FAILED) munmap(map, create.size);
    free(row);
    if (allocated && fd >= 0) {
        memset(&destroy, 0, sizeof(destroy)); destroy.handle = handle;
        drmIoctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
    }
    if (plane) drmModeFreePlane(plane);
    if (planes) drmModeFreePlaneResources(planes);
    if (connector) drmModeFreeConnector(connector);
    if (resources) drmModeFreeResources(resources);
    if (fd >= 0) close(fd);
    return exit_code;
}
