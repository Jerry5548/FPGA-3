#!/usr/bin/env python3
"""Verify lossless DDR->LZ77 payloads and their captured camera IDs."""
import sys
from pathlib import Path
root=Path(__file__).resolve().parent
sys.path.insert(0,str(root.parents[2]/'rk3576'))
from lz77_decode import decode_frame
stream=bytes.fromhex((root/'ddr_lz77.hex').read_text())
for fid in range(1,11):
    end=stream.find(b'END!',16)
    assert end>=0,(fid,'missing footer')
    raw,meta=decode_frame(stream[:end+20],expect_rgb24=True)
    expected=bytes((fid*97+i)&255 for i in range(768))
    assert meta['frame_id']==fid,meta
    assert raw==expected,(fid,len(raw))
    stream=stream[end+20:]
assert not stream,len(stream)
print('PASS DDR->LZ77 decode: 10 exact frames, CRC, RGB24 geometry and capture IDs; short frame absent')
