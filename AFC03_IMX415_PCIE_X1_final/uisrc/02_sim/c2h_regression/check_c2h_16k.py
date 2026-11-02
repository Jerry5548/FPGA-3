#!/usr/bin/env python3
"""Check the 16 KiB C2H RTL capture against its source bytes and CRC."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parents[2] / 'rk3576'))
from lz77_decode import decode_frame

stream = bytes.fromhex((ROOT / 'c2h_16k.hex').read_text())
raw_expected = bytes.fromhex((ROOT / 'c2h_16k_raw.hex').read_text())
assert stream.startswith(b'LZ77')
end = stream.find(b'END!', 16)
assert end >= 0, 'missing frame footer after 16 KiB EOP boundaries'
frame = stream[:end + 20]
raw, meta = decode_frame(frame, expect_rgb24=True)
assert meta['frame_id'] == 77 and meta['width'] == 192 and meta['height'] == 144
assert raw == raw_expected and len(raw) == 192 * 144 * 3
assert end + 20 == len(stream), f'unexpected trailing C2H bytes: {len(stream)-end-20}'
print('PASS C2H 16 KiB capture: exact RGB24 bytes, frame ID, footer, lengths and CRC')
