"""Decode actual RTL BLK1 bytes and compare with independent RGB reference."""
from pathlib import Path
import struct
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[3]/'rk3576'))
from lz77_decode import decode_frame

folder=Path(sys.argv[1])
wire=bytes.fromhex((folder/'stream.hex').read_text())
words=[int(w,16) for w in (folder/'expected.hex').read_text().split()]
# RTL words are B,G,R,X in little-endian order; pack4 emits RGB24.
expected=b''.join(w.to_bytes(16,'little')[k:k+3][::-1] for w in words for k in (0,4,8,12))
offset=0
for fid in range(1,5):
    assert wire[offset:offset+4]==b'LZ77'
    assert wire[offset+8:offset+12]==b'BLK1'
    pos=offset+16
    count=0
    while count<768:
        kind=wire[pos]
        raw=int.from_bytes(wire[pos+1:pos+4],'little')
        stored=struct.unpack_from('<I',wire,pos+4)[0]
        assert kind in (0,1) and 0<raw<=256 and 0<stored<=raw
        assert kind==0 or stored<raw
        count+=raw
        pos+=8+stored
    assert count==768 and wire[pos:pos+4]==b'END!'
    raw,meta=decode_frame(wire[offset:pos+20],expect_rgb24=True)
    assert meta['frame_id']==fid and meta['width']==meta['height']==16
    assert raw==expected[fid*768:(fid+1)*768],fid
    offset=pos+20
assert offset==len(wire)
print('PASS enhancement -> RGB24 pack -> DDR -> BLK1: 4 frames, independent pixels/CRC/IDs, startup skip, backpressure')
