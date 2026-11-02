#!/usr/bin/env python3
"""RGB24 FIFO or V4L2 display with top-left measured FPS and optional YOLO."""
import argparse
import math
import re
import signal
import sys
import time
from pathlib import Path

MODES = {0: 'ORIGINAL', 1: 'GRAY', 2: 'GAUSSIAN', 3: 'HE',
         4: 'GAUSSIAN+HE', 5: 'GRAY+MEDIAN', 6: 'GRAY+SOBEL', 8: 'LOWLIGHT', 9: 'DEHAZE'}


def gst_quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def build_pipeline(args, video_sink):
    """Build independently queued live display/inference branches.

    stats keeps live display independent of NPU; boxes/boxes-sync display only
    the source frame copied by the YOLO worker after that frame's inference.
    """
    capture_enabled = bool(getattr(args, 'capture_control', None))
    async_boxes = (bool(args.yolo_model) and args.yolo_view == 'stats' and
                   not getattr(args, 'yolo_kms_overlay', False))
    if args.video_device is not None:
        description = ('v4l2src device=' + gst_quote(args.video_device) +
                       ' io-mode=' + args.io_mode + ' ! '
                       'video/x-raw,width=1920,height=1080,format=RGB,framerate=60/1 ! ')
    else:
        if args.fifo is None or args.rx_log is None:
            raise ValueError('Provide --video-device, or both --fifo and --rx-log')
        description = ('filesrc location=' + gst_quote(args.fifo) + ' blocksize=65536 ! '
                       'rawvideoparse format=rgb width=1920 height=1080 framerate=60/1 ! ')
    infer_tail = ('queue name=infer_queue max-size-buffers=1 max-size-bytes=0 max-size-time=0 '
                  'leaky=downstream ! appsink name=infer max-buffers=1 drop=true '
                  'sync=false async=false emit-signals=false ')
    if args.yolo_model or capture_enabled:
        description += 'tee name=decoded decoded. ! '
    description += ('queue name=display_queue max-size-buffers=1 max-size-bytes=0 '
                    'max-size-time=0 leaky=downstream ! ')
    if not args.headless:
        description += 'videoconvert ! '
        if async_boxes:
            # Keep native negotiated video format. The callback only returns
            # cached sparse BGRA strips/labels, never paints the video surface.
            description += 'overlaycomposition name=box_overlay ! '
        description += (
            f'textoverlay name=osd font-desc="Monospace {args.font_size}" '
            'auto-resize=false line-alignment=left '
            'halignment=left valignment=top xpad=16 ypad=12 '
            'color=4294967295 outline-color=4278190080 '
            'draw-shadow=false draw-outline=true shaded-background=false ! videoconvert ! ')
    description += ('fpsdisplaysink name=fps text-overlay=false '
                    'sync=false signal-fps-measurements=true fps-update-interval=500 '
                    'video-sink=' + gst_quote(video_sink))
    if args.yolo_model:
        description += ' decoded. ! ' + infer_tail
    if capture_enabled:
        description += (' decoded. ! queue name=capture_queue max-size-buffers=1 '
                        'max-size-bytes=0 max-size-time=0 leaky=downstream ! '
                        'appsink name=capture_tap emit-signals=true sync=false async=false '
                        'max-buffers=1 drop=true ')
    return description


def build_sync_pipelines(args, video_sink):
    """Separate capture/appsink inference from appsrc display for YOLO-paced boxes."""
    if args.video_device is not None:
        capture = ('v4l2src device=' + gst_quote(args.video_device) +
                   ' io-mode=' + args.io_mode + ' ! '
                   'video/x-raw,width=1920,height=1080,format=RGB,framerate=60/1 ! ')
    else:
        if args.fifo is None or args.rx_log is None:
            raise ValueError('Provide --video-device, or both --fifo and --rx-log')
        capture = ('filesrc location=' + gst_quote(args.fifo) + ' blocksize=65536 ! '
                   'rawvideoparse format=rgb width=1920 height=1080 framerate=60/1 ! ')
    capture += ('queue name=infer_queue max-size-buffers=1 max-size-bytes=0 max-size-time=0 '
                'leaky=downstream ! appsink name=infer max-buffers=1 drop=true '
                'sync=false async=false emit-signals=false')
    display = ('appsrc name=annotated is-live=true format=time do-timestamp=true '
               'block=true max-bytes=6220800 min-latency=0 '
               'caps="video/x-raw,format=RGB,width=1920,height=1080,framerate=60/1" ! '
               'queue name=display_queue max-size-buffers=1 max-size-bytes=0 '
               'max-size-time=0 leaky=downstream ! ')
    if not args.headless:
        display += ('videoconvert ! '
                    f'textoverlay name=osd font-desc="Monospace {args.font_size}" '
                    'auto-resize=false line-alignment=left '
                    'halignment=left valignment=top xpad=16 ypad=12 '
                    'color=4294967295 outline-color=4278190080 '
                    'draw-shadow=false draw-outline=true shaded-background=false ! videoconvert ! ')
    display += ('fpsdisplaysink name=fps text-overlay=false '
                'sync=false signal-fps-measurements=true fps-update-interval=500 '
                'video-sink=' + gst_quote(video_sink))
    return capture, display


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true')
    ap.add_argument('--headless', action='store_true',
                    help='Benchmark with fakesink; omit OSD, conversion and KMS display')
    source = ap.add_mutually_exclusive_group()
    source.add_argument('--fifo', type=Path)
    source.add_argument('--video-device', type=Path)
    ap.add_argument('--io-mode', choices=['mmap', 'dmabuf'], default='mmap')
    ap.add_argument('--rx-log', type=Path)
    ap.add_argument('--connector', type=int, default=188)
    ap.add_argument('--mode', type=int, choices=MODES, default=1)
    ap.add_argument('--yolo-model', type=Path)
    ap.add_argument('--yolo-input-order', choices=['BGR', 'RGB'], default='BGR')
    ap.add_argument('--yolo-view', choices=['stats', 'boxes', 'boxes-sync'], default='stats',
                    help='stats: independent display + latest boxes; boxes/boxes-sync: '
                         'display only inferred frames at the YOLO rate')
    ap.add_argument('--yolo-max-fps', type=float, default=30,
                    help='Maximum inference sample rate, 0 disables the limit (default 30)')
    ap.add_argument('--yolo-box-ttl-ms', type=float, default=250,
                    help='Maximum detection age for async boxes, including inference time (default 250 ms)')
    ap.add_argument('--yolo-kms-overlay', action='store_true',
                    help='Stats only: send cached boxes to verified DRM plane 108 (1280x800 HDMI mode)')
    ap.add_argument('--ready-file', type=Path)
    ap.add_argument('--capture-control', type=Path,
                    help='enable on-demand snapshot/record controls on this Unix socket')
    ap.add_argument('--capture-dir', type=Path,
                    help='directory for JPEG screenshots and MKV recordings')
    ap.add_argument('--video-encoder',
                    help='optional H.264 encoder factory override for recording')
    ap.add_argument('--font-size', type=int, default=16)
    args = ap.parse_args()
    if not 8 <= args.font_size <= 32:
        ap.error('--font-size must be between 8 and 32')
    if not math.isfinite(args.yolo_max_fps) or not 0 <= args.yolo_max_fps <= 60:
        ap.error('--yolo-max-fps must be 0..60 (0 means unlimited)')
    if not math.isfinite(args.yolo_box_ttl_ms) or not 50 <= args.yolo_box_ttl_ms <= 2000:
        ap.error('--yolo-box-ttl-ms must be 50..2000')
    sync_boxes = bool(args.yolo_model) and args.yolo_view in ('boxes', 'boxes-sync')
    if bool(args.capture_control) != bool(args.capture_dir):
        ap.error('--capture-control and --capture-dir must be supplied together')
    if args.capture_control and sync_boxes:
        ap.error('capture control currently requires stats or YOLO-disabled playback')
    if args.yolo_kms_overlay and (not args.yolo_model or args.yolo_view != 'stats' or args.headless):
        ap.error('--yolo-kms-overlay requires YOLO_MODEL, YOLO_VIEW=stats and a visible display')
    async_boxes = bool(args.yolo_model) and args.yolo_view == 'stats' and not args.headless
    if args.yolo_kms_overlay:
        async_boxes = True
    if args.yolo_model:
        from rknn_yolo_backend import resolve_model
        try:
            args.yolo_model = resolve_model(args.yolo_model)
        except (OSError, ValueError) as exc:
            raise SystemExit(str(exc))
        print(f'YOLO model: {args.yolo_model}', flush=True)
    try:
        import gi
        gi.require_version('Gst', '1.0')
        from gi.repository import Gst, GLib
        Gst.init(None)
    except (ImportError, ValueError) as exc:
        raise SystemExit('Python GStreamer bindings unavailable (python3-gi / gir1.2-gstreamer-1.0): ' + str(exc))
    if args.yolo_kms_overlay:
        kms_check = Gst.ElementFactory.make('kmssink', None)
        if kms_check is None or kms_check.find_property('plane-id') is None:
            raise SystemExit('YOLO_KMS_OVERLAY requires kmssink with a plane-id property')
        try:
            import cairo  # noqa: F401
        except ImportError as exc:
            raise SystemExit('YOLO_KMS_OVERLAY requires python3-cairo: ' + str(exc)) from exc
    if args.capture_control:
        for factory in ('tee', 'appsink', 'jpegenc'):
            if Gst.ElementFactory.find(factory) is None:
                raise SystemExit(f'VIDEO_CAPTURE requires GStreamer element {factory}')
    if async_boxes and not args.yolo_kms_overlay:
        from yolo_async_overlay import check_composition_overlay
        try:
            check_composition_overlay(Gst)
        except RuntimeError as exc:
            raise SystemExit(str(exc))
    if sync_boxes and Gst.ElementFactory.find('appsrc') is None:
        raise SystemExit('Synchronous boxes require GStreamer appsrc')
    if args.check:
        if args.yolo_model:
            from rknn_yolo_backend import check_dependencies
            try:
                check_dependencies(args.yolo_model)
            except (RuntimeError, OSError, ValueError) as exc:
                raise SystemExit(str(exc))
        if args.yolo_kms_overlay:
            from yolo_kms_plane import check_daemon_build
            try:
                check_daemon_build()
            except (RuntimeError, OSError) as exc:
                raise SystemExit(str(exc))
        # Parse the exact selected graph before the shell script enables FPGA
        # capture, including both halves of the synchronous appsink/appsrc path.
        try:
            if sync_boxes:
                capture_graph, display_graph = build_sync_pipelines(
                    args, 'fakesink sync=false async=false')
                preflight_graphs = [Gst.parse_launch(capture_graph),
                                    Gst.parse_launch(display_graph)]
            else:
                preflight_graphs = [Gst.parse_launch(
                    build_pipeline(args, 'fakesink sync=false async=false'))]
            for preflight in preflight_graphs:
                preflight.set_state(Gst.State.NULL)
            del preflight_graphs
        except Exception as exc:
            raise SystemExit(f'GStreamer pipeline preflight failed before capture: {exc}') from exc
        print('Python GStreamer bindings available; pipeline parse preflight passed')
        return 0
    video_sink = 'fakesink sync=false async=false'
    if not args.headless:
        kms = Gst.ElementFactory.make('kmssink', None)
        if kms is None:
            raise SystemExit('GStreamer kmssink unavailable')
        video_sink = 'kmssink connector-id=' + str(args.connector) + ' sync=false'
        # sync=false disables GstBaseSink scheduling, but not KMS's own
        # vblank wait. An extra wait can halve a 60 Hz display to 30 FPS.
        if kms.find_property('skip-vsync') is not None:
            video_sink += ' skip-vsync=true'
            print('KMS skip-vsync=true (avoid extra vblank wait)', flush=True)
        else:
            print('KMS skip-vsync unavailable; this plugin may still halve display FPS. '
                  'Update kmssink to a build supporting skip-vsync.',
                  file=sys.stderr, flush=True)
    try:
        if sync_boxes:
            capture_description, description = build_sync_pipelines(args, video_sink)
        else:
            capture_description = None
            description = build_pipeline(args, video_sink)
    except ValueError as exc:
        ap.error(str(exc))
    pipeline = Gst.parse_launch(description)
    capture_pipeline = (Gst.parse_launch(capture_description)
                        if capture_description is not None else pipeline)
    capture_manager = None
    if args.capture_control:
        from video_capture import VideoCaptureManager
        capture_manager = VideoCaptureManager(pipeline, Gst, GLib,
                                              args.capture_control, args.capture_dir,
                                              encoder=getattr(args, 'video_encoder', None),
                                              logger=lambda line: print(line, flush=True))
    print('YOLO view: ' + (args.yolo_view if args.yolo_model else 'disabled'), flush=True)
    print(f'VIDEO headless={int(args.headless)} mode={args.mode} input_order={args.yolo_input_order}', flush=True)
    print('PIPELINE ' + description, flush=True)
    annotated = pipeline.get_by_name('annotated') if sync_boxes else None
    osd = pipeline.get_by_name('osd')
    loop = GLib.MainLoop()
    display_fps = rx_fps = None
    display_time = rx_time = 0.0
    rx_offset = 0
    pending = ''
    result = 0
    worker = None
    yolo_fps = npu_ms = None
    yolo_time = 0.0
    detection_count = 0
    last_text = None
    overlay = store = None
    kms_overlay = None

    def push_annotated(image, sequence):
        data = image.tobytes()
        buffer = Gst.Buffer.new_allocate(None, len(data), None)
        buffer.fill(0, data)
        buffer.offset = sequence
        # The synchronous display is intentionally paced by completed inference.
        status = annotated.emit('push-buffer', buffer)
        if status != Gst.FlowReturn.OK and not worker.stop.is_set():
            raise RuntimeError(f'Annotated display push failed: {status}')

    def refresh():
        nonlocal last_text
        if osd is None:
            return
        now = time.monotonic()
        def number(value, updated):
            if value is None:
                return '--'
            return f'{value if now-updated < 3.0 else 0.0:.1f}'
        if args.yolo_model:
            npu = '--' if npu_ms is None else f'{npu_ms:.1f}'
            yolo_line = (f'YOLO FPS:{number(yolo_fps, yolo_time)}  NPU:{npu}ms '
                         f'DET:{detection_count} {args.yolo_view.upper()}'
                         + (' ASYNC' if async_boxes else (' SYNC' if sync_boxes else '')))
        else:
            yolo_line = 'YOLO FPS:-- (NOT CONNECTED)'
        transport = ('COMP:OFF' if args.video_device is not None else
                     f'LZ77:{number(rx_fps, rx_time)}')
        text = (f'1920x1080 FPS:{number(display_fps, display_time)} '
                f'{transport} {MODES[args.mode]}\n' + yolo_line)
        if text != last_text:
            osd.set_property('text', text)
            last_text = text

    def apply_yolo(fps, npu, detections):
        nonlocal yolo_fps, npu_ms, yolo_time, detection_count
        yolo_fps, npu_ms = fps, npu
        yolo_time = time.monotonic()
        detection_count = detections
        return False

    def yolo_error(error):
        nonlocal result
        print('YOLO error: ' + error, file=sys.stderr, flush=True)
        result = 1
        loop.quit()
        return False

    def apply_fps(value):
        nonlocal display_fps, display_time
        display_fps = value
        display_time = time.monotonic()
        source_name = 'V4L2' if args.video_device is not None else 'LZ77'
        metric = 'OUTPUT' if args.headless else 'DISPLAY'
        print(f'{metric} source={source_name} fps={value:.3f}', flush=True)
        return False

    def measured(_sink, fps, _drop, _average):
        GLib.idle_add(apply_fps, fps)

    def poll_receiver():
        nonlocal rx_offset, pending, rx_fps, rx_time
        if overlay is not None:
            print(overlay.report(), flush=True)
        if args.video_device is not None:
            refresh()
            return True
        try:
            with args.rx_log.open('rb') as src:
                src.seek(rx_offset)
                data = src.read(65536)
                rx_offset = src.tell()
            pending += data.decode('utf-8', errors='replace')
            lines = pending.split('\n')
            pending = lines.pop()
            for line in lines:
                if not line.startswith('PERF '):
                    continue
                match = re.search(r'\binterval_fps=([0-9.]+)', line)
                if match:
                    rx_fps = float(match[1])
                    rx_time = time.monotonic()
        except FileNotFoundError:
            pass
        refresh()
        return True

    def message(_bus, msg):
        nonlocal result
        if msg.type == Gst.MessageType.ERROR:
            error, debug = msg.parse_error()
            print(f'GStreamer error: {error}\n{debug}', file=sys.stderr, flush=True)
            result = 1
            loop.quit()
        elif msg.type == Gst.MessageType.EOS:
            loop.quit()

    pipeline.get_by_name('fps').connect('fps-measurements', measured)
    for active_pipeline in ([pipeline, capture_pipeline]
                            if capture_pipeline is not pipeline else [pipeline]):
        bus = active_pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect('message', message)
    GLib.timeout_add(500, poll_receiver)
    for sig in (signal.SIGINT, signal.SIGTERM):
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, lambda: (loop.quit(), False)[1])
    refresh()
    try:
        if args.yolo_model:
            from rknn_yolo_backend import YoloWorker
            if async_boxes:
                from yolo_async_overlay import LatestBoxes
                if args.yolo_kms_overlay:
                    from yolo_kms_plane import KmsPlaneOverlay
                    store = LatestBoxes(ttl_ms=args.yolo_box_ttl_ms)
                    kms_overlay = KmsPlaneOverlay(Gst, connector=args.connector, plane=108,
                                                  ttl_ms=args.yolo_box_ttl_ms,
                                                  on_error=lambda error: GLib.idle_add(yolo_error, error))
                    overlay = kms_overlay
                    print(f'ASYNC_BOXES enabled=1 view=stats backend=drm-plane plane=108 '
                          f'mode=1280x800 ttl_ms={args.yolo_box_ttl_ms:g}', flush=True)
                else:
                    from yolo_async_overlay import (CompositionRenderer,
                                                   CachedCompositionOverlay)
                    GstVideo, cairo = check_composition_overlay(Gst)
                    renderer = CompositionRenderer(Gst, GstVideo, cairo)
                    store = LatestBoxes(ttl_ms=args.yolo_box_ttl_ms, renderer=renderer)
                    overlay = CachedCompositionOverlay(pipeline.get_by_name('box_overlay'), store,
                        renderer, lambda error: GLib.idle_add(yolo_error, error), Gst=Gst)
                    print(f'ASYNC_BOXES enabled=1 view={args.yolo_view} '
                          f'backend=cached-composition format=native max_age_ms={args.yolo_box_ttl_ms:g} '
                          'max_boxes=64 result_slots=1 timestamp_guard=1', flush=True)
            elif sync_boxes:
                print(f'SYNC_BOXES enabled=1 view={args.yolo_view} '
                      'display_follows_completed_inference=1 full_frame_copy=1', flush=True)
            print(f'YOLO max_fps={args.yolo_max_fps:g} (0=unlimited)', flush=True)
            def publish_boxes(*values):
                accepted = store.publish(*values)
                if accepted and kms_overlay is not None:
                    snapshot = store.latest()
                    if snapshot is not None:
                        kms_overlay.publish(snapshot.entries, snapshot.acquired_at,
                                            snapshot.sequence)
                return accepted
            worker = YoloWorker(args.yolo_model, capture_pipeline.get_by_name('infer'), Gst,
                                lambda *values: GLib.idle_add(apply_yolo, *values),
                                lambda error: GLib.idle_add(yolo_error, error),
                                args.yolo_input_order,
                                on_frame=push_annotated if sync_boxes else None,
                                on_result=publish_boxes if async_boxes and store is not None else None,
                                max_fps=args.yolo_max_fps)
            worker.start()
        if pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            print('Cannot start GStreamer display', file=sys.stderr)
            return 1
        if capture_pipeline is not pipeline:
            if capture_pipeline.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
                print('Cannot start GStreamer capture/inference', file=sys.stderr)
                return 1
        if kms_overlay is not None:
            kms_overlay.start()
        if capture_manager is not None:
            capture_manager.start()
        if args.ready_file:
            args.ready_file.write_text('ready\n', encoding='ascii')
        loop.run()
    finally:
        if worker:
            worker.stop.set()
        if capture_pipeline is not pipeline:
            capture_pipeline.set_state(Gst.State.NULL)
        if kms_overlay:
            kms_overlay.close()
        if capture_manager:
            capture_manager.close()
        pipeline.set_state(Gst.State.NULL)
        if worker:
            worker.close()
    return result


if __name__ == '__main__':
    raise SystemExit(main())
