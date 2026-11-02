#!/usr/bin/env python3
"""Decode RTL output streams and compare every byte with source vectors."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parents[2] / 'rk3576'))
from lz77_decode import decode_frame


def check(name, count, prefix=None):
    stream = bytes.fromhex((ROOT/name).read_text())
    for index in range(count):
        assert stream.startswith(b'LZ77'), (name,index,'missing header')
        end = stream.find(b'END!',16)
        assert end>=0, (name,index,'missing footer')
        frame=stream[:end+20]
        raw,meta=decode_frame(frame)
        assert meta['frame_id']==index, (name,index,meta)
        expected=(bytes.fromhex((ROOT/f'{prefix}{index}.hex').read_text())
                  if prefix else bytes(((index*3+j)&255) for j in range(3)))
        assert raw==expected, (name,index,len(raw),len(expected))
        if name=='fault_stream.hex' and index==1:
            try: decode_frame(frame,expect_rgb24=True)
            except ValueError: pass
            else: raise AssertionError('short image accepted')
        else: decode_frame(frame,expect_rgb24=True)
        stream=stream[end+20:]
    assert not stream,(name,'trailing data',len(stream))
    print(f'PASS {name}: {count} frames, exact raw bytes, frame IDs, CRC and geometry')


if __name__=='__main__':
    check('rtl_0.hex',100,'raw_')
    check('fault_stream.hex',5,'fault_raw_')
    check('formatter_eof.hex',100)
