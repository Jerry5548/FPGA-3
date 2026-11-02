#!/usr/bin/env python3
"""Numerical 4D/5D raw-head regressions; no RKNN, OpenCV or camera required."""
import unittest

import numpy as np

from rknn_yolo_backend import classify_yolo_heads
from yolo_reference import ANCHORS, postprocess_yolov5s


def heads(class_count):
    return [np.zeros((1, 3, 5 + class_count, grid, grid), dtype=np.float32)
            for grid in (80, 40, 20)]


def flatten(outputs):
    return [out.reshape(1, -1, *out.shape[-2:]) for out in outputs]


def decode(outputs, sparse=True):
    classify_yolo_heads(outputs)
    return postprocess_yolov5s(outputs, 1 / 3, 0, 140, 1920, 1080, sparse=sparse)


def put(out, anchor, row, col, class_id, obj=0.9, score=0.8):
    values = out[0, anchor, :, row, col]
    values[:4] = 0.5
    values[4] = obj
    values[5 + class_id] = score


class HeadLayoutTests(unittest.TestCase):
    def assert_results_equal(self, actual, expected):
        for a, b in zip(actual, expected):
            np.testing.assert_array_equal(a, b)

    def test_known_person_car_boxes_and_letterbox(self):
        outputs = heads(2)
        put(outputs[0], 0, 30, 40, 0)
        put(outputs[1], 0, 20, 20, 1)
        for layout in (outputs, flatten(outputs)):
            for sparse in (False, True):
                boxes, scores, classes = decode(layout, sparse)
                order = np.argsort(classes)
                np.testing.assert_array_equal(classes[order], [0, 1])
                np.testing.assert_array_equal(boxes[order], [[957, 292, 987, 331],
                                                            [939, 472, 1029, 655]])
                np.testing.assert_allclose(scores[order], [0.72, 0.72], atol=1e-7)

    def test_all_three_scales_and_anchors(self):
        for class_count in (2, 80):
            for scale in range(3):
                for anchor in range(3):
                    with self.subTest(classes=class_count, scale=scale, anchor=anchor):
                        outputs = heads(class_count)
                        grid = outputs[scale].shape[-1]
                        row = col = grid // 2
                        put(outputs[scale], anchor, row, col, class_count - 1)
                        center = (col + 0.5) * (640 // grid)
                        width, height = ANCHORS[scale * 3 + anchor]
                        expected = np.array([[center - width / 2, center - height / 2,
                                              center + width / 2, center + height / 2]])
                        for sparse in (False, True):
                            for layout in (outputs, flatten(outputs)):
                                boxes, _, classes = postprocess_yolov5s(
                                    layout, 1.0, 0, 0, 640, 640, sparse=sparse)
                                np.testing.assert_array_equal(boxes, expected.astype(np.int32))
                                np.testing.assert_array_equal(classes, [class_count - 1])

    def test_random_layout_dense_sparse_equivalence_and_input_preserved(self):
        for class_count in (2, 80):
            for seed in range(4):
                rng = np.random.default_rng(seed)
                outputs = heads(class_count)
                for out in outputs:
                    out[:] = rng.random(out.shape, dtype=np.float32)
                    out[:, :, 4] *= 0.44
                    for _ in range(12):
                        anchor = int(rng.integers(3))
                        row, col = rng.integers(out.shape[-1], size=2)
                        put(out, anchor, row, col, int(rng.integers(class_count)))
                originals = [out.copy() for out in outputs]
                expected = decode(flatten(outputs), False)
                for layout in (outputs, flatten(outputs)):
                    for sparse in (False, True):
                        self.assert_results_equal(decode(layout, sparse), expected)
                for actual, original in zip(outputs, originals):
                    np.testing.assert_array_equal(actual, original)

    def test_per_class_nms_for_person_and_car(self):
        outputs = heads(2)
        put(outputs[0], 0, 30, 40, 0, obj=0.9)
        put(outputs[0], 1, 30, 40, 0, obj=0.8)
        put(outputs[0], 2, 30, 40, 1, obj=0.7)
        for anchor in (1, 2):
            width, height = ANCHORS[anchor]
            outputs[0][0, anchor, 2:4, 30, 40] = np.sqrt([10 / width, 13 / height]) / 2
        for layout in (outputs, flatten(outputs)):
            for sparse in (False, True):
                boxes, scores, classes = decode(layout, sparse)
                np.testing.assert_array_equal(np.sort(classes), [0, 1])
                np.testing.assert_allclose(np.sort(scores), [0.56, 0.72], atol=1e-7)
                self.assertEqual(boxes.shape, (2, 4))

    def test_empty_outputs_both_profiles(self):
        for class_count in (2, 80):
            for layout in (heads(class_count), flatten(heads(class_count))):
                for sparse in (False, True):
                    boxes, scores, classes = decode(layout, sparse)
                    self.assertEqual(boxes.shape, (0, 4))
                    self.assertEqual(scores.shape, (0,))
                    self.assertEqual(classes.shape, (0,))


if __name__ == '__main__':
    unittest.main(verbosity=2)
