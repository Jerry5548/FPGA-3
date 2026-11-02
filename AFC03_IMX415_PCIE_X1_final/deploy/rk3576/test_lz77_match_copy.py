#!/usr/bin/env python3
"""Exact match expansion and block-boundary regression; no board access."""
import argparse
import random
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path

from lz77_blocks import BLOCK_MAGIC
from lz77_decode import decode_frame


def packet(payload, raw_size, tokens, flags=BLOCK_MAGIC):
    return (b'LZ77' + struct.pack('<HHII', 0, 0, flags, 37) + payload +
            b'END!' + struct.pack('<IIII', raw_size, len(payload), tokens,
                                  zlib.crc32(payload)))


def vectors():
    rng = random.Random(357625)
    payload = bytearray()
    legacy = bytearray()
    expected = bytearray()
    tokens = 0
    # Cover non-overlap, exact adjacency and overlap, including lengths smaller
    # than distance. Every block resets its dictionary with distinct seed bytes.
    for distance in range(1, 256):
        for length in range(3, 128):
            seed = rng.randbytes(distance)
            raw = bytearray(seed)
            body = bytearray()
            for byte in seed:
                body += bytes((0, byte))
            for _ in range(4):
                body += bytes((0x80 | length, distance))
                for _ in range(length):
                    raw.append(raw[-distance])
            block_tokens = distance + 4
            # Raw fallback is required when these tokens do not save space.
            if len(body) < len(raw):
                payload += bytes((1,)) + len(raw).to_bytes(3, 'little')
                payload += struct.pack('<I', len(body)) + body
                tokens += block_tokens
            else:
                payload += bytes((0,)) + len(raw).to_bytes(3, 'little')
                payload += struct.pack('<I', len(raw)) + raw
            legacy += body
            expected += raw
    blob = packet(payload, len(expected), tokens)
    old = packet(legacy, len(expected), 255 * 125 * 4 + sum(range(1, 256)) * 125, 0)
    # Correct CRC but invalid match: it must not borrow the preceding block's
    # dictionary, nor read before the beginning of an empty output.
    invalid = [packet(b'\x01\x06\x00\x00\x02\x00\x00\x00\x86\x01', 6, 1),
               packet(b'\x00\x04\x00\x00\x04\x00\x00\x00ABCD' +
                      b'\x01\x06\x00\x00\x02\x00\x00\x00\x86\x01', 10, 1)]
    return [(blob, bytes(expected)), (old, bytes(expected))], invalid


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--receiver', type=Path, required=True)
    args = ap.parse_args()
    rx = str(args.receiver.resolve())
    cases, invalid = vectors()
    with tempfile.TemporaryDirectory(prefix='lz77-match-copy-') as td:
        root = Path(td)
        source = root/'input.lz77'
        prefix = root/'decoded'
        for label, (blob, expected) in zip(('BLK1', 'legacy'), cases):
            assert decode_frame(blob)[0] == expected
            source.write_bytes(blob)
            for scheduling in ('--serial', '--pipeline'):
                for mode in ('scalar', 'fast'):
                    result = subprocess.run([rx, '-d', str(source), scheduling,
                                             '--match-copy', mode, '-o', str(prefix)],
                                            capture_output=True, timeout=90)
                    assert result.returncode == 0, result.stdout + result.stderr
                    assert (root/'decoded_000037.bin').read_bytes() == expected
            print(f'PASS {label}: all distances 1..255, lengths 3..127, '
                  'overlapping/non-overlapping copies, fast/scalar, serial/pipeline')
        for blob in invalid:
            source.write_bytes(blob)
            for mode in ('scalar', 'fast'):
                result = subprocess.run([rx, '-d', str(source), '--pipeline',
                                         '--match-copy', mode],
                                        capture_output=True, timeout=15)
                assert result.returncode != 0, 'block-local match violation accepted'
        print('PASS rejected invalid match distances, including cross-block references')


if __name__ == '__main__':
    main()
