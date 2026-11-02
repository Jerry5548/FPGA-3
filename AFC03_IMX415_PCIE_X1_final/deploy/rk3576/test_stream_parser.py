#!/usr/bin/env python3
"""Exercise stream framing with arbitrary DMA read fragment sizes."""
from pathlib import Path
import random, struct, sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from lz77_decode import decode_frame
from make_test_frame import make_frame

frames = [make_frame(bytes([x])*((x % 13)+5) + bytes(range(17)), 32, 2, x) for x in range(1, 6)]
stream = b''.join(frames)
random.seed(3576)
acc = bytearray(); got = []
pos = 0
while pos < len(stream):
    n = min(random.randint(1, 37), len(stream)-pos)
    acc.extend(stream[pos:pos+n]); pos += n
    while True:
        if len(acc) < 16: break
        if acc[:4] != b'LZ77': raise AssertionError('lost frame alignment')
        end = acc.find(b'END!', 16)
        if end < 0: break
        frame_end = end + 20
        if len(acc) < frame_end: break
        frame = bytes(acc[:frame_end])
        # Decode only once the complete footer is present.
        out, meta = decode_frame(frame)
        got.append((meta['frame_id'], len(out)))
        del acc[:frame_end]
assert not acc
assert [x[0] for x in got] == [1,2,3,4,5]
print('PASS fragmented C2H stream framing:', got)
