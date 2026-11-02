#!/usr/bin/env python3
"""Generate deterministic phase-1 FPGA-compatible LZ77 test frames."""
from pathlib import Path
import struct, zlib

MAGIC=b"LZ77"; END=b"END!"

def make_tokens(raw: bytes):
    # Match the FPGA phase-1 subset: distance=1 runs, literal seed per run.
    out=bytearray(); i=0; tokens=0
    while i < len(raw):
        j=i+1
        while j < len(raw) and raw[j] == raw[i] and j-i < 127:
            j += 1
        run=j-i
        if run >= 3:
            out += bytes((0, raw[i])); tokens += 1; i += 1
            out += bytes((0x80 | (run-1), 1)); tokens += 1; i = j
        else:
            out += bytes((0, raw[i])); tokens += 1; i += 1
    return bytes(out), tokens

def make_frame(raw: bytes, width=64, height=8, frame_id=7):
    payload, tokens = make_tokens(raw)
    header = MAGIC + struct.pack('<HHII', width, height, 0, frame_id)
    footer = END + struct.pack('<IIII', len(raw), len(payload), tokens,
                               zlib.crc32(payload) & 0xffffffff)
    return header + payload + footer

def main():
    outdir = Path(__file__).resolve().parent / 'test_vectors'
    outdir.mkdir(parents=True, exist_ok=True)
    raw = (b'ABCD' + b'Z'*32 + bytes(range(16)) + b'Q'*11 + b'xyz')
    frame = make_frame(raw)
    (outdir/'sample_frame.lz77').write_bytes(frame)
    (outdir/'sample_frame.raw').write_bytes(raw)
    print(f'frame={outdir/"sample_frame.lz77"} bytes={len(frame)} raw={len(raw)}')

if __name__ == '__main__': main()
