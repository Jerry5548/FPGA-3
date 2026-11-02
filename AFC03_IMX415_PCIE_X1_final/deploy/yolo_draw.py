"""Draw model results onto their own RGB frame, without changing colour order."""
import math


def prepare_boxes(boxes, scores, classes, names, width, height):
    if not (len(boxes) == len(scores) == len(classes)):
        raise ValueError('Mismatched detection arrays')
    result = []
    for box, score, cid in zip(boxes, scores, classes):
        values = [float(v) for v in box]
        score = float(score)
        if len(values) != 4 or not all(math.isfinite(v) for v in values + [score]):
            continue
        x1, y1, x2, y2 = values
        x1, x2 = [max(0, min(width - 1, int(x))) for x in (x1, x2)]
        y1, y2 = [max(0, min(height - 1, int(y))) for y in (y1, y2)]
        if x2 <= x1 or y2 <= y1:
            continue
        cid = int(cid)
        name = names[cid] if 0 <= cid < len(names) else str(cid)
        result.append(((x1, y1, x2, y2), f'{name} {score:.2f}'))
    return result


def draw_results_rgb(image, boxes, scores, classes, names):
    import cv2
    height, width = image.shape[:2]
    for (x1, y1, x2, y2), label in prepare_boxes(boxes, scores, classes, names, width, height):
        # OpenCV writes tuples as supplied. Green/white are identical in RGB/BGR;
        # the entire frame must remain RGB for the display appsrc.
        cv2.rectangle(image, (x1, y1), (x2, y2), (0, 255, 0), 2)
        (tw, th), baseline = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.6, 1)
        tx = max(0, min(x1, width - tw - 4))
        ty = max(th + 3, y1 - 4)
        ty = min(ty, height - baseline - 1)
        cv2.rectangle(image, (tx, max(0, ty-th-3)),
                      (min(width-1, tx+tw+4), min(height-1, ty+baseline)), (0, 0, 0), -1)
        cv2.putText(image, label, (tx+2, ty), cv2.FONT_HERSHEY_SIMPLEX,
                    0.6, (255, 255, 255), 1, cv2.LINE_AA)
    return image
