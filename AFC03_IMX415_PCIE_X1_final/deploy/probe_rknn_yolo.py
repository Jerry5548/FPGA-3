#!/usr/bin/env python3
"""Load an RKNN model, run one zero frame, and report its raw output heads.

This is a model/runtime probe only: it does not open the camera, display, DMA,
or change FPGA registers. Run on the RK3576 Python environment.
"""
import argparse
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('model', type=Path)
    parser.add_argument('--input-order', choices=('RGB', 'BGR'), default='BGR')
    args = parser.parse_args()
    if not args.model.is_file():
        parser.error(f'model not found: {args.model}')
    import numpy as np
    from rknnlite.api import RKNNLite
    from rknn_yolo_backend import classify_yolo_heads

    runtime = RKNNLite()
    try:
        rc = runtime.load_rknn(str(args.model.resolve()))
        if rc != 0:
            raise RuntimeError(f'load_rknn failed: {rc}')
        rc = runtime.init_runtime(core_mask=RKNNLite.NPU_CORE_0)
        if rc != 0:
            raise RuntimeError(f'init_runtime failed: {rc}')
        sample = np.zeros((1, 640, 640, 3), dtype=np.uint8)
        outputs = runtime.inference(inputs=[sample])
        print(f'MODEL={args.model.resolve()}')
        print(f'INPUT shape={sample.shape} dtype={sample.dtype} order={args.input_order}')
        for i, output in enumerate(outputs if outputs is not None else ()):
            if output is None:
                print(f'HEAD{i} shape=None')
                continue
            arr = np.asarray(output)
            if arr.size:
                print(f'HEAD{i} shape={arr.shape} dtype={arr.dtype} min={arr.min()} max={arr.max()}')
            else:
                print(f'HEAD{i} shape={arr.shape} dtype={arr.dtype} empty')
        names = classify_yolo_heads(outputs)
        print(f'PROFILE classes={len(names)} names={names}')
        print('PASS RKNN load/init/inference and three-head shape validation')
        print('Zero input checks runtime and shapes only; verify colors, labels and boxes on known images.')
    finally:
        runtime.release()
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        sys.exit(1)
