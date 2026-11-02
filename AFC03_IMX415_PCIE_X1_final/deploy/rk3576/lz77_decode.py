#!/usr/bin/env python3
"""Reference decoder for the phase-1 LZ77 frame formatter.

Token wire format is little-endian: literal 00,value; match 80|length,distance.
The decoder validates footer lengths, token count and reflected CRC32.
"""
from __future__ import annotations
import argparse, struct, sys, zlib
from pathlib import Path
from lz77_blocks import BLOCK_MAGIC, decode_blocks

MAGIC=b"LZ77"; END=b"END!"

def decode_frame(blob: bytes, *, expect_rgb24: bool = False) -> tuple[bytes, dict]:
    if len(blob)<36 or blob[:4]!=MAGIC:
        raise ValueError("invalid LZ77 header")
    width,height=struct.unpack_from('<HH',blob,4)
    flags=struct.unpack_from('<I',blob,8)[0]
    frame_id=struct.unpack_from('<I',blob,12)[0]
    if blob[-20:-16]!=END:
        raise ValueError("invalid LZ77 footer")
    raw_len,comp_len,tokens,want_crc=struct.unpack_from('<IIII',blob,-16)
    if expect_rgb24 and (not width or not height or raw_len != width*height*3):
        raise ValueError(f"RGB24 length mismatch: {width}x{height} "
                         f"expected={width*height*3} footer_raw={raw_len}")
    payload=blob[16:-20]
    if len(payload)!=comp_len:
        raise ValueError(f"compressed length mismatch: payload={len(payload)} footer={comp_len}")
    if zlib.crc32(payload)&0xffffffff != want_crc:
        raise ValueError("payload CRC32 mismatch")
    if flags == BLOCK_MAGIC:
        out, _ = decode_blocks(payload, raw_len, tokens)
        return out,dict(width=width,height=height,frame_id=frame_id,flags=flags,raw_len=raw_len,comp_len=comp_len,tokens=tokens,crc32=want_crc)
    if flags != 0: raise ValueError(f"unsupported frame flags 0x{flags:08x}")
    out=bytearray(); pos=0; token_n=0
    while pos<len(payload):
        if pos+2>len(payload): raise ValueError("truncated token")
        control,value=payload[pos],payload[pos+1];pos+=2;token_n+=1
        if control==0:
            out.append(value)
        elif control&0x80:
            length=control&0x7f;distance=value
            if length<3 or distance==0 or distance>len(out): raise ValueError("invalid match")
            for _ in range(length): out.append(out[-distance])
        else: raise ValueError(f"reserved token 0x{control:02x}")
    if len(out)!=raw_len: raise ValueError(f"raw length mismatch: data={len(out)} footer={raw_len}")
    if token_n!=tokens: raise ValueError(f"token count mismatch: data={token_n} footer={tokens}")
    return bytes(out),dict(width=width,height=height,frame_id=frame_id,flags=flags,raw_len=raw_len,comp_len=comp_len,tokens=tokens,crc32=want_crc)

def self_test() -> None:
    # AAAA BC BBBB DE; encoder output: literal A, match AAA, literals B/C,
    # literal B, match BBB, literals D/E.
    payload=bytes([0,ord('A'),0x83,1,0,ord('B'),0,ord('C'),0,ord('B'),0x83,1,0,ord('D'),0,ord('E')])
    # Build a valid frame matching the protocol, then decode it.
    footer=END+struct.pack('<IIII',12,len(payload),8,zlib.crc32(payload)&0xffffffff)
    frame=MAGIC+struct.pack('<HHII',8,2,0,0)+payload+footer
    out,meta=decode_frame(frame)
    assert out==b'AAAABCBBBBDE',out
    assert meta['tokens']==8
    print('PASS LZ77 decoder self-test',meta)

def main() -> int:
    ap=argparse.ArgumentParser();ap.add_argument('frame',nargs='?');ap.add_argument('-o','--output');ap.add_argument('--self-test',action='store_true');ap.add_argument('--expect-rgb24',action='store_true');a=ap.parse_args()
    if a.self_test:self_test();return 0
    if not a.frame: ap.error('frame is required unless --self-test is used')
    data,meta=decode_frame(Path(a.frame).read_bytes(), expect_rgb24=a.expect_rgb24)
    if a.output:Path(a.output).write_bytes(data)
    print(meta)
    return 0
if __name__=='__main__':sys.exit(main())
