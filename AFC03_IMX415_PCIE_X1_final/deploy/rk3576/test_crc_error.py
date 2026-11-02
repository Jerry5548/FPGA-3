#!/usr/bin/env python3
"""Negative tests for payload CRC and frame integrity."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from lz77_decode import decode_frame
p = Path(__file__).resolve().parent/'test_vectors'/'sample_frame.lz77'
b = bytearray(p.read_bytes())
# Payload byte corruption must be rejected by the footer CRC.
b[20] ^= 0x01
try:
    decode_frame(bytes(b))
except ValueError as e:
    assert 'CRC32' in str(e)
    print('PASS corrupted payload rejected:', e)
else:
    raise SystemExit('CRC corruption was not detected')
