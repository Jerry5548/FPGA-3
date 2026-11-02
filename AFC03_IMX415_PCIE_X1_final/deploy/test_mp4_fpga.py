#!/usr/bin/env python3
"""Offline transport checks; no FPGA, root, FFmpeg or third-party modules needed."""
import argparse
import ctypes
import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

script = Path(__file__).with_name('process_mp4_fpga.py')
spec = importlib.util.spec_from_file_location('process_mp4_fpga', script)
mp4 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mp4)


class TransportTests(unittest.TestCase):
    def test_h2c_exact_stream_and_page_alignment(self):
        data = bytes(range(256)) * (mp4.DMA_WRITE // 256) + bytes(range(112))
        writes = []
        addresses = []
        starts = []
        def sink(fd, view):
            self.assertEqual(fd, 123)
            address = ctypes.addressof(ctypes.c_char.from_buffer(view))
            self.assertEqual(address % 4096, 0)
            addresses.append(address)
            writes.append(bytes(view))
            return len(view)
        with patch.object(mp4.os, 'write', side_effect=sink):
            mp4.send_frame(123, 7, data, threading.Event(), on_start=lambda: starts.append(len(writes)))
        self.assertEqual(b''.join(writes), mp4.make_header(7) + data)
        self.assertEqual([len(x) for x in writes], [16, mp4.DMA_WRITE, 112])
        self.assertEqual(len(set(addresses)), 1)
        self.assertEqual(starts, [1])

    def test_h2c_batch_size_is_driver_aligned_limit(self):
        self.assertEqual(mp4.DMA_WRITE, 255*4096)
        self.assertLessEqual(mp4.DMA_WRITE, 1024*1024)
        self.assertEqual(mp4.DMA_WRITE % 4096, 0)

    def test_short_write_rejected_without_retry_or_byte_shift(self):
        with patch.object(mp4.os, 'write', return_value=16) as write:
            with self.assertRaisesRegex(RuntimeError, 'short H2C'):
                mp4.send_frame(123, 1, bytes(4096), threading.Event())
            self.assertEqual(write.call_count, 2)  # header succeeds, first payload chunk is rejected.

    def test_cancel_before_dma(self):
        event = threading.Event()
        event.set()
        with patch.object(mp4.os, 'write') as write:
            with self.assertRaises(InterruptedError):
                mp4.send_frame(123, 1, bytes(16), event)
            write.assert_not_called()

    def test_preview_queue_keeps_only_latest_frame(self):
        class Alive:
            @staticmethod
            def is_alive():
                return True
        preview = mp4.LivePreview.__new__(mp4.LivePreview)
        preview.error = None
        preview.thread = Alive()
        preview.frames = __import__('queue').Queue(maxsize=1)
        preview.dropped = 0
        preview.offer(b'frame1')
        preview.offer(b'frame2')
        preview.offer(b'frame3')
        self.assertEqual(preview.dropped, 2)
        self.assertEqual(preview.frames.get_nowait(), b'frame3')

    def test_preview_open_wait_does_not_require_gstreamer_preroll(self):
        class Alive:
            @staticmethod
            def poll():
                return None
        preview = mp4.LivePreview.__new__(mp4.LivePreview)
        preview.display_process = Alive()
        preview.opened = threading.Event()
        worker = threading.Thread(target=lambda: (time.sleep(0.03), preview.opened.set()))
        worker.start()
        self.assertTrue(preview.wait_open(1))
        worker.join()

    def test_header_and_rgb_order(self):
        self.assertEqual(struct.unpack('<4sHHII', mp4.make_header(2)),
                         (b'H2V1', 1920, 1080, 2, 8294400))
        self.assertEqual(mp4.bgrx_rgb24(bytes([1, 2, 3, 99, 11, 12, 13, 0])),
                         bytes([3, 2, 1, 13, 12, 11]))
        with self.assertRaises(ValueError):
            mp4.make_header(0)

    def test_ffmpeg_uses_fpga_pixels_no_enhancement_filter(self):
        args = argparse.Namespace(input=Path('input with spaces.mp4'), frames=3, fps=30)
        decode, encode = mp4.ffmpeg_commands(args, Path('new output.mp4'))
        self.assertEqual(decode[decode.index('-i')+1], str(args.input))
        self.assertEqual(decode[decode.index('-pix_fmt')+1], 'bgr0')
        self.assertEqual(decode[decode.index('-frames:v')+1], '3')
        filters = decode[decode.index('-vf')+1]
        self.assertTrue(filters.startswith('scale=1920:1080:'))
        self.assertNotIn('eq=', filters)
        self.assertNotIn('gamma', filters)
        self.assertEqual(encode[encode.index('-pixel_format')+1], 'rgb24')
        self.assertEqual(encode[encode.index('-i')+1], 'pipe:0')
        self.assertEqual(encode[-1], 'new output.mp4')

    def test_existing_input_output_protected_and_dry_run_no_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            src = Path(temp)/'input.mp4'
            dst = Path(temp)/'output.mp4'
            src.write_bytes(b'input remains untouched')
            cmd = [sys.executable, str(script), str(src), '--mode', '9', '--output', str(dst)]
            run = subprocess.run(cmd+['--dry-run'], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertFalse(dst.exists())
            self.assertEqual(src.read_bytes(), b'input remains untouched')
            run = subprocess.run(cmd+['--dry-run', '--display', '--connector', '188'], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn('Live preview', run.stdout)
            dst.write_bytes(b'existing output')
            run = subprocess.run(cmd+['--dry-run'], capture_output=True, text=True)
            self.assertNotEqual(run.returncode, 0)
            self.assertEqual(dst.read_bytes(), b'existing output')
            run = subprocess.run([sys.executable, str(script), str(src), '--mode', '8',
                                  '--output', str(src), '--dry-run'], capture_output=True)
            self.assertNotEqual(run.returncode, 0)
            self.assertEqual(src.read_bytes(), b'input remains untouched')


if __name__ == '__main__':
    unittest.main(verbosity=2)
