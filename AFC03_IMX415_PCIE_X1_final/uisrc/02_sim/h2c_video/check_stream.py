"""Check actual H2V1 RTL output against independent pixels and BLK1 CRC/IDs."""
from pathlib import Path
import argparse
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'rk3576'))
from lz77_decode import decode_frame

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('folder', type=Path)
p.add_argument('--width', type=int, required=True)
p.add_argument('--height', type=int, required=True)
p.add_argument('--frames', type=int, required=True)
p.add_argument('--block', type=int, required=True)
a = p.parse_args()
wire = (a.folder / 'stream.bin').read_bytes()
words = (a.folder / 'expected.hex').read_text().split()
offset = 0
groups = a.width * a.height // 4
for index in range(a.frames):
    start = offset
    assert wire[start:start+4] == b'LZ77'
    assert wire[start+8:start+12] == b'BLK1'
    pos = start+16
    count = 0
    while count < a.width*a.height*3:
        kind = wire[pos]
        raw = int.from_bytes(wire[pos+1:pos+4], 'little')
        stored = struct.unpack_from('<I', wire, pos+4)[0]
        assert kind in (0, 1) and 0 < raw <= a.block and 0 < stored <= raw
        count += raw
        pos += 8+stored
    assert count == a.width*a.height*3 and wire[pos:pos+4] == b'END!'
    output, meta = decode_frame(wire[start:pos+20], expect_rgb24=True)
    expected = bytearray()
    for text in words[index*groups:(index+1)*groups]:
        b = int(text, 16).to_bytes(16, 'little')
        for k in (0, 4, 8, 12):
            expected += b[k:k+3][::-1]
    assert output == expected, f'pixel mismatch frame {index+1}'
    assert meta['frame_id'] == index+1
    assert meta['width'] == a.width and meta['height'] == a.height
    offset = pos+20
assert offset == len(wire), 'trailing or missing frame'
print(f'PASS H2V1 -> shared preprocessing -> RGB24 -> BLK1: {a.frames} exact frames, CRC, RGB order, IDs')
