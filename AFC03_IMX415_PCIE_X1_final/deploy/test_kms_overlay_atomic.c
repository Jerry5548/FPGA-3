#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/mman.h>
#include <unistd.h>

#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm.h>
#include <drm_mode.h>
#include <drm_fourcc.h>

static volatile sig_atomic_t stop_requested;

static void stop_handler(int signo)
{
    (void)signo;
    stop_requested = 1;
}

static uint64_t monotonic_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static uint32_t property_id(int fd, uint32_t object, uint32_t type,
                            const char *name, uint64_t *value)
{
    drmModeObjectPropertiesPtr props = drmModeObjectGetProperties(fd, object, type);
    uint32_t id = 0;
    if (!props)
        return 0;
    for (uint32_t i = 0; i < props->count_props; ++i) {
        drmModePropertyPtr prop = drmModeGetProperty(fd, props->props[i]);
        if (!prop)
            continue;
        if (strcmp(prop->name, name) == 0) {
            id = prop->prop_id;
            if (value)
                *value = props->prop_values[i];
        }
        drmModeFreeProperty(prop);
        if (id)
            break;
    }
    drmModeFreeObjectProperties(props);
    return id;
}

static int add_prop(drmModeAtomicReqPtr req, int fd, uint32_t plane,
                    const char *name, uint64_t value, int required)
{
    uint32_t id = property_id(fd, plane, DRM_MODE_OBJECT_PLANE, name, NULL);
    if (!id) {
        fprintf(stderr, "%s: missing plane property %s\n",
                required ? "FAIL" : "INFO", name);
        return required ? -1 : 0;
    }
    if (drmModeAtomicAddProperty(req, plane, id, value) < 0) {
        fprintf(stderr, "FAIL: add property %s: %s\n", name, strerror(errno));
        return -1;
    }
    return 0;
}

static int test_format(drmModePlanePtr plane, uint32_t format)
{
    for (uint32_t i = 0; i < plane->count_formats; ++i)
        if (plane->formats[i] == format)
            return 1;
    return 0;
}

static int add_plane_state(drmModeAtomicReqPtr req, int fd, uint32_t plane,
                           uint32_t crtc, uint32_t fb, uint32_t x, uint32_t y,
                           uint32_t width, uint32_t height)
{
    return add_prop(req, fd, plane, "CRTC_ID", crtc, 1) ||
           add_prop(req, fd, plane, "FB_ID", fb, 1) ||
           add_prop(req, fd, plane, "SRC_X", 0, 1) ||
           add_prop(req, fd, plane, "SRC_Y", 0, 1) ||
           add_prop(req, fd, plane, "SRC_W", (uint64_t)width << 16, 1) ||
           add_prop(req, fd, plane, "SRC_H", (uint64_t)height << 16, 1) ||
           add_prop(req, fd, plane, "CRTC_X", x, 1) ||
           add_prop(req, fd, plane, "CRTC_Y", y, 1) ||
           add_prop(req, fd, plane, "CRTC_W", width, 1) ||
           add_prop(req, fd, plane, "CRTC_H", height, 1) ||
           add_prop(req, fd, plane, "alpha", 65535, 1) ||
           add_prop(req, fd, plane, "pixel blend mode", 0, 1) ||
           add_prop(req, fd, plane, "zpos", 2, 1);
}

struct saved_plane_properties {
    uint64_t alpha;
    uint64_t blend;
    uint64_t zpos;
};

static int disable_plane(int fd, uint32_t plane,
                         const struct saved_plane_properties *saved)
{
    drmModeAtomicReqPtr req = drmModeAtomicAlloc();
    if (!req)
        return -1;
    int failed = add_prop(req, fd, plane, "FB_ID", 0, 1) ||
                 add_prop(req, fd, plane, "CRTC_ID", 0, 1) ||
                 add_prop(req, fd, plane, "alpha", saved->alpha, 1) ||
                 add_prop(req, fd, plane, "pixel blend mode", saved->blend, 1) ||
                 add_prop(req, fd, plane, "zpos", saved->zpos, 1);
    int result = failed ? -1 : drmModeAtomicCommit(fd, req, 0, NULL);
    drmModeAtomicFree(req);
    return result;
}

static int run_display_test(int fd, uint32_t plane, uint32_t crtc, uint32_t fb,
                            void *pixels, uint32_t pitch, uint32_t width,
                            uint32_t height, unsigned seconds,
                            const struct saved_plane_properties *saved)
{
    struct sigaction action = {0};
    action.sa_handler = stop_handler;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGTERM, &action, NULL);
    memset(pixels, 0, (size_t)pitch * height);
    for (uint32_t y = 0; y < height; ++y) {
        uint8_t *row = (uint8_t *)pixels + (size_t)y * pitch;
        for (uint32_t x = 0; x < width; ++x) {
            if (x < 3 || y < 3 || x >= width - 3 || y >= height - 3) {
                uint8_t *px = row + (size_t)x * 4;
                px[0] = 0; px[1] = 255; px[2] = 0; px[3] = 255;
            }
        }
    }
    fprintf(stderr, "DISPLAY_TEST: showing a green %ux%u box on plane %u for at most %u seconds; Ctrl+C also cleans up\n",
            width, height, plane, seconds);
    const uint64_t start_ns = monotonic_ns();
    const uint64_t deadline_ns = start_ns + (uint64_t)seconds * 1000000000ull;
    unsigned commits = 0;
    int failed = 0;
    uint64_t commit_total_ns = 0, commit_max_ns = 0;
    while (!stop_requested && monotonic_ns() < deadline_ns) {
        uint32_t x = 48 + ((commits & 1u) ? 24u : 0u);
        drmModeAtomicReqPtr req = drmModeAtomicAlloc();
        if (!req || add_plane_state(req, fd, plane, crtc, fb, x, 48, width, height)) {
            if (req) drmModeAtomicFree(req);
            failed = 1;
            break;
        }
        uint64_t commit_start_ns = monotonic_ns();
        if (drmModeAtomicCommit(fd, req, 0, NULL) != 0) {
            fprintf(stderr, "FAIL: active atomic commit %u: %s (%d)\n",
                    commits, strerror(errno), errno);
            drmModeAtomicFree(req);
            failed = 1;
            break;
        }
        uint64_t commit_ns = monotonic_ns() - commit_start_ns;
        drmModeAtomicFree(req);
        commit_total_ns += commit_ns;
        if (commit_ns > commit_max_ns)
            commit_max_ns = commit_ns;
        ++commits;
    }
    uint64_t elapsed_ns = monotonic_ns() - start_ns;
    double elapsed_ms = (double)elapsed_ns / 1e6;
    double update_hz = elapsed_ns ? (double)commits * 1e9 / (double)elapsed_ns : 0.0;
    double commit_avg_ms = commits ? (double)commit_total_ns / (double)commits / 1e6 : 0.0;
    if (disable_plane(fd, plane, saved) != 0) {
        fprintf(stderr, "FAIL: could not disable test plane %u and restore its properties: %s (%d)\n",
                plane, strerror(errno), errno);
        failed = 1;
    } else {
        fprintf(stderr, "DISPLAY_TEST: plane %u disabled; active_updates=%u elapsed_ms=%.1f update_hz=%.2f commit_avg_ms=%.2f commit_max_ms=%.2f\n",
                plane, commits, elapsed_ms, update_hz, commit_avg_ms,
                (double)commit_max_ns / 1e6);
    }
    return failed || commits == 0 ? -1 : 0;
}

int main(int argc, char **argv)
{
    const char *device = argc > 1 ? argv[1] : "/dev/dri/card0";
    uint32_t connector_id = argc > 2 ? (uint32_t)strtoul(argv[2], NULL, 0) : 188;
    uint32_t candidate_id = argc > 3 ? (uint32_t)strtoul(argv[3], NULL, 0) : 108;
    unsigned display_seconds = argc > 4 ? (unsigned)strtoul(argv[4], NULL, 0) : 0;
    const uint32_t tile_w = 64, tile_h = 64;
    int fd = -1, rc = 1, fb_added = 0, dumb_created = 0;
    void *map = MAP_FAILED;
    uint32_t fb_id = 0, handle = 0;
    struct drm_mode_create_dumb create = {0};
    struct drm_mode_map_dumb map_req = {0};
    struct drm_mode_destroy_dumb destroy = {0};
    drmModeAtomicReqPtr req = NULL;
    drmModeResPtr resources = NULL;
    drmModeConnectorPtr connector = NULL;
    drmModeCrtcPtr crtc = NULL;
    drmModePlaneResPtr plane_resources = NULL;
    drmModePlanePtr candidate = NULL;
    uint32_t crtc_id = 0, active_fb = 0, current_plane = 0;
    uint32_t crtc_index = UINT32_MAX;
    struct saved_plane_properties saved = {0};

    if (argc > 5 || display_seconds > 10) {
        fprintf(stderr, "Usage: %s [DRM_CARD [CONNECTOR_ID [PLANE_ID [DISPLAY_SECONDS 0..10]]]]\n", argv[0]);
        return 2;
    }
    fd = open(device, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "FAIL: open %s: %s\n", device, strerror(errno));
        goto out;
    }
    if (drmSetClientCap(fd, DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1) != 0 ||
        drmSetClientCap(fd, DRM_CLIENT_CAP_ATOMIC, 1) != 0) {
        fprintf(stderr, "FAIL: DRM atomic/universal plane capability unavailable: %s\n",
                strerror(errno));
        goto out;
    }
    resources = drmModeGetResources(fd);
    connector = drmModeGetConnector(fd, connector_id);
    if (!resources || !connector || connector->connection != DRM_MODE_CONNECTED) {
        fprintf(stderr, "FAIL: connector %u is missing or disconnected\n", connector_id);
        goto out;
    }
    if (!connector->encoder_id) {
        fprintf(stderr, "FAIL: connector %u has no active encoder; keep the display active\n",
                connector_id);
        goto out;
    }
    drmModeEncoderPtr encoder = drmModeGetEncoder(fd, connector->encoder_id);
    if (encoder) {
        crtc_id = encoder->crtc_id;
        drmModeFreeEncoder(encoder);
    }
    if (!crtc_id) {
        fprintf(stderr, "FAIL: connector %u is not attached to an active CRTC\n", connector_id);
        goto out;
    }
    for (uint32_t i = 0; i < (uint32_t)resources->count_crtcs; ++i)
        if (resources->crtcs[i] == crtc_id)
            crtc_index = (uint32_t)i;
    crtc = drmModeGetCrtc(fd, crtc_id);
    if (!crtc || !crtc->mode_valid || crtc_index == UINT32_MAX) {
        fprintf(stderr, "FAIL: CRTC %u has no active mode\n", crtc_id);
        goto out;
    }
    plane_resources = drmModeGetPlaneResources(fd);
    if (!plane_resources) {
        fprintf(stderr, "FAIL: drmModeGetPlaneResources: %s\n", strerror(errno));
        goto out;
    }
    for (uint32_t i = 0; i < plane_resources->count_planes; ++i) {
        drmModePlanePtr p = drmModeGetPlane(fd, plane_resources->planes[i]);
        if (!p)
            continue;
        if (p->plane_id == candidate_id)
            candidate = p;
        else if (p->crtc_id == crtc_id && p->fb_id) {
            current_plane = p->plane_id;
            active_fb = p->fb_id;
        }
        if (p != candidate)
            drmModeFreePlane(p);
    }
    if (!candidate) {
        fprintf(stderr, "FAIL: plane %u not found\n", candidate_id);
        goto out;
    }
    if (!(candidate->possible_crtcs & (1u << crtc_index))) {
        fprintf(stderr, "FAIL: plane %u possible_crtcs=0x%x excludes CRTC %u index %u\n",
                candidate_id, candidate->possible_crtcs, crtc_id, crtc_index);
        goto out;
    }
    if (!active_fb || !current_plane) {
        fprintf(stderr, "FAIL: no currently active plane/framebuffer found on CRTC %u\n", crtc_id);
        goto out;
    }
    if (!test_format(candidate, DRM_FORMAT_ARGB8888)) {
        fprintf(stderr, "FAIL: plane %u does not advertise linear ARGB8888\n", candidate_id);
        goto out;
    }
    if (!property_id(fd, candidate_id, DRM_MODE_OBJECT_PLANE, "alpha", &saved.alpha) ||
        !property_id(fd, candidate_id, DRM_MODE_OBJECT_PLANE, "pixel blend mode", &saved.blend) ||
        !property_id(fd, candidate_id, DRM_MODE_OBJECT_PLANE, "zpos", &saved.zpos)) {
        fprintf(stderr, "FAIL: could not snapshot alpha/blend/zpos plane state\n");
        goto out;
    }

    create.width = tile_w;
    create.height = tile_h;
    create.bpp = 32;
    if (drmIoctl(fd, DRM_IOCTL_MODE_CREATE_DUMB, &create) != 0) {
        fprintf(stderr, "FAIL: allocate transparent ARGB test buffer: %s\n", strerror(errno));
        goto out;
    }
    dumb_created = 1;
    handle = create.handle;
    map_req.handle = handle;
    if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &map_req) != 0) {
        fprintf(stderr, "FAIL: map test buffer: %s\n", strerror(errno));
        goto out;
    }
    map = mmap(NULL, create.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, map_req.offset);
    if (map == MAP_FAILED) {
        fprintf(stderr, "FAIL: mmap test buffer: %s\n", strerror(errno));
        goto out;
    }
    memset(map, 0, create.size); /* transparent premultiplied ARGB */
    uint32_t handles[4] = {handle, 0, 0, 0};
    uint32_t pitches[4] = {create.pitch, 0, 0, 0};
    uint32_t offsets[4] = {0, 0, 0, 0};
    if (drmModeAddFB2(fd, tile_w, tile_h, DRM_FORMAT_ARGB8888,
                      handles, pitches, offsets, &fb_id, 0) != 0) {
        fprintf(stderr, "FAIL: create ARGB framebuffer: %s\n", strerror(errno));
        goto out;
    }
    fb_added = 1;

    req = drmModeAtomicAlloc();
    if (!req) {
        fprintf(stderr, "FAIL: allocate atomic request\n");
        goto out;
    }
    if (add_plane_state(req, fd, candidate_id, crtc_id, fb_id, 48, 48,
                        tile_w, tile_h))
        goto out;

    fprintf(stderr, "TEST_ONLY connector=%u crtc=%u mode=%ux%u active_plane=%u active_fb=%u candidate_plane=%u tile=%ux%u ARGB8888 global_alpha=65535 pixel_alpha=0 blend=premultiplied zpos=2\n",
            connector_id, crtc_id, crtc->mode.hdisplay, crtc->mode.vdisplay,
            current_plane, active_fb, candidate_id, tile_w, tile_h);
    if (drmModeAtomicCommit(fd, req, DRM_MODE_ATOMIC_TEST_ONLY, NULL) != 0) {
        fprintf(stderr, "FAIL: atomic TEST_ONLY rejected candidate: %s (%d)\n",
                strerror(errno), errno);
        goto out;
    }
    fprintf(stderr, "PASS: plane %u can be attached to active HDMI CRTC %u alongside plane %u; no display state was committed\n",
            candidate_id, crtc_id, current_plane);
    rc = 0;
    drmModeAtomicFree(req);
    req = NULL;
    if (display_seconds && run_display_test(fd, candidate_id, crtc_id, fb_id,
                                            map, create.pitch, tile_w, tile_h,
                                            display_seconds, &saved) != 0)
        rc = 1;

out:
    if (req)
        drmModeAtomicFree(req);
    if (fb_added)
        drmModeRmFB(fd, fb_id);
    if (map != MAP_FAILED)
        munmap(map, create.size);
    if (dumb_created) {
        destroy.handle = handle;
        drmIoctl(fd, DRM_IOCTL_MODE_DESTROY_DUMB, &destroy);
    }
    if (candidate)
        drmModeFreePlane(candidate);
    if (plane_resources)
        drmModeFreePlaneResources(plane_resources);
    if (crtc)
        drmModeFreeCrtc(crtc);
    if (connector)
        drmModeFreeConnector(connector);
    if (resources)
        drmModeFreeResources(resources);
    if (fd >= 0)
        close(fd);
    return rc;
}
