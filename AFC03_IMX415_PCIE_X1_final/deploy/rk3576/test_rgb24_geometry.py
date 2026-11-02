#!/usr/bin/env python3
"""Reject CRC-valid packets whose decoded size is not one RGB24 image.

With --receiver PATH, also exercise the actual C receiver (on RK3576),
including its missing-footer limit and multi-frame read boundaries.
"""
import argparse
import random
import struct
import subprocess
import tempfile
from pathlib import Path

from lz77_decode import decode_frame
from make_test_frame import make_frame


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--receiver', type=Path)
    ap.add_argument('--pipeline', action='store_true')
    args = ap.parse_args()
    raw = bytes(range(96))
    good = make_frame(raw, 8, 4, 1)
    assert decode_frame(good, expect_rgb24=True)[0] == raw
    bad_frames = [make_frame(raw[:-1], 8, 4, 2),
                  make_frame(raw + b'X', 8, 4, 3),
                  make_frame(raw, 0, 4, 4)]
    for frame in bad_frames:
        # Each packet is valid under the generic protocol: CRC, tokens,
        # and footer lengths agree. It is nevertheless an invalid image.
        decode_frame(frame)
        try:
            decode_frame(frame, expect_rgb24=True)
        except ValueError as exc:
            assert 'RGB24 length mismatch' in str(exc), exc
        else:
            raise AssertionError('accepted wrong RGB24 geometry')
    print('PASS Python: CRC-valid short/long/zero-dimension images rejected')

    if not args.receiver:
        print('C receiver checks pending: run with --receiver ./rk3576_lz77_rx')
        return
    receiver = str(args.receiver.resolve())
    with tempfile.TemporaryDirectory(prefix='lz77-geometry-') as td:
        root = Path(td)

        def run(blob, count=1):
            source = root / 'input.bin'
            source.write_bytes(blob)
            result = subprocess.run([receiver, '-d', str(source), '-n', str(count),
                                     '--expect-rgb24', '-v'] + (['--pipeline'] if args.pipeline else ['--serial']), text=True,
                                    capture_output=True, timeout=10)
            assert source.read_bytes() == blob, (
                'receiver modified/truncated input file\n' + result.stdout + result.stderr)
            return result

        result = run(good)
        assert result.returncode == 0, result.stdout + result.stderr
        for frame in bad_frames:
            result = run(frame)
            assert result.returncode == 1, result
            assert 'frames=0 ' in result.stdout, result.stdout
            assert 'format_errors=1 ' in result.stdout, result.stdout
        # Reproduce the reported 1080p footer counts without allocating
        # huge raw images. Footer corruption doesn't change the payload CRC.
        for raw_len in (17525488, 7741920):
            blob = bytearray(good)
            struct.pack_into('<HH', blob, 4, 1920, 1080)
            struct.pack_into('<I', blob, len(blob)-16, raw_len)
            result = run(blob)
            assert result.returncode == 1, result
            assert f'footer_raw={raw_len}' in result.stderr, result.stderr
        # No footer: bounded by geometry, not a 256 MiB allocation.
        result = run(good[:16] + b'\x00\x41' * 1024)
        assert result.returncode == 1, result
        assert 'missing footer' in result.stderr, result.stderr
        # Several valid packets may arrive in the same 4096-byte read.
        result = run(b''.join(make_frame(raw, 8, 4, i) for i in range(20)), 20)
        assert result.returncode == 0, result.stdout + result.stderr
        assert 'frames=20 ' in result.stdout, result.stdout
        # Put footers across read boundaries; including a >4096-byte image.
        rng = random.Random(3576)
        large_raw = bytes(rng.randrange(256) for _ in range(48*48*3))
        blob = b''.join(make_frame(large_raw, 48, 48, i) for i in range(3))
        result = run(blob, 3)
        assert result.returncode == 0, result.stdout + result.stderr
    print('PASS C: input preserved, geometry rejection, missing-footer bound, fragmented/multiple frames')


if __name__ == '__main__':
    main()
