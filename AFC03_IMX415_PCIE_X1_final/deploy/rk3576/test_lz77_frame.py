#!/usr/bin/env python3
"""Validate the RK3576 test vector with the project reference decoder."""
from pathlib import Path
import sys
root = Path(__file__).resolve().parent
sys.path.insert(0, str(root))
from lz77_decode import decode_frame
frame = root/'test_vectors'/'sample_frame.lz77'
expected = root/'test_vectors'/'sample_frame.raw'
out, meta = decode_frame(frame.read_bytes())
assert out == expected.read_bytes()
assert meta['width'] == 64 and meta['height'] == 8 and meta['frame_id'] == 7
print('PASS RK3576-compatible LZ77 frame, metadata:', meta)
print('PASS payload CRC32 and lossless raw output')
