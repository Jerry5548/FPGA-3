#!/usr/bin/env python3
"""Equivalence and offline timing only; does not load RKNN or open video."""
import argparse
import time
import numpy as np
from yolo_reference import postprocess_yolov5s


def fixture(seed, count):
    rng = np.random.default_rng(seed)
    heads = [rng.random((1, 255, n, n), dtype=np.float32) for n in (80, 40, 20)]
    for head in heads:
        shaped = head.reshape(1, 3, 85, head.shape[-2], head.shape[-1])
        shaped[:, :, 4] *= 0.44
        for _ in range(count):
            anchor = rng.integers(0, 3)
            row, col = rng.integers(0, head.shape[-1], size=2)
            shaped[0, anchor, 4, row, col] = rng.choice([0.45, 0.6, 0.9])
            shaped[0, anchor, 5:, row, col] = 0.1
            shaped[0, anchor, rng.integers(5, 85), row, col] = rng.choice([0.44, 0.45, 0.8])
    return heads


def process(heads, sparse):
    return postprocess_yolov5s(heads, 1 / 3, 0, 140, 1920, 1080, sparse=sparse)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--iterations', type=int, default=30)
    args = ap.parse_args()
    if args.iterations < 1:
        ap.error('--iterations must be positive')
    for seed in range(24):
        heads = fixture(seed, seed * 4)
        expected, actual = process(heads, False), process(heads, True)
        for old, new in zip(expected, actual):
            np.testing.assert_array_equal(new, old)
        # Verify neither implementation writes into NPU output tensors.
        for original, again in zip(heads, fixture(seed, seed * 4)):
            np.testing.assert_array_equal(original, again)
    # All objectness candidates survive, but class probabilities fail: validate
    # the empty-result path after the second threshold, too.
    dense_rejected = [np.full((1, 255, n, n), 0.44, dtype=np.float32) for n in (80, 40, 20)]
    for head in dense_rejected:
        head.reshape(1, 3, 85, head.shape[-2], head.shape[-1])[:, :, 4] = 0.9
    for old, new in zip(process(dense_rejected, False), process(dense_rejected, True)):
        np.testing.assert_array_equal(new, old)
    print('PASS: exact boxes/scores/classes for 25 empty/sparse/threshold fixtures; input preserved')
    for label, heads in [('empty', fixture(1, 0)), ('sparse', fixture(2, 30))]:
        for sparse in (False, True):
            for _ in range(3):
                process(heads, sparse)
            timings = []
            for _ in range(args.iterations):
                start = time.perf_counter()
                process(heads, sparse)
                timings.append((time.perf_counter() - start) * 1000)
            print(f'POST_BENCH {label} sparse={int(sparse)} '
                  f'mean_ms={np.mean(timings):.3f} p95_ms={np.percentile(timings, 95):.3f}')
    print('Synthetic postprocessor only; not camera/NPU/display FPS or detection accuracy.')


if __name__ == '__main__':
    main()
