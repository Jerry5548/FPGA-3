#!/usr/bin/env python3
"""Pure async-box regressions; --gst also tests real 1080p Cairo/GStreamer pixels.

The optional live synthetic test opens no camera, DMA, display, model or NPU.
"""
import argparse
from pathlib import Path
import struct
import threading
import time
from types import SimpleNamespace
import unittest

from display_lz77_video import build_pipeline, build_sync_pipelines
from rknn_yolo_backend import InferencePacer
from yolo_async_overlay import (LatestBoxes, CairoBoxOverlay, CLOCK_TIME_NONE,
                               CachedCompositionOverlay, CompositionRenderer)
from yolo_kms_plane import KmsPlaneOverlay, map_entries


class Clock:
    def __init__(self):
        self.now = 10.0

    def __call__(self):
        return self.now


class Context:
    """Recorder to verify sparse drawing and balanced native context lifetime."""
    def __init__(self):
        self.calls = []

    def text_extents(self, label):
        return (0, -15, len(label) * 9, 18, len(label) * 9, 0)

    def __getattr__(self, name):
        return lambda *args: self.calls.append((name, args))


class Element:
    def __init__(self):
        self.handlers = {}

    def connect(self, name, callback):
        self.handlers[name] = callback


def args_for(view='stats', headless=False, model=True, fifo=False):
    return SimpleNamespace(yolo_model=Path('fixture.rknn') if model else None,
                           yolo_view=view, headless=headless, io_mode='mmap',
                           video_device=None if fifo else Path('/dev/video73'),
                           fifo=Path('/tmp/rgb.pipe') if fifo else None,
                           rx_log=Path('/tmp/rx.log') if fifo else None, font_size=16)


class AsyncOverlayTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock()
        self.store = LatestBoxes(clock=self.clock)

    def publish(self, pts=1_000_000_000, acquired=9.95, boxes=None, scores=None, sequence=1):
        boxes = [[20, 30, 200, 300]] if boxes is None else boxes
        scores = [0.9] if scores is None else scores
        return self.store.publish(boxes, scores, [0] * len(boxes), ('person', 'car'),
                                  pts, acquired, sequence)

    def test_latest_result_owns_coordinates_and_empty_clears(self):
        boxes = [[20, 30, 200, 300]]
        self.publish(boxes=boxes)
        boxes[0][0] = 999
        snap, state, age = self.store.for_frame(1_016_000_000)
        self.assertEqual(snap.entries, (((20, 30, 200, 300), 'person 0.90'),))
        self.assertEqual(state, 'current')
        self.assertAlmostEqual(age, 50)
        self.publish(boxes=[], scores=[])
        self.assertEqual(self.store.for_frame(1_016_000_000)[0].entries, ())

    def test_wall_age_includes_inference_and_clears_stale_boxes(self):
        self.publish()
        self.clock.now = 10.21
        self.assertEqual(self.store.for_frame(1_016_000_000)[1], 'expired')
        self.assertFalse(self.publish(acquired=9.0))
        self.assertEqual(self.store.counts(), (1, 1))

    def test_stream_age_and_no_future_detections(self):
        self.publish()
        self.assertEqual(self.store.for_frame(999_000_000)[1], 'future')
        self.assertEqual(self.store.for_frame(1_251_000_000)[1], 'expired')
        self.assertEqual(self.store.for_frame(1_100_000_000)[1], 'current')

    def test_missing_pts_still_uses_wall_age(self):
        for pts in (None, CLOCK_TIME_NONE, -1):
            self.publish(pts=pts)
            self.assertEqual(self.store.for_frame(CLOCK_TIME_NONE)[1], 'current')
        self.clock.now += 0.3
        self.assertEqual(self.store.for_frame(None)[1], 'expired')

    def test_out_of_order_completion_rejected(self):
        self.publish(acquired=9.98, sequence=2)
        self.assertFalse(self.publish(acquired=9.97, sequence=1))
        self.assertEqual(self.store.for_frame(1_016_000_000)[0].sequence, 2)

    def test_sanitize_clip_and_bounded_top_scores(self):
        store = LatestBoxes(max_boxes=2, clock=self.clock)
        store.publish([[-10, -5, 2000, 2000], [20, 30, 40, 50], [60, 70, 80, 90],
                       [1, 1, float('nan'), 50]], [0.1, 0.9, 0.8, 1.0], [0, 1, 0, 0],
                      ('person', 'car'), 0, 9.99)
        entries = store.for_frame(0)[0].entries
        self.assertEqual([x[1] for x in entries], ['car 0.90', 'person 0.80'])
        self.publish(boxes=[[-10, -5, 2000, 2000]])
        self.assertEqual(self.store.for_frame(1_000_000_000)[0].entries[0][0], (0, 0, 1919, 1079))

    def test_render_reuses_result_without_waiting_for_new_inference(self):
        self.publish()
        element, context, errors = Element(), Context(), []
        overlay = CairoBoxOverlay(element, self.store, errors.append, clock=self.clock)
        for offset in range(6):
            element.handlers['draw'](element, context, 1_000_000_000 + offset * 16_666_667, 0)
        self.assertFalse(errors)
        self.assertEqual(sum(name == 'show_text' for name, _ in context.calls), 6)
        self.assertEqual(sum(name == 'save' for name, _ in context.calls), 6)
        self.assertEqual(sum(name == 'restore' for name, _ in context.calls), 6)
        self.assertIn('frames=6 boxed_frames=6', overlay.report())
        self.clock.now += 0.3
        element.handlers['draw'](element, context, 1_200_000_000, 0)
        self.assertEqual(sum(name == 'show_text' for name, _ in context.calls), 6)
        self.assertIn('expired_frames=1', overlay.report())

    def test_render_exceptions_fail_once_and_clear_result(self):
        self.publish()
        element, errors = Element(), []
        overlay = CairoBoxOverlay(element, self.store, errors.append, clock=self.clock)
        context = Context()
        def broken(*_):
            raise RuntimeError('native draw failed')
        context.stroke = broken
        overlay.draw(element, context, 1_000_000_000, 0)
        overlay.draw(element, context, 1_000_000_000, 0)
        self.assertEqual(len(errors), 1)
        self.assertIn('native draw failed', errors[0])
        self.assertEqual(self.store.for_frame(1_000_000_000)[1], 'empty')
        self.assertEqual(context.calls[-1][0], 'restore')

    def test_pipeline_modes_and_fifo_do_not_force_inference_display(self):
        for fifo in (False, True):
            pipeline = build_pipeline(args_for(fifo=fifo), 'fakesink sync=false')
            self.assertIn('tee name=decoded', pipeline)
            self.assertIn('overlaycomposition name=box_overlay', pipeline)
            self.assertNotIn('cairooverlay', pipeline)
            self.assertNotIn('format=RGB16', pipeline)
            self.assertNotIn('appsrc', pipeline)
            for branch in ('infer_queue', 'display_queue'):
                self.assertIn(f'name={branch} max-size-buffers=1', pipeline)
        for view in ('boxes', 'boxes-sync'):
            capture, display = build_sync_pipelines(args_for(view=view), 'fakesink sync=false')
            self.assertIn('appsink name=infer', capture)
            self.assertIn('emit-signals=false', capture)
            self.assertNotIn(';', capture)
            self.assertNotIn('appsrc', capture)
            self.assertIn('appsrc name=annotated', display)
            self.assertNotIn(';', display)
            self.assertNotIn('cairooverlay', display)
            self.assertIn('display_queue max-size-buffers=1', display)
            self.assertIn('fpsdisplaysink name=fps', display)
        self.assertNotIn('cairooverlay', build_pipeline(args_for(headless=True), 'fakesink'))
        plain = build_pipeline(args_for(model=False), 'fakesink')
        self.assertNotIn('tee', plain)
        self.assertNotIn('cairooverlay', plain)
        import sys
        import io
        from contextlib import redirect_stderr
        from unittest.mock import patch
        from display_lz77_video import main
        with self.assertRaises(SystemExit) as error:
            with redirect_stderr(io.StringIO()), patch.object(sys, 'argv',
                 ['display_lz77_video.py', '--yolo-view', 'invalid']):
                main()
        self.assertEqual(error.exception.code, 2)

    def test_kms_path_uses_direct_drm_not_a_second_kmssink_pipeline(self):
        source = Path(__file__).with_name('display_lz77_video.py').read_text()
        helper = Path(__file__).with_name('yolo_kms_plane.py').read_text()
        daemon = Path(__file__).with_name('yolo_kms_plane_daemon.c').read_text()
        self.assertIn('kms_overlay.start()', source)
        self.assertIn('yolo_kms_plane_daemon.c', helper)
        self.assertIn('drmModeAtomicCommit', daemon)
        self.assertIn('single_scanout=1 patch_updates=1', daemon)
        self.assertIn('KMS_PLANE_STOP updates=%u atomic_updates=0', daemon)
        self.assertIn('memcpy((uint8_t *)map', daemon)
        args = args_for()
        args.yolo_kms_overlay = True
        player = build_pipeline(args, 'kmssink connector-id=188')
        self.assertNotIn('overlaycomposition name=box_overlay', player)
        self.assertIn('textoverlay name=osd', player)

    def test_capture_control_adds_one_leaky_latest_frame_tap(self):
        args = args_for()
        args.capture_control = Path('/tmp/capture.sock')
        args.capture_dir = Path('/tmp/captures')
        graph = build_pipeline(args, 'fakesink sync=false')
        self.assertIn('tee name=decoded', graph)
        self.assertIn('capture_queue max-size-buffers=1', graph)
        self.assertIn('appsink name=capture_tap', graph)
        self.assertIn('max-buffers=1 drop=true', graph)

    def test_kms_plane_maps_1080p_boxes_to_active_hdmi_image_area(self):
        mapped = map_entries((((0, 0, 1919, 1079), 'person 0.9'),
                              ((960, 540, 959, 539), 'invalid')))
        self.assertEqual(mapped, (((0, 16, 1279, 783), 'person 0.9'),))

    def test_kms_plane_overlay_sends_local_patch_not_full_scanout_frame(self):
        class Pipe:
            def __init__(self): self.data = bytearray()
            def write(self, data):
                self.data.extend(data)
                return len(data)
        class Surface:
            FORMAT_ARGB32 = 0
            ImageSurface = None
            def __init__(self, _format, _width, _height):
                pass
            Context = staticmethod(lambda _surface: Context())
            @staticmethod
            def create_for_data(data, _format, width, height, _stride):
                self.assertEqual(len(data), width * height * 4)
                return SimpleNamespace(flush=lambda: None)
        Surface.ImageSurface = Surface
        overlay = KmsPlaneOverlay(clock=self.clock, cairo_module=Surface)
        pipe = Pipe()
        overlay._process = SimpleNamespace(stdin=pipe)
        self.assertTrue(overlay.publish((((100, 100, 300, 300), 'person'),), 9.99, 1))
        with overlay._condition:
            first = overlay._pending
        self.assertTrue(overlay.publish((((960, 540, 1200, 800), 'car'),), 9.995, 2))
        with overlay._condition:
            latest = overlay._pending
        self.assertGreater(latest[2], first[2])
        patch = overlay._render_patch(latest[0], first[0])
        self.assertIsNotNone(patch)
        x, y, width, height, pixels = patch
        self.assertLess(width * height * 4, 1280 * 800 * 4)
        overlay._push(patch)
        self.assertEqual(len(pipe.data), 16 + len(pixels))
        self.assertEqual(struct.unpack('<4I', pipe.data[:16]), (x, y, width, height))
        self.assertEqual(overlay.report().split('updates=')[1].split()[0], '0')

    def test_cached_snapshot_renders_on_publish_only_and_reuses_for_frames(self):
        calls = []
        composition = object()
        def render(entries):
            calls.append(entries)
            return composition if entries else None
        store = LatestBoxes(renderer=render, clock=self.clock)
        store.publish([[20,30,200,300]], [0.9], [0], ('person',),
                      1_000_000_000, 9.95)
        element, errors = Element(), []
        renderer = SimpleNamespace(metrics=lambda: {})
        overlay = CachedCompositionOverlay(element, store, renderer, errors.append, self.clock)
        for offset in range(10):
            sample = SimpleNamespace(get_buffer=lambda: SimpleNamespace(pts=1_000_000_000+offset*10_000_000))
            self.assertIs(element.handlers['draw'](element, sample), composition)
        self.assertEqual(len(calls), 1)
        self.assertEqual(overlay.boxed, 10)
        store.publish([], [], [], ('person',), 1_100_000_000, 9.98)
        sample = SimpleNamespace(get_buffer=lambda: SimpleNamespace(pts=1_100_000_000))
        self.assertIsNone(overlay.draw(element, sample))
        self.assertEqual(len(calls), 2)
        self.assertFalse(errors)

    def test_cached_results_expire_and_reject_future_frames(self):
        store = LatestBoxes(renderer=lambda _entries: object(), clock=self.clock)
        store.publish([[20,30,200,300]], [0.9], [0], ('person',),
                      1_000_000_000, 9.95)
        overlay = CachedCompositionOverlay(Element(), store, None, self.fail, self.clock)
        def sample(pts):
            return SimpleNamespace(get_buffer=lambda: SimpleNamespace(pts=pts))
        self.assertIsNone(overlay.draw(None, sample(999_000_000)))
        self.assertEqual(overlay.future, 1)
        self.clock.now += 0.3
        self.assertIsNone(overlay.draw(None, sample(1_100_000_000)))
        self.assertEqual(overlay.expired, 1)

    def test_stage_probe_pairs_buffers_by_pts_across_threads(self):
        class Pad:
            def add_probe(self, _kind, callback):
                self.callback = callback
                return 1
        class ProbedElement(Element):
            def __init__(self):
                super().__init__()
                self.pads = {'sink': Pad(), 'src': Pad()}
            def get_static_pad(self, name):
                return self.pads[name]
        Gst = SimpleNamespace(PadProbeType=SimpleNamespace(BUFFER=1),
                              PadProbeReturn=SimpleNamespace(OK=0))
        element = ProbedElement()
        overlay = CachedCompositionOverlay(element, LatestBoxes(clock=self.clock), None,
                                           self.fail, clock=self.clock, Gst=Gst)
        info = SimpleNamespace(get_buffer=lambda: SimpleNamespace(pts=1234))
        element.pads['sink'].callback(element.pads['sink'], info)
        self.clock.now += 0.020
        worker = threading.Thread(target=element.pads['src'].callback,
                                  args=(element.pads['src'], info))
        worker.start()
        worker.join()
        self.assertEqual(overlay.stage_frames, 1)
        self.assertEqual(overlay.stage_inputs, 1)
        self.assertEqual(overlay.stage_outputs, 1)
        self.assertAlmostEqual(overlay.stage_s, 0.020)
        self.assertEqual(overlay.stage_unmatched, 0)

    def test_composition_tiles_bounded_and_cache_reuses_native_objects(self):
        buffers = []
        class Buffer:
            @staticmethod
            def new_allocate(_allocator, size, _params):
                result = Buffer()
                result.size = size
                buffers.append(result)
                return result
            def fill(self, _offset, data):
                self.data = data
                return len(data)
        class Composition:
            def __init__(self, rectangle):
                self.rectangles = [rectangle]
            @classmethod
            def new(cls, rectangle):
                return cls(rectangle)
            def add_rectangle(self, rectangle):
                self.rectangles.append(rectangle)
        class Surface:
            def __init__(self, _fmt, width, height):
                self.width, self.height = width, height
            def flush(self):
                pass
            def get_data(self):
                return bytes(self.width * self.height * 4)
        context = Context()
        Gst = SimpleNamespace(Buffer=Buffer)
        GstVideo = SimpleNamespace(buffer_add_video_meta=lambda *x: object(),
            VideoFrameFlags=SimpleNamespace(NONE=0), VideoFormat=SimpleNamespace(BGRA=1),
            VideoOverlayFormatFlags=SimpleNamespace(PREMULTIPLIED_ALPHA=1),
            VideoOverlayRectangle=SimpleNamespace(new_raw=lambda *x: x),
            VideoOverlayComposition=Composition)
        cairo = SimpleNamespace(ImageSurface=Surface, FORMAT_ARGB32=0,
                                Context=lambda surface: context)
        renderer = CompositionRenderer(Gst, GstVideo, cairo, clock=self.clock)
        entries = (((20,30,1800,1000), 'person 0.90'),)
        composition = renderer(entries)
        self.assertEqual(len(composition.rectangles), 5)
        self.assertTrue(all(b.size < 20000 for b in buffers))
        self.assertIs(renderer(entries), composition)
        self.assertEqual(len(buffers), 5)
        self.assertEqual(renderer.metrics()['cache_reuses'], 1)
        self.assertIsNone(renderer(()))
        self.assertEqual(renderer.metrics()['tiles'], 0)

    def test_inference_pacing_interrupt_and_no_catchup_bursts(self):
        clock = self.clock
        class Stop:
            stopped = False
            def is_set(self):
                return self.stopped
            def wait(self, delay):
                clock.now += delay
                return self.stopped
        stop, pacer = Stop(), InferencePacer(30, clock)
        starts = []
        for _ in range(5):
            self.assertTrue(pacer.wait(stop))
            starts.append(clock.now)
            clock.now += 0.024
        for a, b in zip(starts, starts[1:]):
            self.assertAlmostEqual(b - a, 1 / 30)
        clock.now += 0.2  # A slow inference does not cause catch-up submissions.
        self.assertTrue(pacer.wait(stop))
        after_slow = clock.now
        self.assertTrue(pacer.wait(stop))
        self.assertAlmostEqual(clock.now - after_slow, 1 / 30)
        stop.stopped = True
        self.assertFalse(pacer.wait(stop))
        for invalid in (-1, 61, float('nan'), float('inf')):
            with self.assertRaises(ValueError):
                InferencePacer(invalid)


def gst_smoke(frames):
    import gi
    gi.require_version('Gst', '1.0')
    from gi.repository import Gst, GLib
    from yolo_async_overlay import check_composition_overlay
    Gst.init(None)
    GstVideo, cairo = check_composition_overlay(Gst)
    # Exercise the production tee/conversion/OSD/composition path, replacing camera
    # and KMS with a live test source and a pixel-verifying appsink.
    description = build_pipeline(args_for(),
        'appsink name=rendered caps="video/x-raw,format=RGB" '
        'emit-signals=true sync=false max-buffers=1 drop=true')
    description = (f'videotestsrc is-live=true num-buffers={frames} pattern=black ! '
                   'video/x-raw,format=RGB,width=1920,height=1080,framerate=60/1 ! '
                   'tee name=decoded ' + description.split('tee name=decoded ', 1)[1])
    pipeline = Gst.parse_launch(description)
    loop, stop, errors = GLib.MainLoop(), threading.Event(), []
    counts = {'rendered': 0, 'inferred': 0, 'green': False}
    display_times = {'first': None, 'last': None}
    renderer = CompositionRenderer(Gst, GstVideo, cairo)
    store = LatestBoxes(renderer=renderer)
    def fail(error):
        errors.append(str(error))
        GLib.idle_add(loop.quit)
    overlay = CachedCompositionOverlay(pipeline.get_by_name('box_overlay'), store, renderer, fail, Gst=Gst)
    def output_sample(sink):
        sample = sink.emit('pull-sample')
        if sample is None:
            return Gst.FlowReturn.EOS
        counts['rendered'] += 1
        now = time.monotonic()
        if display_times['first'] is None:
            display_times['first'] = now
        display_times['last'] = now
        if not counts['green'] and counts['inferred']:
            buffer = sample.get_buffer()
            ok, mapped = buffer.map(Gst.MapFlags.READ)
            if ok:
                try:
                    # Cairo antialiases the 2px line, so scan a narrow ROI
                    # instead of requiring one exact fully-covered pixel.
                    # Fetch MapInfo.data only ONCE: some PyGObject versions
                    # marshal/copy the whole 8 MiB frame on each access.
                    pixels = mapped.data
                    stride = 1920 * 3
                    for y in range(297, 304):
                        for x in range(297, 704):
                            pos = y * stride + x * 3
                            red, green, blue = pixels[pos:pos+3]
                            if green >= 48 and green > red + 24 and green > blue + 24:
                                counts['green'] = True
                                break
                        if counts['green']:
                            break
                    del pixels
                finally:
                    buffer.unmap(mapped)
        return Gst.FlowReturn.OK
    pipeline.get_by_name('rendered').connect('new-sample', output_sample)
    def simulated_inference():
        sink = pipeline.get_by_name('infer')
        while not stop.is_set():
            sample = sink.emit('try-pull-sample', 100 * Gst.MSECOND)
            if sample is None:
                continue
            acquired, pts = time.monotonic(), sample.get_buffer().pts
            del sample
            if stop.wait(0.04):  # Deliberately ~25 FPS, slower than the video branch.
                break
            store.publish([[300, 300, 700, 650]], [0.9], [0], ('person', 'car'), pts, acquired)
            counts['inferred'] += 1
    def message(_bus, msg):
        if msg.type == Gst.MessageType.ERROR:
            fail(msg.parse_error())
        elif msg.type == Gst.MessageType.EOS:
            loop.quit()
    def timeout():
        fail('GStreamer synthetic test timed out')
        return False
    bus = pipeline.get_bus()
    bus.add_signal_watch()
    bus.connect('message', message)
    GLib.timeout_add_seconds(20, timeout)
    thread = threading.Thread(target=simulated_inference, daemon=True)
    try:
        thread.start()
        if pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            raise RuntimeError('Cannot start GStreamer synthetic test')
        loop.run()
    finally:
        stop.set()
        pipeline.set_state(Gst.State.NULL)
        thread.join(timeout=2)
    if errors or thread.is_alive():
        raise RuntimeError(f'GStreamer overlay test failed: {errors}; worker_alive={thread.is_alive()}')
    elapsed = ((display_times['last'] - display_times['first'])
               if display_times['first'] is not None else 0)
    display_fps = (counts['rendered'] - 1) / elapsed if elapsed > 0 else 0
    print(f'GST_SMOKE source_frames={frames} rendered={counts["rendered"]} '
          f'display_span_s={elapsed:.3f} measured_output_fps={display_fps:.3f}')
    if not counts['green'] or counts['inferred'] < 5 or counts['rendered'] < 1.4 * counts['inferred']:
        raise AssertionError(f'Pixel/delayed-inference independence test failed: {counts}; {overlay.report()}')
    print('PASS GST 1080p async boxes:', counts)
    print(overlay.report())
    print('Synthetic source and delayed worker only; this is not camera/NPU/HDMI FPS validation.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gst', action='store_true')
    parser.add_argument('--gst-frames', type=int, default=180)
    args = parser.parse_args()
    if not 60 <= args.gst_frames <= 600:
        parser.error('--gst-frames must be 60..600')
    result = unittest.main(argv=['test_yolo_async_overlay.py'], verbosity=2, exit=False).result
    if not result.wasSuccessful():
        raise SystemExit(1)
    if args.gst:
        gst_smoke(args.gst_frames)
