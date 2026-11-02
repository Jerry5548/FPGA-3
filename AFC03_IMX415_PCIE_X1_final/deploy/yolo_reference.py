"""Postprocessing adapted from user-supplied official RK3576 YOLOv5s reference.
Source SHA256: da1d576c2cf1151ccda11c7219f83885ee1db0c8105f1a970447eaa92b7d3f67
Only model constants and pure preprocessing/postprocessing are retained.
No camera capture, display, autostart, or board setup runs at import.
"""
import numpy as np

IMG_SIZE   = 640

CLASS_NAMES = [
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
]

OBJ_THRESH = 0.45

NMS_THRESH = 0.45

MASKS   = [[0, 1, 2], [3, 4, 5], [6, 7, 8]]

ANCHORS = [[10, 13], [16, 30], [33, 23], [30, 61], [62, 45],
           [59, 119], [116, 90], [156, 198], [373, 326]]

def letterbox(img, new_shape=640, color=(0, 0, 0)):
    import cv2
    h, w = img.shape[:2]
    r = min(new_shape / h, new_shape / w)
    new_w, new_h = int(w * r), int(h * r)
    dw = (new_shape - new_w) / 2
    dh = (new_shape - new_h) / 2
    img_resized = cv2.resize(img, (new_w, new_h), interpolation=cv2.INTER_LINEAR)
    top    = int(round(dh - 0.1))
    bottom = int(round(dh + 0.1))
    left   = int(round(dw - 0.1))
    right  = int(round(dw + 0.1))
    img_padded = cv2.copyMakeBorder(
        img_resized, top, bottom, left, right,
        cv2.BORDER_CONSTANT, value=color
    )
    return img_padded, r, dw, dh

def xywh2xyxy(x):
    y = np.zeros_like(x)
    y[:, 0] = x[:, 0] - x[:, 2] / 2
    y[:, 1] = x[:, 1] - x[:, 3] / 2
    y[:, 2] = x[:, 0] + x[:, 2] / 2
    y[:, 3] = x[:, 1] + x[:, 3] / 2
    return y

def process(input, mask, anchors):
    anchors = [anchors[i] for i in mask]
    grid_h, grid_w = map(int, input.shape[0:2])
    box_confidence = np.expand_dims(input[..., 4], axis=-1)
    box_class_probs = input[..., 5:]
    box_xy = input[..., :2] * 2 - 0.5
    col = np.tile(np.arange(0, grid_w), grid_w).reshape(-1, grid_w)
    row = np.tile(np.arange(0, grid_h).reshape(-1, 1), grid_h)
    col = col.reshape(grid_h, grid_w, 1, 1).repeat(3, axis=-2)
    row = row.reshape(grid_h, grid_w, 1, 1).repeat(3, axis=-2)
    grid = np.concatenate((col, row), axis=-1)
    box_xy += grid
    box_xy *= int(IMG_SIZE / grid_h)
    box_wh = pow(input[..., 2:4] * 2, 2)
    box_wh = box_wh * anchors
    return np.concatenate((box_xy, box_wh), axis=-1), box_confidence, box_class_probs

def filter_boxes(boxes, box_confidences, box_class_probs):
    boxes = boxes.reshape(-1, 4)
    box_confidences = box_confidences.reshape(-1)
    box_class_probs = box_class_probs.reshape(-1, box_class_probs.shape[-1])
    _box_pos = np.where(box_confidences >= OBJ_THRESH)
    boxes = boxes[_box_pos]
    box_confidences = box_confidences[_box_pos]
    box_class_probs = box_class_probs[_box_pos]
    class_max_score = np.max(box_class_probs, axis=-1)
    classes = np.argmax(box_class_probs, axis=-1)
    _class_pos = np.where(class_max_score >= OBJ_THRESH)
    return boxes[_class_pos], classes[_class_pos], (class_max_score * box_confidences)[_class_pos]

def nms_boxes(boxes, scores):
    x = boxes[:, 0]
    y = boxes[:, 1]
    w = boxes[:, 2] - boxes[:, 0]
    h = boxes[:, 3] - boxes[:, 1]
    areas = w * h
    order = scores.argsort()[::-1]
    keep = []
    while order.size > 0:
        i = order[0]
        keep.append(i)
        xx1 = np.maximum(x[i], x[order[1:]])
        yy1 = np.maximum(y[i], y[order[1:]])
        xx2 = np.minimum(x[i] + w[i], x[order[1:]] + w[order[1:]])
        yy2 = np.minimum(y[i] + h[i], y[order[1:]] + h[order[1:]])
        w1 = np.maximum(0.0, xx2 - xx1 + 0.00001)
        h1 = np.maximum(0.0, yy2 - yy1 + 0.00001)
        inter = w1 * h1
        ovr = inter / (areas[i] + areas[order[1:]] - inter)
        inds = np.where(ovr <= NMS_THRESH)[0]
        order = order[inds + 1]
    return np.array(keep)

def _sparse_candidates(out, mask):
    """Filter first; decode coordinates only for candidates the reference keeps.

    Thresholds, score product, anchor order and NMS remain unchanged. Keep
    float32 XY and float64 anchor products to match the official arithmetic.
    """
    data = out.reshape([3, -1] + list(out.shape[-2:]))
    data = np.transpose(data, (2, 3, 0, 1))
    rows, cols, anchor_ids = np.nonzero(data[..., 4] >= OBJ_THRESH)
    candidates = data[rows, cols, anchor_ids]
    class_probs = candidates[:, 5:]
    class_max = np.max(class_probs, axis=-1)
    classes = np.argmax(class_probs, axis=-1)
    selected = class_max >= OBJ_THRESH
    candidates = candidates[selected]
    rows, cols, anchor_ids = rows[selected], cols[selected], anchor_ids[selected]
    classes = classes[selected]
    scores = class_max[selected] * candidates[:, 4]
    xy = candidates[:, :2] * 2 - 0.5
    xy += np.column_stack((cols, rows))
    xy *= int(IMG_SIZE / data.shape[0])
    anchors = np.asarray(ANCHORS, dtype=np.int64)[mask][anchor_ids]
    wh = pow(candidates[:, 2:4] * 2, 2) * anchors
    return np.concatenate((xy, wh), axis=-1), classes, scores


def postprocess_yolov5s(outputs, ratio, dw, dh, src_w, src_h, sparse=True):
    boxes, classes, scores = [], [], []
    for out, mask in zip(outputs, MASKS):
        if sparse:
            b, c, s = _sparse_candidates(out, mask)
        else:
            data = out.reshape([3, -1] + list(out.shape[-2:]))
            data = np.transpose(data, (2, 3, 0, 1))
            b, c, s = process(data, mask, ANCHORS)
            b, c, s = filter_boxes(b, c, s)
        boxes.append(b)
        classes.append(c)
        scores.append(s)
    if not boxes:
        return np.empty((0, 4), dtype=int), np.empty((0,)), np.empty((0,), dtype=int)
    boxes = np.concatenate(boxes)
    boxes = xywh2xyxy(boxes)
    classes = np.concatenate(classes)
    scores = np.concatenate(scores)
    nboxes, nclasses, nscores = [], [], []
    for c in set(classes.tolist()):
        inds = np.where(classes == c)
        b = boxes[inds]
        s = scores[inds]
        keep = nms_boxes(b, s)
        nboxes.append(b[keep])
        nclasses.append(classes[inds][keep])
        nscores.append(s[keep])
    if not nboxes:
        return np.empty((0, 4), dtype=int), np.empty((0,)), np.empty((0,), dtype=int)
    boxes = np.concatenate(nboxes)
    scores = np.concatenate(nscores)
    classes = np.concatenate(nclasses)
    boxes[:, [0, 2]] = (boxes[:, [0, 2]] - dw) / ratio
    boxes[:, [1, 3]] = (boxes[:, [1, 3]] - dh) / ratio
    boxes[:, 0] = np.clip(boxes[:, 0], 0, src_w)
    boxes[:, 1] = np.clip(boxes[:, 1], 0, src_h)
    boxes[:, 2] = np.clip(boxes[:, 2], 0, src_w)
    boxes[:, 3] = np.clip(boxes[:, 3], 0, src_h)
    return boxes.astype(np.int32), scores, classes.astype(np.int32)
