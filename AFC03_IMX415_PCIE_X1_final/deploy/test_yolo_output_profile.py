#!/usr/bin/env python3
"""Dependency-free checks for COCO80 and person/car 3-head dispatch."""
import unittest

from rknn_yolo_backend import classify_yolo_heads, COCO80_NAMES, PERSON_CAR_NAMES


class Head:
    def __init__(self, shape):
        self.shape = shape


def heads(channels):
    return [Head((1, channels, grid, grid)) for grid in (80, 40, 20)]


def anchor_heads(attributes):
    return [Head((1, 3, attributes, grid, grid)) for grid in (80, 40, 20)]


class OutputProfileTests(unittest.TestCase):
    def test_person_car_int8_three_heads(self):
        self.assertEqual(classify_yolo_heads(heads(21)), PERSON_CAR_NAMES)
        self.assertEqual(PERSON_CAR_NAMES, ('person', 'car'))

    def test_official_coco_three_heads(self):
        self.assertEqual(classify_yolo_heads(heads(255)), COCO80_NAMES)
        self.assertEqual(len(COCO80_NAMES), 80)

    def test_person_car_explicit_anchor_heads(self):
        self.assertEqual(classify_yolo_heads(anchor_heads(7)), PERSON_CAR_NAMES)

    def test_official_coco_explicit_anchor_heads(self):
        self.assertEqual(classify_yolo_heads(anchor_heads(85)), COCO80_NAMES)

    def test_rejects_single_head(self):
        with self.assertRaisesRegex(RuntimeError, 'three'):
            classify_yolo_heads(heads(21)[:1])
        with self.assertRaisesRegex(RuntimeError, 'three'):
            classify_yolo_heads(None)
        with self.assertRaisesRegex(RuntimeError, 'three'):
            classify_yolo_heads([])

    def test_rejects_wrong_grid_or_class_count(self):
        with self.assertRaisesRegex(RuntimeError, 'expected'):
            classify_yolo_heads([Head((1, 21, 80, 80)), Head((1, 21, 40, 40)), Head((1, 21, 20, 19))])
        with self.assertRaisesRegex(RuntimeError, 'class count'):
            classify_yolo_heads([Head((1, 21, 80, 80)), Head((1, 255, 40, 40)), Head((1, 21, 20, 20))])
        with self.assertRaisesRegex(RuntimeError, 'Unsupported'):
            classify_yolo_heads(heads(24))

    def test_rejects_invalid_anchor_layout(self):
        with self.assertRaisesRegex(RuntimeError, 'expected'):
            classify_yolo_heads([Head((1, 2, 7, 80, 80)), Head((1, 3, 7, 40, 40)), Head((1, 3, 7, 20, 20))])
        with self.assertRaisesRegex(RuntimeError, 'expected'):
            classify_yolo_heads([Head((1, 3, 7, 80, 80)), Head((1, 3, 7, 40, 40)), Head((1, 3, 7, 20, 20, 1))])
        with self.assertRaisesRegex(RuntimeError, 'no usable shape'):
            classify_yolo_heads([None, Head((1, 3, 7, 40, 40)), Head((1, 3, 7, 20, 20))])

    def test_rejects_batch_channel_last_and_reversed_grids(self):
        for shape in ((2, 3, 7, 80, 80), (2, 21, 80, 80),
                      (1, 80, 80, 21), (1, 80, 80, 3, 7), (1, 22, 80, 80)):
            with self.subTest(shape=shape):
                with self.assertRaisesRegex(RuntimeError, 'expected'):
                    classify_yolo_heads([Head(shape)] + anchor_heads(7)[1:])
        with self.assertRaisesRegex(RuntimeError, 'expected'):
            classify_yolo_heads(anchor_heads(7)[::-1])

    def test_rejects_inconsistent_explicit_class_counts(self):
        with self.assertRaisesRegex(RuntimeError, 'class counts disagree'):
            classify_yolo_heads([anchor_heads(7)[0], anchor_heads(85)[1], anchor_heads(7)[2]])
        with self.assertRaisesRegex(RuntimeError, 'Unsupported'):
            classify_yolo_heads(anchor_heads(8))

    def test_per_head_layouts_have_same_class_profile(self):
        self.assertEqual(classify_yolo_heads([heads(21)[0], anchor_heads(7)[1], heads(21)[2]]),
                         PERSON_CAR_NAMES)


if __name__ == '__main__':
    unittest.main(verbosity=2)
