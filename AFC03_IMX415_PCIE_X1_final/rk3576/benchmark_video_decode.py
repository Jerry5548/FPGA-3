#!/usr/bin/env python3
"""Offline CPU/decode baseline. This does not measure FPGA, DMA, or display."""
import argparse
import struct
import subprocess
import tempfile
import time
import zlib
from pathlib import Path
from test_video_output import frame
from lz77_blocks import make_block_frame


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--receiver', type=Path, required=True)
    ap.add_argument('--frames', type=int, default=12)
    scheduling = ap.add_mutually_exclusive_group()
    scheduling.add_argument('--pipeline', action='store_true')
    scheduling.add_argument('--serial', action='store_true')
    ap.add_argument('--crc', choices=('auto', 'table', 'slice8', 'arm'), default='auto')
    ap.add_argument('--match-copy', choices=('fast', 'scalar'), default='fast')
    args = ap.parse_args()
    receiver = str(args.receiver.resolve())
    if args.frames < 1:
        ap.error('--frames must be positive')
    extra = ['--crc', args.crc, '--match-copy', args.match_copy]
    extra += ['--pipeline'] if args.pipeline else ['--serial']
    # High-compression and all-literal payloads bound typical workload types.
    raw = bytes(range(256)) * (6220800 // 256)
    raw += bytes(range(6220800 - len(raw)))
    literal = bytearray(2 * len(raw))
    literal[1::2] = raw
    packet = (b'LZ77' + struct.pack('<HHII', 1920, 1080, 0, 0) + literal +
              b'END!' + struct.pack('<IIII', len(raw), len(literal), len(raw),
                                    zlib.crc32(literal)))
    with tempfile.TemporaryDirectory(prefix='lz77-bench-') as td:
        path = Path(td) / 'input.lz77'
        cases = [('legacy_repeat', frame(0x55)), ('legacy_literal', packet),
                 ('blk1_repeat', make_block_frame(b'\x55'*6220800, 1920, 1080, 0, 32768)),
                 ('blk1_raw_fallback', make_block_frame(raw, 1920, 1080, 0, 32768))]
        for label, data in cases:
            with path.open('wb') as source:
                for _ in range(args.frames):
                    source.write(data)
            start = time.monotonic()
            result = subprocess.run(
                [receiver, '-d', str(path), '-n', str(args.frames), '--stdout-rgb24', '--profile'] + extra,
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, timeout=max(60, args.frames*5))
            print(f'OFFLINE {label}: match_copy={args.match_copy} elapsed={time.monotonic()-start:.3f}s exit={result.returncode}')
            print(result.stderr, end='')
            if result.returncode:
                raise SystemExit(result.returncode)
    print('Offline only: file input and /dev/null output; pipeline stages overlap, read_wait is consumer queue wait.')


if __name__ == '__main__':
    main()
