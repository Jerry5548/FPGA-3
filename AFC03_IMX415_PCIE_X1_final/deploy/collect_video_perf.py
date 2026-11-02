#!/usr/bin/env python3
"""Collect existing video logs and read-only PCIe state; never opens DMA/video."""
import argparse
import collections
import datetime
import os
import re
import subprocess
import tempfile
import zipfile
from pathlib import Path


def latest(pattern):
    entries = [p for p in Path('/tmp').glob(pattern) if p.is_dir()]
    return max(entries, key=lambda p: p.stat().st_mtime) if entries else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--raw', type=Path, help='explicit /tmp/raw-video.* directory')
    ap.add_argument('--lz77', type=Path, help='explicit /tmp/lz77-video.* directory')
    ap.add_argument('--recent', type=int, default=0,
                    help='Collect this many newest raw/LZ77 runs together (max 20)')
    ap.add_argument('--benchmark', type=Path, help='Include benchmark_video_paths.sh case logs')
    args = ap.parse_args()
    if not 0 <= args.recent <= 20:
        ap.error('--recent must be 0..20')
    if args.recent and (args.raw or args.lz77):
        ap.error('--recent cannot be combined with --raw/--lz77')
    if args.benchmark and (args.recent or args.raw or args.lz77):
        ap.error('--benchmark cannot be combined with --recent/--raw/--lz77')
    folders = {'raw': args.raw or latest('raw-video.*'),
               'lz77': args.lz77 or latest('lz77-video.*')}
    summary = ['Existing logs only. No new capture or benchmark was run.',
               'Default picks the newest raw and LZ77 directories separately.',
               'Check timestamps, modes, scene and YOLO configuration before comparing.']
    if args.recent:
        candidates = [p for pattern in ('raw-video.*', 'lz77-video.*')
                      for p in Path('/tmp').glob(pattern) if p.is_dir()]
        candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        folders = {p.name: p for p in candidates[:args.recent]}
        summary[1] = f'Collected the newest {len(folders)} runs together; names identify separate tests.'
    if args.benchmark:
        if not args.benchmark.is_dir():
            ap.error('--benchmark directory missing')
        # Read the exact run directories printed by these cases. Do not mix
        # previous playback runs into a failed/incomplete benchmark batch.
        folders = {}
        for case in sorted(args.benchmark.glob('*.log')):
            body = case.read_text(encoding='utf-8', errors='replace')
            for name in re.findall(r'Logs: (/tmp/(?:raw|lz77)-video\.[A-Za-z0-9]+)', body):
                folder = Path(name)
                if folder.is_dir():
                    folders[case.stem + '-' + folder.name] = folder
        summary[1] = f'Collected {len(folders)} exact playback directories from this benchmark batch.'
    files = []
    for kind, folder in folders.items():
        summary.append(f'\n[{kind}] {folder}')
        if folder is None or not folder.is_dir():
            summary.append('No log directory found')
            continue
        summary.append('directory_mtime=' + datetime.datetime.fromtimestamp(folder.stat().st_mtime).isoformat())
        for name in ('rx.log', 'gst.log', 'hardware.log', 'before.log', 'after.log', 'dmesg.log', 'first_fault.log'):
            path = folder / name
            if not path.is_file():
                continue
            files.append((path, f'{kind}/{name}'))
            if name in ('rx.log', 'gst.log', 'hardware.log'):
                tail = collections.deque(maxlen=8)
                with path.open(encoding='utf-8', errors='replace') as src:
                    for line in src:
                        if line.startswith(('PERF ', 'PERF_DMA ', 'PIPE_OUTPUT ', 'OPTIMIZATIONS ',
                                            'OVERLAY ', 'DISPLAY ', 'OUTPUT ', 'YOLO ', 'YOLO_PERF ',
                                            'HARDWARE ', 'VIDEO ', 'frames=', 'START ', 'YOLO model:')):
                            tail.append(line.rstrip())
                summary.append(name + ':\n' + '\n'.join(tail))
    if args.benchmark:
        for path in sorted(args.benchmark.iterdir()):
            if path.is_file() and (path.suffix == '.log' or path.name == 'results.txt'):
                files.append((path, 'benchmark/' + path.name))
    system = []
    for command in (['uname', '-a'], ['lspci', '-D', '-nn', '-vv'],
                    ['v4l2-ctl', '-d', '/dev/video73', '--get-fmt-video', '--get-parm']):
        system.append('COMMAND: ' + ' '.join(command))
        try:
            result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                    text=True, errors='replace', timeout=10)
            system.append(result.stdout)
        except (OSError, subprocess.TimeoutExpired) as exc:
            system.append(str(exc))
    parameter_dir = Path('/sys/module/anlogic_pci/parameters')
    if parameter_dir.is_dir():
        for path in sorted(parameter_dir.iterdir()):
            if path.is_file():
                try:
                    system.append(str(path) + '=' + path.read_text().strip())
                except OSError as exc:
                    system.append(str(exc))
    fd, name = tempfile.mkstemp(prefix='pcie-video-report.', suffix='.zip', dir='/tmp')
    os.close(fd)
    with zipfile.ZipFile(name, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('summary.txt', '\n'.join(summary))
        archive.writestr('system.txt', '\n'.join(system))
        for source, relative in files:
            archive.write(source, relative)
    os.chmod(name, 0o644)
    print('\n'.join(summary))
    print('\nDownload this report with Xftp: ' + name)


if __name__ == '__main__':
    main()
