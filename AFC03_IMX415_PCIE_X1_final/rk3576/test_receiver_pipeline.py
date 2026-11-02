#!/usr/bin/env python3
"""Linux receiver regression: bounded pipeline, exact outputs, failures/shutdown.

No camera/device access. Run after build.sh on RK3576 or another Linux host.
"""
import argparse
import hashlib
import os
import signal
import struct
import subprocess
import tempfile
import threading
import time
import zlib
from pathlib import Path

from test_video_output import frame
from lz77_blocks import make_block_frame


def literal_packet(raw, ident, width=0, height=0):
    payload = bytearray(len(raw)*2)
    payload[1::2] = raw
    return (b'LZ77' + struct.pack('<HHII', width, height, 0, ident) + payload +
            b'END!' + struct.pack('<IIII', len(raw), len(payload), len(raw), zlib.crc32(payload)))


def check(result, success=True):
    assert (result.returncode == 0) == success, (result.returncode, result.stderr[-3000:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--receiver', type=Path, required=True)
    args = ap.parse_args()
    rx = str(args.receiver.resolve())
    if os.name != 'posix':
        ap.error('run receiver/FIFO tests on Linux, preferably RK3576')
    result = subprocess.run([rx, '--self-test-crc'], capture_output=True, timeout=30)
    check(result)
    print(result.stdout.decode(), end='')
    with tempfile.TemporaryDirectory(prefix='rx-pipeline-test-') as td:
        root = Path(td)
        path = root/'input.lz77'

        def run(blob, extra=(), stdout=False, success=True):
            path.write_bytes(blob)
            command = [rx, '-d', str(path), '--profile', '-v'] + list(extra)
            if stdout:
                command += ['--stdout-rgb24']
            result = subprocess.run(command, capture_output=True, timeout=30)
            check(result, success)
            assert path.read_bytes() == blob, 'input was modified'
            return result

        # Grow each reusable slot, then reuse it for smaller and empty frames.
        raws = [bytes(range(256))*k for k in (1, 4097, 8193, 2, 0, 16, 64)]
        blob = b''.join(literal_packet(raw, i) for i, raw in enumerate(raws))
        for scheduling in ('--serial', '--pipeline'):
            for crc in ('table', 'slice8', 'auto'):
                prefix = root/'decoded'
                result = run(blob, [scheduling, '--crc', crc, '-o', str(prefix)])
                assert b'frames=7 ' in result.stdout, result.stdout
                for i, raw in enumerate(raws):
                    assert (root/f'decoded_{i:06d}.bin').read_bytes() == raw
                if scheduling == '--pipeline':
                    assert b'ring_high_water=' in result.stderr
                    assert b'PIPELINE_OUTPUT buffers=2' in result.stderr
        print('PASS exact file output: serial/pipeline, table/slice8/auto, buffer growth/reuse/empty frames')

        images = frame(0x12) + frame(0xa7)
        expected = b'\x12'*6220800 + b'\xa7'*6220800
        for scheduling in ('--serial', '--pipeline'):
            result = run(images, [scheduling], stdout=True)
            assert result.stdout == expected
            assert b'frames=2 ' in result.stderr
            result = run(images, [scheduling, '-n', '1'], stdout=True)
            assert result.stdout == expected[:6220800]
        block_raw = bytes(range(256)) * (6220800 // 256)
        block_frame = make_block_frame(block_raw, 1920, 1080, 91, 65536)
        result = run(block_frame, ['--pipeline'])
        assert b'frames=1 ' in result.stdout, result.stdout
        broken = bytearray(frame(0x44))
        broken[17] ^= 0x20
        result = run(broken, ['--pipeline'], stdout=True, success=False)
        assert result.stdout == b'' and b'crc_errors=1 ' in result.stderr
        bad_token = bytearray(frame(0x44))
        bad_token[16] = 1
        struct.pack_into('<I', bad_token, len(bad_token)-4, zlib.crc32(bad_token[16:-20]))
        result = run(bad_token, ['--pipeline'], stdout=True, success=False)
        assert not result.stdout and b'decode_errors=1 ' in result.stderr
        for tail in (b'LZ77', images[:200]):
            result = run(tail, ['--pipeline'], stdout=True, success=False)
            assert not result.stdout
        print('PASS stdout: exact RGB24, frame limit, CRC rejection and truncated EOF')

        # Capture is bounded and refuses to truncate an existing file/input.
        capture = root/'capture.bin'
        result = run(blob, ['--pipeline', '--capture', str(capture)])
        assert capture.read_bytes() == blob[:1024*1024]
        run(blob, ['--pipeline', '--capture', str(capture)], success=False)
        run(blob, ['--pipeline', '--capture', str(path)], success=False)
        print('PASS bounded capture and exclusive-create input protection')

        fifo = root/'input.fifo'
        os.mkfifo(fifo)
        errors = root/'stderr.log'

        def start_fifo(stdout=subprocess.PIPE, extra=()):
            log = errors.open('wb')
            p = subprocess.Popen([rx, '-d', str(fifo), '--pipeline', '--stdout-rgb24', '--profile'] + list(extra),
                                 stdout=stdout, stderr=log)
            log.close()
            return p

        def reap(p):
            if p.poll() is None:
                p.kill()
            p.wait(timeout=10)
            if p.stdout:
                p.stdout.close()

        def wait_log(needle, p):
            deadline = time.monotonic()+10
            while time.monotonic() < deadline:
                if needle in errors.read_bytes():
                    return
                assert p.poll() is None, errors.read_bytes()
                time.sleep(.01)
            raise AssertionError(f'missing readiness: {needle!r}')

        # Artificial fragmented FIFO reads and natural EOF must drain output.
        def feed(data, chunks):
            try:
                with fifo.open('wb', buffering=0) as out:
                    offset = 0
                    while offset < len(data):
                        size = chunks[offset % len(chunks)]
                        sent = out.write(data[offset:offset+size])
                        offset += sent
            except BrokenPipeError:
                pass

        p = start_fifo()
        writer = threading.Thread(target=feed, args=(images, (1, 7, 4093, 19, 4096)), daemon=True)
        writer.start()
        try:
            data, _ = p.communicate(timeout=30)
            assert p.returncode == 0 and data == expected, errors.read_bytes()
        finally:
            reap(p)
            writer.join(timeout=5)
        assert not writer.is_alive(), 'FIFO writer remained blocked'
        print('PASS fragmented input FIFO, EOF drain and exact frame ordering')

        # Slow output: force ring to its finite limit, check exact stream hash.
        large = literal_packet(bytes(range(256))*(6220800//256), 3, 1920, 1080)
        p = start_fifo()
        writer = threading.Thread(target=feed, args=(large*4, (4096,)), daemon=True)
        writer.start()
        digest = hashlib.sha256()
        received = 0
        try:
            wait_log(b'PIPELINE enabled=1', p)
            time.sleep(.5)
            deadline = time.monotonic()+30
            os.set_blocking(p.stdout.fileno(), False)
            while True:
                try:
                    chunk = os.read(p.stdout.fileno(), 16384)
                except BlockingIOError:
                    chunk = None
                if chunk == b'':
                    break
                if chunk:
                    received += len(chunk)
                    digest.update(chunk)
                assert time.monotonic() < deadline, 'slow-output timeout'
                time.sleep(.0002)
            p.wait(timeout=10)
            assert p.returncode == 0, errors.read_bytes()
            raw = bytes(range(256))*(6220800//256)
            assert received == 4*len(raw)
            assert digest.digest() == hashlib.sha256(raw*4).digest()
            assert b'ring_high_water=1024/1024' in errors.read_bytes(), errors.read_bytes()
        finally:
            reap(p)
            writer.join(timeout=5)
        assert not writer.is_alive()
        print('PASS full 4 MiB ring, slow output, no missing/reordered bytes')

        # Interrupt a reader blocked in read() while FIFO's writer stays open.
        for signo in (signal.SIGINT, signal.SIGTERM):
            hold = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
            p = start_fifo(stdout=subprocess.DEVNULL)
            try:
                wait_log(b'PIPELINE enabled=1', p)
                p.send_signal(signo)
                p.wait(timeout=10)
                assert p.returncode == 128+signo, errors.read_bytes()
            finally:
                reap(p)
                os.close(hold)
        print('PASS SIGINT/SIGTERM while input read is blocked')

        # -n must finish even with the input writer held open after one frame.
        hold = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
        p = start_fifo(extra=('-n', '1'))
        writer = threading.Thread(target=feed, args=(frame(0x33), (4096,)), daemon=True)
        writer.start()
        try:
            data, _ = p.communicate(timeout=15)
            assert p.returncode == 0 and data == b'\x33'*6220800, errors.read_bytes()
        finally:
            reap(p)
            os.close(hold)
            writer.join(timeout=5)
        assert not writer.is_alive()
        print('PASS -n drains output and cancels pending input read without waiting for EOF')

        # Interrupt blocked output/full ring with an active input producer.
        p = start_fifo()
        writer = threading.Thread(target=feed, args=(large*4, (4096,)), daemon=True)
        writer.start()
        try:
            wait_log(b'PIPELINE enabled=1', p)
            time.sleep(.5)
            p.send_signal(signal.SIGTERM)
            p.wait(timeout=10)
            assert p.returncode == 143, errors.read_bytes()
        finally:
            reap(p)
            writer.join(timeout=5)
        assert not writer.is_alive()
        print('PASS SIGTERM with output backpressure and full input queue')

        # Output failure must wake the parser and blocked read stage.
        path.write_bytes(images)
        with subprocess.Popen([rx, '-d', str(path), '--pipeline', '--stdout-rgb24'],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) as p:
            p.stdout.close()
            p.stdout = None
            _, err = p.communicate(timeout=10)
            assert p.returncode == 1 and b'RGB24 output' in err, err
        print('PASS broken-pipe failure propagation')
        result = subprocess.run([rx, '-d', str(root), '--pipeline'], capture_output=True, timeout=10)
        check(result, success=False)
        assert b'errno=' in result.stderr, result.stderr
        run(images, ['--pipeline', '-o', str(root/'missing'/'frame')], success=False)
        print('PASS input read-error and output file-error propagation')
    print('PASS receiver pipeline regression')


if __name__ == '__main__':
    main()
