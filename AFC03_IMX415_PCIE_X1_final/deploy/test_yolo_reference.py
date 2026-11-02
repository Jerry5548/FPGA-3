#!/usr/bin/env python3
"""Board-side postprocessor smoke test; does not initialize the NPU."""
import numpy as np
from yolo_reference import postprocess_yolov5s, letterbox

heads = [np.zeros((1, 255, n, n), dtype=np.float32) for n in (80, 40, 20)]
boxes, scores, classes = postprocess_yolov5s(heads, 1/3, 0, 140, 1920, 1080)
assert len(boxes) == len(scores) == len(classes) == 0
heads[0][0, :4, 40, 40] = 0.5
heads[0][0, 4, 40, 40] = 0.9
heads[0][0, 5, 40, 40] = 0.8
boxes, scores, classes = postprocess_yolov5s(heads, 1/3, 0, 140, 1920, 1080)
assert len(boxes) == 1 and classes[0] == 0
assert abs(float(scores[0]) - 0.72) < 0.001
assert boxes[0, 2] > boxes[0, 0] and boxes[0, 3] > boxes[0, 1]
image, ratio, dw, dh = letterbox(np.zeros((1080, 1920, 3), dtype=np.uint8))
assert image.shape == (640, 640, 3) and dw == 0 and dh == 140
print('PASS YOLO reference: empty heads, one known detection, 1080p letterbox')
