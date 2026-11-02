#!/usr/bin/env python3
from lz77_blocks import BLOCK_MAGIC, decode_blocks, encode_blocks, make_block_frame
from lz77_decode import decode_frame
import argparse
import struct
import subprocess
import tempfile
from pathlib import Path
import zlib

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--receiver', type=Path)
    args = ap.parse_args()
    for raw in (b"", bytes(range(256))*17, b"A"*200000, b"RGBRGB"*12000 + bytes(range(251))):
        payload, tokens, blocks = encode_blocks(raw, 4096)
        assert decode_blocks(payload, len(raw), tokens)[0] == raw
        assert len(payload) <= len(raw) + max(1, len(blocks))*8
        assert all(stored <= raw_n for kind, raw_n, stored, *_ in blocks if kind == 0)
    raw = bytes(range(256))*24300
    out, meta = decode_frame(make_block_frame(raw, 1920, 1080, 7, 65536), expect_rgb24=True)
    assert out == raw and meta["flags"] == BLOCK_MAGIC
    # Reset the dictionary at every compressed block; invalid lengths and
    # references must be rejected even with a fresh, valid payload CRC.
    def packet(payload, size, tokens):
        return (b'LZ77' + struct.pack('<HHII', 8, 4, BLOCK_MAGIC, 7) + payload +
                b'END!' + struct.pack('<IIII', size, len(payload), tokens, zlib.crc32(payload)))

    malformed = [
        packet(bytes((0, 4, 0, 0))+struct.pack('<I', 3)+b'ABC', 4, 0),
        packet(bytes((1, 6, 0, 0))+struct.pack('<I', 2)+b'\x86\x01', 6, 1),
        packet(bytes((1, 9, 0, 0))+struct.pack('<I', 4)+b'\x00A\x83\x01', 9, 2),
        packet(bytes((0, 4, 0, 0))+struct.pack('<I', 4)+b'ABCD'+
               bytes((1, 4, 0, 0))+struct.pack('<I', 2)+b'\x84\x01', 8, 1),
    ]
    for invalid in malformed:
        try:
            decode_frame(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError('malformed block accepted')
    print("PASS BLK1: raw fallback, LZ blocks, RGB24 geometry, CRC and worst-case bound")
    if args.receiver:
        with tempfile.TemporaryDirectory(prefix='blk1-c-regression-') as td:
            folder = Path(td)
            source = folder/'stream.bin'
            # A valid-looking footer INSIDE a raw block must be skipped by
            # block length, irrespective of matching offset and embedded magic.
            raw = bytearray(bytes(range(256))*5)
            raw[100:120] = b'END!' + struct.pack('<IIII', 4, 108, 0, 0)
            raw[200:204] = b'LZ77'
            variants = [bytes(raw), b'Z'*2048,
                        bytes(range(256))*3+b'A'*2048+bytes(range(256))*2]
            for pipeline in ('--serial', '--pipeline'):
                blob = b''.join(make_block_frame(data, 8, 4, i, 256)
                                for i, data in enumerate(variants))
                source.write_bytes(blob)
                prefix = folder/'frame'
                result = subprocess.run([str(args.receiver.resolve()), '-d', str(source),
                                         pipeline, '-n', '3', '-o', str(prefix)],
                                        capture_output=True, timeout=20)
                assert result.returncode == 0, result.stdout+result.stderr
                for i, data in enumerate(variants):
                    assert (folder/f'frame_{i:06d}.bin').read_bytes() == data
                assert source.read_bytes() == blob
                for invalid in malformed:
                    source.write_bytes(invalid)
                    result = subprocess.run([str(args.receiver.resolve()), '-d', str(source),
                                             pipeline], capture_output=True, timeout=20)
                    assert result.returncode != 0, result.stdout+result.stderr
            print('PASS C BLK1: exact raw/compressed/mixed output, block-local matches, '
                  'forged raw footer, malformed blocks, serial/pipeline')

if __name__ == "__main__": main()
