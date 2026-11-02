"""Latest-result, bounded-age boxes for an independent GStreamer display branch.

Only immutable coordinates/labels cross threads. Camera buffers and NPU output
arrays are never kept here. Gst timestamps belong to the same pre-tee stream;
wall-clock age also expires boxes when a stream stalls or timestamps are absent.
"""
from dataclasses import dataclass
from collections import deque
import math
import threading
import time

from yolo_draw import prepare_boxes

CLOCK_TIME_NONE = (1 << 64) - 1


def valid_pts(value):
    if value is None:
        return None
    value = int(value)
    return value if 0 <= value < CLOCK_TIME_NONE else None


@dataclass(frozen=True)
class BoxSnapshot:
    entries: tuple
    source_pts: object
    acquired_at: float
    completed_at: float
    sequence: int
    composition: object = None


class LatestBoxes:
    """One immutable result, with no frame queue or blocking inference wait."""

    def __init__(self, width=1920, height=1080, ttl_ms=250, max_boxes=64,
                 clock=time.monotonic, renderer=None):
        if (width <= 0 or height <= 0 or max_boxes <= 0 or
                not math.isfinite(ttl_ms) or ttl_ms <= 0):
            raise ValueError('Invalid overlay geometry, TTL or box limit')
        self.width, self.height = width, height
        self.ttl_s = ttl_ms / 1000
        self.max_boxes, self.clock = max_boxes, clock
        self._lock = threading.Lock()
        self._snapshot = None
        self._published = self._rejected = 0
        self.renderer = renderer

    def publish(self, boxes, scores, classes, names, source_pts, acquired_at,
                sequence=0):
        now = self.clock()
        if not math.isfinite(acquired_at) or acquired_at > now:
            raise ValueError('Invalid detection acquisition time')
        with self._lock:
            if (now - acquired_at > self.ttl_s or
                    (self._snapshot is not None and acquired_at < self._snapshot.acquired_at)):
                self._rejected += 1
                return False
        # Sanitize and convert NPU arrays into owned Python scalars outside the
        # lock. Keep the highest scores if a scene produces too many detections.
        if not (len(boxes) == len(scores) == len(classes)):
            raise ValueError('Mismatched detection arrays')
        ranked = sorted(((box, float(score), cid) for box, score, cid in zip(boxes, scores, classes)
                         if math.isfinite(float(score))), key=lambda item: item[1], reverse=True)
        entries = prepare_boxes([x[0] for x in ranked], [x[1] for x in ranked],
                                [x[2] for x in ranked], names, self.width, self.height)
        entries = tuple(entries[:self.max_boxes])
        # The publisher is the sole inference thread. Render a new immutable
        # overlay BEFORE publishing it; video callbacks only read snapshots.
        composition = self.renderer(entries) if self.renderer is not None else None
        now = self.clock()
        snapshot = BoxSnapshot(entries, valid_pts(source_pts), acquired_at, now, sequence, composition)
        with self._lock:
            if (now - acquired_at > self.ttl_s or
                    (self._snapshot is not None and acquired_at < self._snapshot.acquired_at)):
                self._rejected += 1
                return False
            self._snapshot = snapshot  # Empty results explicitly clear old boxes.
            self._published += 1
        return True

    def for_frame(self, frame_pts, now=None):
        now = self.clock() if now is None else now
        frame_pts = valid_pts(frame_pts)
        with self._lock:
            snapshot = self._snapshot
        if snapshot is None:
            return None, 'empty', None
        age_ms = (now - snapshot.acquired_at) * 1000
        if age_ms < 0 or age_ms > self.ttl_s * 1000:
            return None, 'expired', age_ms
        if frame_pts is not None and snapshot.source_pts is not None:
            stream_age_ms = (frame_pts - snapshot.source_pts) / 1e6
            if stream_age_ms < 0:
                return None, 'future', stream_age_ms
            if stream_age_ms > self.ttl_s * 1000:
                return None, 'expired', stream_age_ms
            age_ms = max(age_ms, stream_age_ms)
        return snapshot, 'current', age_ms

    def clear(self):
        with self._lock:
            self._snapshot = None

    def counts(self):
        with self._lock:
            return self._published, self._rejected

    def latest(self):
        with self._lock:
            return self._snapshot


def draw_cairo_boxes(context, entries, width, height):
    """Draw sparse outlines/labels in native Cairo, never map/copy RGB in Python."""
    if not entries:
        return
    context.save()
    try:
        context.rectangle(0, 0, width, height)
        context.clip()
        context.set_line_width(2)
        context.select_font_face('Sans')
        context.set_font_size(18)
        for (x1, y1, x2, y2), label in entries:
            context.set_source_rgb(0, 1, 0)
            context.rectangle(x1 + 0.5, y1 + 0.5, x2 - x1, y2 - y1)
            context.stroke()
            bearing_x, bearing_y, tw, th, _, _ = context.text_extents(label)
            tx = max(3, min(x1 + 3, width - tw - 5))
            ty = max(th + 5, min(y1 - 5, height - 5))
            context.set_source_rgba(0, 0, 0, 0.8)
            context.rectangle(tx + bearing_x - 3, ty + bearing_y - 3, tw + 6, th + 6)
            context.fill()
            context.set_source_rgb(1, 1, 1)
            context.move_to(tx, ty)
            context.show_text(label)
    finally:
        context.restore()


def check_cairo_overlay(Gst):
    """Check the plugin and GI's native Cairo context marshaller before DMA."""
    try:
        import cairo  # noqa: F401 - PyGObject requires the Pycairo type adapter.
        import gi
        gi.require_foreign('cairo')
    except (ImportError, ValueError) as exc:
        raise RuntimeError('Async boxes require Pycairo and GI Cairo bindings in this Python. '
                           'On Debian: apt-get install python3-cairo python3-gi-cairo. '
                           f'Detail: {exc}') from exc
    if Gst.ElementFactory.find('cairooverlay') is None:
        raise RuntimeError('GStreamer cairooverlay missing; install gstreamer1.0-plugins-good '
                           'and check: gst-inspect-1.0 cairooverlay')


class CairoBoxOverlay:
    def __init__(self, element, store, on_error, clock=time.monotonic):
        self.element, self.store = element, store
        self.on_error, self.clock = on_error, clock
        self.error = None
        self._metrics_lock = threading.Lock()
        self._frames = self._boxed = self._expired = self._future = 0
        self._draw_s = 0.0
        self._last_age = None
        self._last_count = 0
        element.connect('caps-changed', self.caps_changed)
        element.connect('draw', self.draw)

    def fail(self, error):
        if self.error is None:
            self.error = str(error)
            self.store.clear()
            self.on_error('Async box overlay: ' + self.error)

    def caps_changed(self, _element, caps):
        try:
            structure = caps.get_structure(0)
            geometry = (structure.get_value('width'), structure.get_value('height'))
            if geometry != (self.store.width, self.store.height):
                raise RuntimeError(f'Overlay geometry {geometry} differs from detection geometry')
        except Exception as exc:
            self.fail(exc)

    def draw(self, _element, context, timestamp, _duration):
        if self.error is not None:
            return
        started = self.clock()
        try:
            snapshot, state, age = self.store.for_frame(timestamp, started)
            entries = snapshot.entries if snapshot is not None else ()
            draw_cairo_boxes(context, entries, self.store.width, self.store.height)
            with self._metrics_lock:
                self._frames += 1
                self._boxed += bool(entries)
                self._expired += state == 'expired'
                self._future += state == 'future'
                self._last_age, self._last_count = age, len(entries)
                self._draw_s += self.clock() - started
        except Exception as exc:
            self.fail(exc)

    def report(self):
        with self._metrics_lock:
            frames = self._frames
            fields = (frames, self._boxed, self._expired, self._future,
                      self._last_count, self._last_age,
                      1000 * self._draw_s / frames if frames else 0.0)
        published, rejected = self.store.counts()
        frames, boxed, expired, future, count, age, draw_ms = fields
        age_text = '--' if age is None else f'{age:.1f}'
        return (f'OVERLAY frames={frames} boxed_frames={boxed} boxes={count} '
                f'source_age_ms={age_text} expired_frames={expired} future_frames={future} '
                f'draw_ms={draw_ms:.3f} published={published} rejected={rejected}')


def check_composition_overlay(Gst):
    """Load supported GI APIs before capture; Cairo is used only for label tiles."""
    import gi
    import sys
    try:
        import cairo
        gi.require_version('GstVideo', '1.0')
        from gi.repository import GstVideo
    except (ImportError, ValueError) as exc:
        raise RuntimeError('Cached overlay requires python3-cairo and GstVideo introspection '
                           f'(gir1.2-gst-plugins-base-1.0): {exc}') from exc
    if sys.byteorder != 'little':
        raise RuntimeError('Cached BGRA overlay is validated for little-endian RK3576 only')
    if Gst.ElementFactory.find('overlaycomposition') is None:
        raise RuntimeError('GStreamer overlaycomposition missing; install/enable '
                           'gstreamer1.0-plugins-base (GStreamer >= 1.16)')
    for name in ('VideoOverlayRectangle', 'VideoOverlayComposition', 'buffer_add_video_meta'):
        if not hasattr(GstVideo, name):
            raise RuntimeError('GstVideo introspection lacks ' + name)
    # Validate native GI constructors on a tiny transparent tile before capture;
    # a factory lookup alone does not prove these APIs work on the board image.
    test_buffer = Gst.Buffer.new_allocate(None, 16, None)
    test_buffer.fill(0, bytes(16))
    meta = GstVideo.buffer_add_video_meta(test_buffer, GstVideo.VideoFrameFlags.NONE,
                                         GstVideo.VideoFormat.BGRA, 2, 2)
    if meta is None:
        raise RuntimeError('GstVideo could not attach BGRA VideoMeta')
    rectangle = GstVideo.VideoOverlayRectangle.new_raw(
        test_buffer, 0, 0, 2, 2, GstVideo.VideoOverlayFormatFlags.PREMULTIPLIED_ALPHA)
    if rectangle is None or GstVideo.VideoOverlayComposition.new(rectangle) is None:
        raise RuntimeError('GstVideo overlay composition constructors failed')
    return GstVideo, cairo


class CompositionRenderer:
    """Pre-render sparse BGRA strips/labels once per changed detection result.

    No full-resolution transparent surface: each box has four 2px green strips
    and one small label tile. Reusing the composition preserves native caches.
    Instances have a single publisher (the inference worker).
    """
    def __init__(self, Gst, GstVideo, cairo, width=1920, height=1080,
                 clock=time.monotonic):
        self.Gst, self.GstVideo, self.cairo = Gst, GstVideo, cairo
        self.width, self.height, self.clock = width, height, clock
        self._entries, self._cached = None, None
        self._lock = threading.Lock()
        self.updates = self.reuses = self.tiles = self.tile_bytes = 0
        self.render_s = 0.0

    def rectangle(self, data, width, height, x, y):
        buffer = self.Gst.Buffer.new_allocate(None, len(data), None)
        if buffer.fill(0, data) != len(data):
            raise RuntimeError('Could not fill overlay tile')
        # Cairo ARGB32 and GStreamer BGRA have identical native little-endian
        # premultiplied layout on RK3576. This buffer is never mutated later.
        meta = self.GstVideo.buffer_add_video_meta(
            buffer, self.GstVideo.VideoFrameFlags.NONE,
            self.GstVideo.VideoFormat.BGRA, width, height)
        if meta is None:
            raise RuntimeError('Could not add overlay tile VideoMeta')
        rectangle = self.GstVideo.VideoOverlayRectangle.new_raw(
            buffer, x, y, width, height,
            self.GstVideo.VideoOverlayFormatFlags.PREMULTIPLIED_ALPHA)
        if rectangle is None:
            raise RuntimeError('Could not create overlay rectangle')
        return rectangle

    def __call__(self, entries):
        if entries == self._entries:
            with self._lock:
                self.reuses += 1
            return self._cached
        started = self.clock()
        rectangles, total_bytes = [], 0
        green = bytes((0, 255, 0, 255))
        for (x1, y1, x2, y2), label in entries:
            width, height = x2 - x1 + 1, y2 - y1 + 1
            thickness = min(2, width, height)
            for x, y, w, h in ((x1, y1, width, thickness),
                               (x1, y2-thickness+1, width, thickness),
                               (x1, y1, thickness, height),
                               (x2-thickness+1, y1, thickness, height)):
                data = green * (w * h)
                rectangles.append(self.rectangle(data, w, h, x, y))
                total_bytes += len(data)
            # A bounded small label surface, never a 1920x1080 frame/surface.
            probe = self.cairo.ImageSurface(self.cairo.FORMAT_ARGB32, 1, 1)
            context = self.cairo.Context(probe)
            context.select_font_face('Sans')
            context.set_font_size(18)
            bx, by, tw, th, _, _ = context.text_extents(label)
            w = min(self.width, max(1, int(math.ceil(tw)) + 8))
            h = min(self.height, max(1, int(math.ceil(th)) + 8))
            surface = self.cairo.ImageSurface(self.cairo.FORMAT_ARGB32, w, h)
            context = self.cairo.Context(surface)
            context.set_source_rgba(0, 0, 0, 0.8)
            context.paint()
            context.select_font_face('Sans')
            context.set_font_size(18)
            context.set_source_rgb(1, 1, 1)
            context.move_to(4 - bx, 4 - by)
            context.show_text(label)
            surface.flush()
            data = bytes(surface.get_data())
            rectangles.append(self.rectangle(data, w, h,
                max(0, min(x1, self.width-w)), max(0, min(y1-h, self.height-h))))
            total_bytes += len(data)
        composition = None
        if rectangles:
            composition = self.GstVideo.VideoOverlayComposition.new(rectangles[0])
            for rectangle in rectangles[1:]:
                composition.add_rectangle(rectangle)
        self._entries, self._cached = entries, composition
        with self._lock:
            self.updates += 1
            self.tiles, self.tile_bytes = len(rectangles), total_bytes
            self.render_s += self.clock() - started
        return composition

    def metrics(self):
        with self._lock:
            return dict(render_updates=self.updates, cache_reuses=self.reuses,
                        tiles=self.tiles, tile_bytes=self.tile_bytes,
                        render_ms=1000*self.render_s/max(1, self.updates))


class CachedCompositionOverlay:
    """Video callbacks select an already-rendered composition; no pixel drawing."""
    def __init__(self, element, store, renderer, on_error, clock=time.monotonic, Gst=None):
        self.element, self.store, self.renderer = element, store, renderer
        self.on_error, self.clock = on_error, clock
        self.error = None
        self._lock = threading.Lock()
        self.frames = self.boxed = self.expired = self.future = 0
        self.callback_s = 0.0
        self.stage_s = 0.0
        self.stage_frames = 0
        self.stage_inputs = self.stage_outputs = self.stage_unmatched = 0
        self._stage_pending = deque()
        self._stage_lock = threading.Lock()
        self._probe_handles = []
        self.last_age, self.last_count = None, 0
        element.connect('caps-changed', self.caps_changed)
        element.connect('draw', self.draw)
        if Gst is not None:
            # The native element processes each frame synchronously between its
            # sink/src pads. Measure that whole stage, not just Python selection.
            sinkpad = element.get_static_pad('sink')
            srcpad = element.get_static_pad('src')
            def get_pts(info):
                try:
                    pts = info.get_buffer().pts
                    return int(pts) if pts is not None and int(pts) < CLOCK_TIME_NONE else None
                except (AttributeError, TypeError, ValueError):
                    return None
            def before(_pad, info):
                key = get_pts(info)
                started = self.clock()
                with self._stage_lock:
                    self._stage_pending.append((key, started))
                    self.stage_inputs += 1
                    # A downstream flush/drop should not let stale timestamps
                    # grow without bound or pair with a later frame.
                    while len(self._stage_pending) > 32:
                        self._stage_pending.popleft()
                        self.stage_unmatched += 1
                return Gst.PadProbeReturn.OK
            def after(_pad, info):
                key = get_pts(info)
                ended = self.clock()
                with self._stage_lock:
                    self.stage_outputs += 1
                    index = next((i for i, (pending_key, _started) in
                                  enumerate(self._stage_pending) if pending_key == key), None)
                    if index is None:
                        self.stage_unmatched += 1
                    else:
                        _pending_key, started = self._stage_pending[index]
                        del self._stage_pending[index]
                        duration = max(0.0, ended - started)
                        with self._lock:
                            self.stage_s += duration
                            self.stage_frames += 1
                return Gst.PadProbeReturn.OK
            for pad, callback in ((sinkpad, before), (srcpad, after)):
                if pad is None:
                    raise RuntimeError('overlaycomposition is missing a video pad')
                self._probe_handles.append((pad, pad.add_probe(Gst.PadProbeType.BUFFER, callback)))

    def fail(self, error):
        if self.error is None:
            self.error = str(error)
            self.store.clear()
            self.on_error('Cached box overlay: ' + self.error)

    def caps_changed(self, _element, caps, _window_width, _window_height):
        try:
            structure = caps.get_structure(0)
            geometry = (structure.get_value('width'), structure.get_value('height'))
            if geometry != (self.store.width, self.store.height):
                raise RuntimeError(f'Overlay geometry {geometry} differs from detection geometry')
        except Exception as exc:
            self.fail(exc)

    def draw(self, _element, sample):
        if self.error is not None:
            return None
        started = self.clock()
        try:
            snapshot, state, age = self.store.for_frame(sample.get_buffer().pts, started)
            composition = snapshot.composition if snapshot is not None else None
            count = len(snapshot.entries) if snapshot is not None else 0
            with self._lock:
                self.frames += 1
                self.boxed += composition is not None
                self.expired += state == 'expired'
                self.future += state == 'future'
                self.last_age, self.last_count = age, count
                self.callback_s += self.clock() - started
            return composition
        except Exception as exc:
            self.fail(exc)
            return None

    def report(self):
        with self._lock:
            frames, boxed, expired, future = self.frames, self.boxed, self.expired, self.future
            age, count = self.last_age, self.last_count
            callback_ms = self.callback_s * 1000 / max(1, frames)
            stage_ms = self.stage_s * 1000 / max(1, self.stage_frames)
            stage_frames = self.stage_frames
        with self._stage_lock:
            stage_inputs, stage_outputs = self.stage_inputs, self.stage_outputs
            stage_unmatched = self.stage_unmatched + len(self._stage_pending)
        published, rejected = self.store.counts()
        age_text = '--' if age is None else f'{age:.1f}'
        blend = 'unknown'
        pad = self.element.get_static_pad('src')
        caps = pad.get_current_caps() if pad is not None else None
        if caps is not None and caps.get_size():
            blend = ('downstream-meta' if caps.get_features(0).contains(
                'meta:GstVideoOverlayComposition') else 'software')
        metrics = self.renderer.metrics()
        return (f'OVERLAY backend=cached-composition frames={frames} boxed_frames={boxed} boxes={count} '
                f'source_age_ms={age_text} expired_frames={expired} future_frames={future} '
                f'draw_ms={callback_ms:.3f} callback_ms={callback_ms:.3f} '
                f'render_ms={metrics["render_ms"]:.3f} render_updates={metrics["render_updates"]} '
                f'cache_reuses={metrics["cache_reuses"]} tiles={metrics["tiles"]} '
                f'tile_bytes={metrics["tile_bytes"]} blend={blend} '
                f'overlay_stage_ms={stage_ms:.3f} stage_frames={stage_frames} '
                f'stage_in={stage_inputs} stage_out={stage_outputs} stage_unmatched={stage_unmatched} '
                'draw_scope=selection-only stage_scope=callback+native-blend '
                f'published={published} rejected={rejected}')
