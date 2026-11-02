#!/usr/bin/env python3
"""Model discovery checks without RKNN, OpenCV, GStreamer, or hardware."""
import tempfile
from pathlib import Path
from rknn_yolo_backend import resolve_model

with tempfile.TemporaryDirectory() as td:
    root = Path(td)
    official, local = root / 'official', root / 'deploy'
    official.mkdir()
    local.mkdir()
    fallback = local / 'yolov5s_relu.rknn'
    fallback.write_bytes(b'fixture')
    assert resolve_model('auto', [official, local]) == fallback.resolve()
    preferred = official / fallback.name
    preferred.write_bytes(b'fixture')
    assert resolve_model('auto', [official, local]) == preferred.resolve()
    assert resolve_model(fallback) == fallback.resolve()
    for invalid, expected in [(root / 'missing.rknn', FileNotFoundError),
                              (root / 'rk3576_yolov5s_pcie.py', ValueError)]:
        try:
            resolve_model(invalid, [official, local])
        except expected:
            pass
        else:
            raise AssertionError(f'Invalid explicit path silently accepted: {invalid}')
    try:
        resolve_model('auto', [root / 'absent'])
    except FileNotFoundError:
        pass
    else:
        raise AssertionError('Missing automatic model accepted')
print('PASS: auto priority/fallback, explicit path, missing model and launch script rejected')
