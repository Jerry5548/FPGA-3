#!/usr/bin/env python3
import argparse
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'rk3576'))
from lz77_decode import decode_frame
from lz77_blocks import BLOCK_MAGIC


def check(folder, width, height, block, frames):
    wire = bytes.fromhex((folder/'blk1_stream.hex').read_text())
    raw = bytes.fromhex((folder/'blk1_raw.hex').read_text())
    offset = 0
    kinds = set()
    for index in range(frames):
        assert wire[offset:offset+4] == b'LZ77'
        assert struct.unpack_from('<I', wire, offset+8)[0] == BLOCK_MAGIC
        pos = offset+16
        decoded_n = 0
        while decoded_n < width*height*3:
            kind = wire[pos]
            count = int.from_bytes(wire[pos+1:pos+4], 'little')
            stored = struct.unpack_from('<I', wire, pos+4)[0]
            assert kind in (0,1) and 0<count<=block
            assert stored<=count and (kind==0 or stored<count)
            kinds.add(kind)
            pos += 8+stored
            decoded_n += count
        assert wire[pos:pos+4] == b'END!'
        packet = wire[offset:pos+20]
        image,meta = decode_frame(packet, expect_rgb24=True)
        assert meta['frame_id'] == 1000+index
        size = width*height*3
        assert image == raw[index*size:(index+1)*size], f'frame {index}: pixel mismatch'
        assert meta['comp_len'] <= size+8*((size+block-1)//block)
        if index == 0:
            print(f'frame0 raw-fallback payload/raw={meta["comp_len"]/size:.6f}, '
                  f'frame_wire/raw={len(packet)/size:.6f}')
        offset = pos+20
    assert offset==len(wire), 'trailing bytes'
    if frames>=3:
        assert kinds=={0,1}, kinds
    print(f'PASS decoded BLK1 RAM regression: frames={frames}, geometry={width}x{height}, '
          f'block={block}, kinds={sorted(kinds)}, wire/raw={len(wire)/len(raw):.6f}, CRC/ID/pixels/bound verified')


if __name__=='__main__':
    ap=argparse.ArgumentParser()
    ap.add_argument('folder',type=Path)
    for key in ('width','height','block','frames'):
        ap.add_argument('--'+key,type=int,required=True)
    a=ap.parse_args()
    check(a.folder,a.width,a.height,a.block,a.frames)
