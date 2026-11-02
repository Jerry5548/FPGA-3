#!/usr/bin/env python3
"""Optional RKNN YOLOv5s inference on the decoded stream, without C2H access."""
import threading
import time
import importlib
import sys
import math
from pathlib import Path


COCO80_NAMES = (
    'person', 'bicycle', 'car', 'motorcycle', 'airplane', 'bus', 'train', 'truck',
    'boat', 'traffic light', 'fire hydrant', 'stop sign', 'parking meter', 'bench',
    'bird', 'cat', 'dog', 'horse', 'sheep', 'cow', 'elephant', 'bear', 'zebra',
    'giraffe', 'backpack', 'umbrella', 'handbag', 'tie', 'suitcase', 'frisbee',
    'skis', 'snowboard', 'sports ball', 'kite', 'baseball bat', 'baseball glove',
    'skateboard', 'surfboard', 'tennis racket', 'bottle', 'wine glass', 'cup',
    'fork', 'knife', 'spoon', 'bowl', 'banana', 'apple', 'sandwich', 'orange',
    'broccoli', 'carrot', 'hot dog', 'pizza', 'donut', 'cake', 'chair', 'couch',
    'potted plant', 'bed', 'dining table', 'toilet', 'tv', 'laptop', 'mouse',
    'remote', 'keyboard', 'cell phone', 'microwave', 'oven', 'toaster', 'sink',
    'refrigerator', 'book', 'clock', 'vase', 'scissors', 'teddy bear',
    'hair drier', 'toothbrush'
)
PERSON_CAR_NAMES = ('person', 'car')
YOLO_GRIDS = (80, 40, 20)


def classify_yolo_heads(outputs):
    """Identify the supported raw YOLOv5 head layouts.

    RKNN may return either the flattened NCHW form ``[1,3*(5+nc),H,W]``
    or the explicit-anchor form ``[1,3,5+nc,H,W]``.  Both carry the same
    values and are accepted deliberately; other layouts are rejected rather
    than guessed from the total element count.
    """
    if outputs is None or len(outputs) != 3:
        raise RuntimeError(f'Expected three YOLOv5 output heads, got {0 if outputs is None else len(outputs)}')
    class_count = None
    for index, (out, grid) in enumerate(zip(outputs, YOLO_GRIDS)):
        if out is None or not hasattr(out, 'shape'):
            raise RuntimeError(f'YOLO head {index} has no usable shape: {out!r}')
        shape = tuple(int(x) for x in out.shape)
        current = None
        if len(shape) == 4 and shape[0] == 1 and shape[2:] == (grid, grid):
            channels = shape[1]
            if channels % 3 == 0:
                current = channels // 3 - 5
        elif (len(shape) == 5 and shape[0] == 1 and shape[1] == 3
              and shape[3:] == (grid, grid)):
            current = shape[2] - 5
        if current is None:
            raise RuntimeError(
                f'YOLO head {index} expected [1,3*(5+nc),{grid},{grid}] '
                f'or [1,3,5+nc,{grid},{grid}], got {shape}')
        if current not in (2, 80):
            raise RuntimeError(f'Unsupported YOLO class count {current}; supported profiles are COCO80 and person/car2')
        if class_count is None:
            class_count = current
        elif current != class_count:
            raise RuntimeError(f'YOLO head class counts disagree: {class_count} vs {current}')
    return PERSON_CAR_NAMES if class_count == 2 else COCO80_NAMES


def resolve_model(model, search_dirs=None):
    """Resolve a model, never execute an official camera-owning launch script."""
    if str(model) == 'auto':
        if search_dirs is None:
            search_dirs = [Path('/home/linaro/rock/yolo'),
                           Path(__file__).resolve().parent / 'yolo',
                           Path('/home/rock/yolo')]
        candidates = [Path(folder) / 'yolov5s_relu.rknn' for folder in search_dirs]
        path = next((p for p in candidates if p.is_file()), None)
        if path is None:
            raise FileNotFoundError('YOLO model not found. Checked: ' +
                                    ', '.join(str(p) for p in candidates))
    else:
        path = Path(model).expanduser()
    if path.suffix.lower() != '.rknn':
        raise ValueError('YOLO_MODEL must name a .rknn model, not a .py/.sh launch script')
    if not path.is_file():
        raise FileNotFoundError(f'YOLO model missing: {path}. Set the actual .rknn path or YOLO_MODEL=auto')
    if path.stat().st_size == 0:
        raise ValueError(f'YOLO model is empty: {path}')
    return path.resolve()


def check_dependencies(model):
    resolve_model(model)
    for name in ('cv2', 'numpy', 'rknnlite.api'):
        try:
            module = importlib.import_module(name)
            if name == 'rknnlite.api' and not hasattr(module, 'RKNNLite'):
                raise ImportError('RKNNLite class missing')
        except (ImportError, OSError) as exc:
            raise RuntimeError(f'{sys.executable}: cannot load {name}: {exc}. '
                               'Use the Python environment that runs the official YOLO program.') from exc


class InferencePacer:
    """Limit sample acquisition, while the appsink continues to keep its latest frame."""
    def __init__(self, max_fps=30, clock=time.monotonic):
        if not math.isfinite(max_fps) or not 0 <= max_fps <= 60:
            raise ValueError('YOLO maximum FPS must be 0..60 (0 means unlimited)')
        self.period = 1 / max_fps if max_fps else 0
        self.clock, self.next_at = clock, 0.0

    def wait(self, stop):
        if stop.is_set():
            return False
        delay = max(0.0, self.next_at - self.clock())
        if delay and stop.wait(delay):
            return False
        self.next_at = self.clock() + self.period
        return not stop.is_set()


class YoloWorker:
    def __init__(self, model, sink, Gst, on_stats, on_error, input_order='BGR', on_frame=None,
                 on_result=None, max_fps=30):
        self.model, self.sink, self.Gst = model, sink, Gst
        self.on_stats, self.on_error = on_stats, on_error
        self.input_order = input_order
        self.on_frame = on_frame
        self.on_result = on_result
        self.pacer = InferencePacer(max_fps)
        self.stop = threading.Event()
        self.ready = threading.Event()
        self.error = None
        self.thread = threading.Thread(target=self.run, name='rknn-yolo', daemon=True)

    def start(self):
        self.thread.start()
        if not self.ready.wait(30):
            self.stop.set()
            raise RuntimeError('RKNN initialization timed out')
        if self.error:
            raise RuntimeError(self.error)

    def close(self):
        self.stop.set()
        self.thread.join(timeout=2)

    def run(self):
        runtime = None
        try:
            import cv2
            import numpy as np
            from rknnlite.api import RKNNLite
            from yolo_reference import letterbox, postprocess_yolov5s
            from yolo_draw import draw_results_rgb
            runtime = RKNNLite()
            code = runtime.load_rknn(str(self.model))
            if code != 0:
                raise RuntimeError(f'load_rknn failed: {code}')
            code = runtime.init_runtime(core_mask=RKNNLite.NPU_CORE_0)
            if code != 0:
                raise RuntimeError(f'init_runtime failed: {code}')
            self.ready.set()
            reported_at = time.monotonic()
            completed = total = 0
            rate = None
            stages = dict(throttle=0.0, wait=0.0, pre=0.0, npu=0.0, post=0.0, draw=0.0, push=0.0)
            while not self.stop.is_set():
                throttling = time.monotonic()
                if not self.pacer.wait(self.stop):
                    break
                stages['throttle'] += time.monotonic() - throttling
                waiting = time.monotonic()
                sample = self.sink.emit('try-pull-sample', 200 * self.Gst.MSECOND)
                if sample is None:
                    self.stop.wait(0.02)
                    stages['wait'] += time.monotonic() - waiting
                    continue
                stages['wait'] += time.monotonic() - waiting
                acquired_at = time.monotonic()
                preparing = time.monotonic()
                caps = sample.get_caps().get_structure(0)
                if (caps.get_value('width'), caps.get_value('height'), caps.get_value('format')) != (1920, 1080, 'RGB'):
                    raise RuntimeError('YOLO expects decoded 1920x1080 RGB24')
                buffer = sample.get_buffer()
                source_pts = buffer.pts
                ok, mapped = buffer.map(self.Gst.MapFlags.READ)
                if not ok:
                    raise RuntimeError('Cannot map YOLO input frame')
                try:
                    if len(mapped.data) != 1920 * 1080 * 3:
                        raise RuntimeError('Unexpected RGB stride/size for YOLO input')
                    image = np.frombuffer(mapped.data, dtype=np.uint8).reshape(1080, 1920, 3)
                    # Retain only this inference frame, before V4L2/DMA buffer reuse.
                    display_frame = image.copy() if self.on_frame is not None else None
                    small, ratio, dw, dh = letterbox(image, 640)
                    # Official sample sends BGR to this particular model.
                    # Convert after resize to avoid full-frame channel swapping.
                    if self.input_order == 'BGR':
                        small = cv2.cvtColor(small, cv2.COLOR_RGB2BGR)
                    model_input = np.ascontiguousarray(small[None, ...])
                    del image
                finally:
                    buffer.unmap(mapped)
                del sample, buffer
                stages['pre'] += time.monotonic() - preparing
                started = time.monotonic()
                outputs = runtime.inference(inputs=[model_input])
                npu_ms = (time.monotonic() - started) * 1000
                stages['npu'] += npu_ms / 1000
                post_started = time.monotonic()
                class_names = classify_yolo_heads(outputs)
                boxes, scores, classes = postprocess_yolov5s(outputs, ratio, dw, dh, 1920, 1080)
                stages['post'] += time.monotonic() - post_started
                if self.on_result is not None and not self.stop.is_set():
                    publishing = time.monotonic()
                    self.on_result(boxes, scores, classes, class_names, source_pts,
                                   acquired_at, total + 1)
                    stages['push'] += time.monotonic() - publishing
                if self.on_frame is not None and not self.stop.is_set():
                    drawing = time.monotonic()
                    draw_results_rgb(display_frame, boxes, scores, classes, class_names)
                    stages['draw'] += time.monotonic() - drawing
                    pushing = time.monotonic()
                    self.on_frame(display_frame, total + 1)
                    stages['push'] += time.monotonic() - pushing
                completed += 1
                total += 1
                now = time.monotonic()
                if now - reported_at >= 0.5:
                    rate = completed / (now - reported_at)
                    detail = ' '.join(f'{key}_ms={1000 * value / completed:.3f}'
                                      for key, value in stages.items())
                    print(f'YOLO_PERF samples={completed} {detail} '
                          f'cycle_ms={1000 * (now - reported_at) / completed:.3f}', flush=True)
                    stages = dict.fromkeys(stages, 0.0)
                    completed = 0
                    reported_at = now
                    print(f'YOLO frames={total} fps={rate:.3f} npu_ms={npu_ms:.3f} detections={len(boxes)}', flush=True)
                self.on_stats(rate, npu_ms, len(boxes))
                del display_frame
                del model_input, small, outputs, boxes, scores, classes
        except Exception as exc:
            self.error = str(exc)
            self.on_error(self.error)
        finally:
            self.ready.set()
            if runtime is not None:
                runtime.release()
