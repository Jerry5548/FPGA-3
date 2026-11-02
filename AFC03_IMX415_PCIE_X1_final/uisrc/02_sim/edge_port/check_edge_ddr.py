"""Compare decoded RGB24 against independent median/Sobel image references."""
from pathlib import Path
import sys
import argparse
import struct

here = Path(__file__).resolve().parent
sys.path.insert(0, str(here.parents[2] / 'rk3576'))
from lz77_decode import decode_frame
ap=argparse.ArgumentParser()
ap.add_argument('--blk1',action='store_true')
args=ap.parse_args()

for mode, name in [(5, 'median'), (6, 'sobel')]:
    words = [int(w, 16) for w in (here / 'vectors_16x16' / f'{name}.hex').read_text().split()]
    gray = b''.join(w.to_bytes(4, 'little') for w in words)
    suffix='_blk1' if args.blk1 else ''
    stream = bytes.fromhex((here / f'edge{mode}{suffix}.hex').read_text())
    for fid in range(1, 5):
        if args.blk1:
            assert stream[8:12]==b'BLK1'
            end=16
            while stream[end:end+4]!=b'END!':
                assert stream[end] in (0,1)
                stored=struct.unpack_from('<I',stream,end+4)[0]
                assert 0<stored<=256
                end+=8+stored
        else:
            end = stream.find(b'END!', 16)
        assert end >= 0, (mode, fid, 'missing footer')
        raw, meta = decode_frame(stream[:end + 20], expect_rgb24=True)
        expected = bytes(v for y in gray[fid * 256:(fid + 1) * 256] for v in (y, y, y))
        assert meta['frame_id'] == fid and meta['width'] == meta['height'] == 16, meta
        assert raw == expected and len(raw) == 768, (mode, fid)
        stream = stream[end + 20:]
    assert not stream, (mode, 'extra stream')
    print(f'PASS mode {mode} DDR/LZ77 decode: RGB24 pixels, geometry, CRC and capture IDs 1..4')
