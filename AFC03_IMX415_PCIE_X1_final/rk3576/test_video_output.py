#!/usr/bin/env python3
"""Run on Linux/RK: exact multi-frame stdout, geometry/CRC, and closed pipe."""
import argparse
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path


def frame(value, width=1920, height=1080):
    size = width * height * 3
    payload = bytearray((0, value))
    remaining = size - 1
    tokens = 1
    while remaining >= 3:
        count = min(127, remaining)
        payload.extend((0x80 | count, 1))
        remaining -= count
        tokens += 1
    for _ in range(remaining):
        payload.extend((0, value))
        tokens += 1
    return (b'LZ77' + struct.pack('<HHII', width, height, 0, 1) + payload +
            b'END!' + struct.pack('<IIII', size, len(payload), tokens, zlib.crc32(payload)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--receiver', type=Path, required=True)
    ap.add_argument('--pipeline', action='store_true')
    args = ap.parse_args()
    rx = str(args.receiver.resolve())
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / 'input.lz77'
        command = [rx, '-d', str(path), '--stdout-rgb24', '-v', '--profile']
        command += ['--pipeline'] if args.pipeline else ['--serial']
        good = frame(0x0a)
        second = frame(0xff)
        path.write_bytes(good + second)
        r = subprocess.run(command, capture_output=True, timeout=20)
        assert r.returncode == 0, r.stderr
        assert r.stdout == bytes([0x0a]) * 6220800 + bytes([0xff]) * 6220800
        assert b'frames=2 ' in r.stderr
        assert b'PERF frames=2 ' in r.stderr
        assert path.read_bytes() == good + second
        # Exercise literals, distance=1 fill, overlapping distance=2, and
        # non-overlapping copy distance=6. Repeated data is not only grayscale.
        payload = bytearray()
        expected = bytearray()
        def literal(value):
            payload.extend((0, value))
            expected.append(value)
        def match(length, distance):
            payload.extend((0x80 | length, distance))
            for _ in range(length):
                expected.append(expected[-distance])
        literal(0x12)
        literal(0xa7)
        match(127, 2)
        match(6, 6)
        match(127, 1)
        for value in range(256):
            literal(value)
        while len(expected) + 127 <= 6220800:
            match(127, 2)
        while len(expected) < 6220800:
            literal(0x5a)
        packet = (b'LZ77' + struct.pack('<HHII', 1920, 1080, 0, 2) + payload +
                  b'END!' + struct.pack('<IIII', len(expected), len(payload),
                                        len(payload)//2, zlib.crc32(payload)))
        path.write_bytes(packet)
        r = subprocess.run(command, capture_output=True, timeout=20)
        assert r.returncode == 0 and r.stdout == expected, r.stderr
        for invalid in (frame(1, 8, 4), good[:-1] + bytes([good[-1] ^ 1])):
            path.write_bytes(invalid)
            r = subprocess.run(command, capture_output=True, timeout=20)
            assert r.returncode != 0 and r.stdout == b'', r.stderr
        path.write_bytes(good)
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE) as p:
            p.stdout.close()
            p.stdout = None
            _, errors = p.communicate(timeout=20)
            assert p.returncode == 1, errors
            assert b'RGB24 output' in errors
    print('PASS video: exact RGB24, literals/overlapping/nonoverlapping matches, profile, geometry/CRC, broken pipe')


if __name__ == '__main__':
    main()
