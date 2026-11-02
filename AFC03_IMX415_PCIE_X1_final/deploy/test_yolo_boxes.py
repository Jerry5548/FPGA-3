#!/usr/bin/env python3
"""Box/label checks; --pixels additionally checks the installed OpenCV renderer."""
import argparse
from yolo_draw import prepare_boxes, draw_results_rgb


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--pixels', action='store_true')
    args = ap.parse_args()
    boxes = prepare_boxes([[-4, -2, 200, 120], [10, 10, 8, 8],
                           [float('nan'), 1, 5, 5], [1, 2, 8, 9]],
                          [0.9, 0.7, 0.8, 0.5], [0, 0, 0, -1], ['person'], 160, 96)
    assert boxes == [((0, 0, 159, 95), 'person 0.90'), ((1, 2, 8, 9), '-1 0.50')], boxes
    assert prepare_boxes([], [], [], [], 160, 96) == []
    try:
        prepare_boxes([[0, 0, 4, 4]], [], [0], ['person'], 160, 96)
    except ValueError:
        pass
    else:
        raise AssertionError('Mismatched detection arrays accepted')
    print('PASS box coordinates: clipping, invalid/empty boxes, labels and array lengths')
    if not args.pixels:
        print('Pixel rendering pending: run --pixels on the board with numpy/OpenCV')
        return
    import cv2
    import numpy as np
    print('OpenCV:', cv2.__version__, cv2.__file__)
    original = np.empty((96, 160, 3), dtype=np.uint8)
    original[:] = (17, 34, 51)
    original.flags.writeable = False
    display = original.copy()
    result = draw_results_rgb(display, [[20, 30, 120, 80]], [0.9], [0], ['person'])
    assert result is display
    assert tuple(display[80, 70]) == (0, 255, 0)
    assert tuple(display[95, 159]) == (17, 34, 51)
    assert np.all(original == np.array((17, 34, 51), dtype=np.uint8))
    assert not np.array_equal(display, original)
    empty = original.copy()
    draw_results_rgb(empty, [], [], [], [])
    assert np.array_equal(empty, original)
    print('PASS OpenCV pixels: visible box, untouched source, RGB preserved, empty frame unchanged')


if __name__ == '__main__':
    main()
