"""Latest-result YOLO overlay publisher for verified DRM plane 108.

Rendering and KMS submission run on a dedicated bounded worker. The video
pipeline remains independent; each new detection replaces any pending result.
The verified HDMI mode maps 1920x1080 to a 1280x768 image at y=16 in 1280x800.
"""
import math
import shlex
import shutil
import struct
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from yolo_async_overlay import draw_cairo_boxes

SOURCE_WIDTH, SOURCE_HEIGHT = 1920, 1080
OUTPUT_WIDTH, OUTPUT_HEIGHT = 1280, 800
IMAGE_Y, IMAGE_HEIGHT = 16, 768


def check_daemon_build():
    """Compile the libdrm helper during shell preflight, before V4L2 STREAMON."""
    compiler = shutil.which('cc')
    if compiler is None:
        raise RuntimeError('Direct KMS plane requires the board C compiler cc')
    pkg_config = shutil.which('pkg-config')
    if pkg_config is None:
        raise RuntimeError('Direct KMS plane requires pkg-config and libdrm development metadata')
    flags = subprocess.run([pkg_config, '--cflags', '--libs', 'libdrm'],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, check=False)
    if flags.returncode:
        raise RuntimeError('pkg-config could not locate libdrm: ' + flags.stderr.strip())
    source = Path(__file__).resolve().with_name('yolo_kms_plane_daemon.c')
    with tempfile.TemporaryDirectory(prefix='yolo-kms-check-') as temp:
        binary = Path(temp) / 'daemon'
        built = subprocess.run([compiler, '-O2', '-Wall', '-Wextra', '-Werror',
                                str(source), '-o', str(binary),
                                *shlex.split(flags.stdout)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, check=False)
        if built.returncode:
            raise RuntimeError('Could not build direct-DRM plane helper: ' + built.stderr.strip())
    return True


def map_entries(entries):
    """Map source RGB coordinates to the active letterboxed HDMI scanout."""
    mapped = []
    for (x1, y1, x2, y2), label in entries:
        ox1 = max(0, min(OUTPUT_WIDTH - 1, round(x1 * OUTPUT_WIDTH / SOURCE_WIDTH)))
        ox2 = max(0, min(OUTPUT_WIDTH - 1, round((x2 + 1) * OUTPUT_WIDTH / SOURCE_WIDTH) - 1))
        oy1 = max(IMAGE_Y, min(IMAGE_Y + IMAGE_HEIGHT - 1,
                               IMAGE_Y + round(y1 * IMAGE_HEIGHT / SOURCE_HEIGHT)))
        oy2 = max(IMAGE_Y, min(IMAGE_Y + IMAGE_HEIGHT - 1,
                               IMAGE_Y + round((y2 + 1) * IMAGE_HEIGHT / SOURCE_HEIGHT) - 1))
        if ox2 >= ox1 and oy2 >= oy1:
            mapped.append(((ox1, oy1, ox2, oy2), label))
    return tuple(mapped)


class KmsPlaneOverlay:
    """Push a cached transparent BGRA frame to a persistent direct-DRM worker."""

    def __init__(self, Gst=None, connector=188, plane=108, ttl_ms=250, on_error=None,
                 clock=time.monotonic, cairo_module=None):
        if not math.isfinite(ttl_ms) or ttl_ms < 50:
            raise ValueError('Invalid KMS overlay TTL')
        if cairo_module is None:
            import cairo as cairo_module
        self.Gst, self.cairo = Gst, cairo_module
        self.connector, self.plane = int(connector), int(plane)
        self.ttl_s, self.clock = ttl_ms / 1000, clock
        self.on_error = on_error or (lambda error: None)
        self._condition = threading.Condition()
        self._pending = None
        self._next_sequence = 0
        self._processed_sequence = 0
        self._stop = False
        self._thread = None
        self.error = None
        self._last_entries = None
        self.frames = self.boxed_frames = self.expired_frames = 0
        self.push_ms_total = self.render_ms_total = 0.0
        self.last_push_ms = self.last_render_ms = 0.0
        self.last_patch_bytes = 0
        self._tempdir = None
        self._process = None

    def start(self):
        if self._thread is not None:
            raise RuntimeError('KMS overlay worker already started')
        compiler = shutil.which('cc')
        if compiler is None:
            raise RuntimeError('Direct KMS plane requires the board C compiler cc')
        pkg_config = shutil.which('pkg-config')
        if pkg_config is None:
            raise RuntimeError('Direct KMS plane requires pkg-config and libdrm development metadata')
        flags = subprocess.run([pkg_config, '--cflags', '--libs', 'libdrm'],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, check=False)
        if flags.returncode:
            raise RuntimeError('pkg-config could not locate libdrm: ' + flags.stderr.strip())
        root = Path(__file__).resolve().parent
        source = root / 'yolo_kms_plane_daemon.c'
        self._tempdir = tempfile.TemporaryDirectory(prefix='yolo-kms-plane-')
        binary = Path(self._tempdir.name) / 'yolo-kms-plane-daemon'
        built = subprocess.run([compiler, '-O2', '-Wall', '-Wextra', '-Werror',
                                str(source), '-o', str(binary),
                                *shlex.split(flags.stdout)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, check=False)
        if built.returncode:
            self._tempdir.cleanup()
            self._tempdir = None
            raise RuntimeError('Could not build persistent direct-DRM plane worker: ' +
                               built.stderr.strip())
        self._process = subprocess.Popen([str(binary), '/dev/dri/card0',
                                          str(self.connector), str(self.plane)],
                                         stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                         stderr=None, bufsize=0)
        time.sleep(0.15)
        if self._process.poll() is not None:
            self._tempdir.cleanup()
            self._tempdir = None
            raise RuntimeError(f'Direct-DRM plane worker exited at startup: {self._process.returncode}')
        self._thread = threading.Thread(target=self._run, name='kms-overlay-108', daemon=True)
        self._thread.start()

    def publish(self, entries, acquired_at, sequence=0):
        now = self.clock()
        if not math.isfinite(acquired_at) or acquired_at > now:
            return False
        if now - acquired_at > self.ttl_s:
            return False
        mapped = map_entries(entries)
        with self._condition:
            if self._pending is not None and sequence < self._pending[2]:
                return False
            self._next_sequence = max(self._next_sequence + 1, sequence)
            self._pending = (mapped, acquired_at, self._next_sequence)
            self._condition.notify()
        return True

    def _render_patch(self, entries, previous):
        changed = tuple(entries) + tuple(previous)
        if not changed:
            return None
        probe = self.cairo.ImageSurface(self.cairo.FORMAT_ARGB32, 1, 1)
        metrics = self.cairo.Context(probe)
        metrics.select_font_face('Sans')
        metrics.set_font_size(18)
        left, top, right, bottom = OUTPUT_WIDTH, OUTPUT_HEIGHT, 0, 0
        for (x1, y1, x2, y2), label in changed:
            left = min(left, x1 - 3)
            top = min(top, y1 - 3)
            right = max(right, x2 + 4)
            bottom = max(bottom, y2 + 4)
            bx, by, tw, th, _, _ = metrics.text_extents(label)
            tx = max(3, min(x1 + 3, OUTPUT_WIDTH - tw - 5))
            ty = max(th + 5, min(y1 - 5, OUTPUT_HEIGHT - 5))
            left = min(left, int(math.floor(tx + bx - 4)))
            top = min(top, int(math.floor(ty + by - 4)))
            right = max(right, int(math.ceil(tx + bx + tw + 4)))
            bottom = max(bottom, int(math.ceil(ty + by + th + 4)))
        left = max(0, min(OUTPUT_WIDTH - 1, left))
        top = max(0, min(OUTPUT_HEIGHT - 1, top))
        right = max(left + 1, min(OUTPUT_WIDTH, right))
        bottom = max(top + 1, min(OUTPUT_HEIGHT, bottom))
        width, height = right - left, bottom - top
        data = bytearray(width * height * 4)
        surface = self.cairo.ImageSurface.create_for_data(
            data, self.cairo.FORMAT_ARGB32, width, height, width * 4)
        context = self.cairo.Context(surface)
        context.translate(-left, -top)
        draw_cairo_boxes(context, entries, OUTPUT_WIDTH, OUTPUT_HEIGHT)
        surface.flush()
        return left, top, width, height, data

    def _write_all(self, payload):
        view = memoryview(payload)
        sent = 0
        while sent < len(view):
            count = self._process.stdin.write(view[sent:])
            if count is None or count <= 0:
                raise RuntimeError('Direct-DRM plane worker closed its patch input')
            sent += count

    def _push(self, patch):
        started = self.clock()
        if self._process is None or self._process.stdin is None:
            raise RuntimeError('Persistent direct-DRM plane worker is not running')
        x, y, width, height, pixels = patch
        self._write_all(struct.pack('<4I', x, y, width, height))
        self._write_all(pixels)
        self.last_patch_bytes = len(pixels)
        self.last_push_ms = (self.clock() - started) * 1000
        self.push_ms_total += self.last_push_ms

    def _run(self):
        current = None
        acquired = 0.0
        seen = -1
        try:
            while True:
                expired = False
                with self._condition:
                    while not self._stop and (self._pending is None or
                                               self._pending[2] == seen):
                        if current and self.clock() - acquired <= self.ttl_s:
                            self._condition.wait(min(0.025, max(0.001,
                                self.ttl_s - (self.clock() - acquired))))
                            if self.clock() - acquired > self.ttl_s:
                                current, acquired = (), self.clock()
                                self._next_sequence += 1
                                self._pending = (current, acquired, self._next_sequence)
                                expired = True
                                break
                        else:
                            self._condition.wait()
                    if self._stop:
                        break
                    entries, acquired, seen = self._pending
                    current = entries
                    self._pending = None
                if entries == self._last_entries:
                    continue
                started = self.clock()
                patch = self._render_patch(entries, self._last_entries or ())
                self.last_render_ms = (self.clock() - started) * 1000
                self.render_ms_total += self.last_render_ms
                if patch is not None:
                    self._push(patch)
                self.frames += 1
                self.boxed_frames += bool(entries)
                self.expired_frames += expired
                self._last_entries = entries
                with self._condition:
                    self._processed_sequence = seen
                    self._condition.notify_all()
        except Exception as exc:
            self.error = str(exc)
            self.on_error('KMS plane 108 overlay: ' + self.error)

    def report(self):
        frames = max(1, self.frames)
        return (f'KMS_OVERLAY plane=108 updates={self.frames} boxed_updates={self.boxed_frames} '
                f'expired_clears={self.expired_frames} render_ms={self.render_ms_total/frames:.3f} '
                f'push_ms={self.push_ms_total/frames:.3f} last_push_ms={self.last_push_ms:.3f} '
                f'last_patch_bytes={self.last_patch_bytes} '
                f'error={self.error or "none"}')

    def close(self):
        if self._thread is None:
            return
        with self._condition:
            self._next_sequence += 1
            target_sequence = self._next_sequence
            self._pending = ((), self.clock(), target_sequence)
            self._condition.notify_all()
            deadline = self.clock() + 0.25
            while (self._processed_sequence < target_sequence and
                   self.clock() < deadline and self.error is None):
                self._condition.wait(min(0.01, deadline - self.clock()))
        with self._condition:
            self._stop = True
            self._condition.notify_all()
        self._thread.join(timeout=0.5)
        if self._process is not None:
            if self._process.stdin:
                self._process.stdin.close()
            try:
                self._process.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                self._process.terminate()
                try:
                    self._process.wait(timeout=0.5)
                except subprocess.TimeoutExpired:
                    self._process.kill()
                    self._process.wait(timeout=0.5)
            self._process = None
        if self._tempdir is not None:
            self._tempdir.cleanup()
            self._tempdir = None
