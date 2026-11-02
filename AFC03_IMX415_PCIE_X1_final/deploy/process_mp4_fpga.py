#!/usr/bin/env python3
"""Send an MP4 through FPGA v31/v32 preprocessing and save verified RGB24 as MP4.

Linux/RK3576: FFmpeg decodes/encodes; FPGA performs modes 0/8/9. H2C producer,
full-CRC C2H reader and MP4 encoder overlap through bounded queues. H2C batches
up to the driver's 255-page limit; C2H retains validated 4096-byte reads.
"""
import argparse
import errno
from fractions import Fraction
import json
import mmap
import os
from pathlib import Path
import queue
import re
import select
import shlex
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time

WIDTH, HEIGHT = 1920, 1080
INPUT_BYTES = WIDTH * HEIGHT * 4
OUTPUT_BYTES = WIDTH * HEIGHT * 3
# cdev_sgdma limits each submitted transfer to 255 pages. H2C can batch to
# that aligned limit; C2H remains the independently validated 4096-byte read.
DMA_WRITE = 255 * 4096
VERSION = 0x56440032
SUPPORTED_VERSIONS = (0x56440031, 0x56440032)
HEADER = struct.Struct('<4sHHII')


class LivePreview:
    """One-frame latest-wins FIFO writer; display stalls never block MP4 output."""
    def __init__(self, path, display_process, timeout=10.0):
        self.path = os.fspath(path)
        self.display_process = display_process
        self.timeout = timeout
        self.frames = queue.Queue(maxsize=1)
        self.dropped = 0
        self.error = None
        self.fd = None
        self.opened = threading.Event()
        self.thread = threading.Thread(target=self._run, name='fpga-live-preview', daemon=True)
        self.thread.start()

    def wait_open(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self.opened.wait(0.05):
                return True
            if self.display_process.poll() is not None:
                return False
        return False

    def offer(self, frame):
        if self.error or not self.thread.is_alive():
            return
        copied = bytes(frame)
        try:
            self.frames.put_nowait(copied)
        except queue.Full:
            try:
                self.frames.get_nowait()
            except queue.Empty:
                pass
            self.dropped += 1
            try:
                self.frames.put_nowait(copied)
            except queue.Full:
                self.dropped += 1

    def _open_writer(self):
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            if self.display_process.poll() is not None:
                raise RuntimeError('GStreamer display exited before opening preview FIFO')
            try:
                return os.open(self.path, os.O_WRONLY | os.O_NONBLOCK | os.O_CLOEXEC)
            except OSError as exc:
                if exc.errno not in (errno.ENXIO, errno.EINTR):
                    raise
                time.sleep(0.05)
        raise TimeoutError('GStreamer did not open the preview FIFO')

    def _write_frame(self, frame):
        view = memoryview(frame)
        pos = 0
        deadline = time.monotonic() + self.timeout
        while pos < len(view):
            if self.display_process.poll() is not None:
                raise RuntimeError('GStreamer display stopped consuming preview frames')
            left = deadline - time.monotonic()
            if left <= 0 or not select.select([], [self.fd], [], min(left, 0.25))[1]:
                continue
            try:
                count = os.write(self.fd, view[pos:pos+(1 << 20)])
            except BlockingIOError:
                continue
            if count <= 0:
                raise RuntimeError('preview FIFO write failed')
            pos += count

    def _run(self):
        try:
            self.fd = self._open_writer()
            self.opened.set()
            while True:
                frame = self.frames.get()
                if frame is None:
                    return
                self._write_frame(frame)
        except BaseException as exc:
            self.error = exc
        finally:
            if self.fd is not None:
                os.close(self.fd)
                self.fd = None

    def close(self):
        if not self.thread.is_alive():
            return
        try:
            self.frames.put_nowait(None)
        except queue.Full:
            try:
                self.frames.get_nowait()
            except queue.Empty:
                pass
            try:
                self.frames.put_nowait(None)
            except queue.Full:
                pass
        self.thread.join(self.timeout + 1.0)
        if self.thread.is_alive():
            self.error = self.error or TimeoutError('preview writer did not stop')


def make_header(frame_id, width=WIDTH, height=HEIGHT):
    if not 1 <= frame_id <= 0xffffffff:
        raise ValueError('frame id out of range')
    return HEADER.pack(b'H2V1', width, height, frame_id, width*height*4)


def bgrx_rgb24(data):
    if len(data) % 4:
        raise ValueError('partial BGRX pixel')
    raw = bytearray(len(data)*3//4)
    raw[0::3] = data[2::4]
    raw[1::3] = data[1::4]
    raw[2::3] = data[0::4]
    return raw


def ffmpeg_commands(args, temporary_output):
    # Preserve every decoded frame; only resize/pad. No input fps filter/drop.
    vf = (f'scale={WIDTH}:{HEIGHT}:force_original_aspect_ratio=decrease,'
          f'pad={WIDTH}:{HEIGHT}:(ow-iw)/2:(oh-ih)/2,setsar=1')
    decode = ['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error',
              '-i', str(args.input), '-map', '0:v:0', '-an', '-sn', '-dn',
              '-vf', vf, '-vsync', '0', '-pix_fmt', 'bgr0']
    if args.frames:
        decode += ['-frames:v', str(args.frames)]
    decode += ['-f', 'rawvideo', 'pipe:1']
    # Native MPEG-4 encoder avoids requiring libx264 or RK hardware encoders.
    encode = ['ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error',
              '-y', '-f', 'rawvideo', '-pixel_format', 'rgb24',
              '-video_size', f'{WIDTH}x{HEIGHT}', '-framerate', str(args.fps),
              '-i', 'pipe:0', '-an', '-c:v', 'mpeg4', '-q:v', '2',
              '-pix_fmt', 'yuv420p', '-movflags', '+faststart', str(temporary_output)]
    return decode, encode


def read_exact(fd, target, timeout, allow_eof=False):
    """Read a pipe, never a DMA device. EOF is legal only between whole frames."""
    deadline = time.monotonic()+timeout
    pos = 0
    while pos < len(target):
        left = deadline-time.monotonic()
        if left <= 0 or not select.select([fd], [], [], max(0, left))[0]:
            raise TimeoutError('video frame read timed out')
        block = os.read(fd, min(1 << 20, len(target)-pos))
        if not block:
            if not pos and allow_eof:
                return False
            raise RuntimeError(f'truncated frame: {pos}/{len(target)} bytes')
        target[pos:pos+len(block)] = block
        pos += len(block)
    return True


def write_pipe(fd, data, timeout):
    deadline = time.monotonic()+timeout
    view = memoryview(data)
    pos = 0
    while pos < len(view):
        left = deadline-time.monotonic()
        if left <= 0 or not select.select([], [fd], [], max(0, left))[1]:
            raise TimeoutError('MP4 encoder pipe write timed out')
        try:
            n = os.write(fd, view[pos:pos+(1 << 20)])
        except BlockingIOError:
            continue
        if n <= 0:
            raise RuntimeError('encoder closed its input')
        pos += n


def send_frame(fd, frame_id, frame, stop, on_start=None):
    """Every H2C write starts at the same page-aligned mmap address.

    Header and pixels are one byte stream. The final write is 16 bytes;
    H2C TLAST is deliberately independent of the frame boundary.
    """
    header = make_header(frame_id)
    # A bounded reusable bounce page, independent of Python heap alignment.
    with mmap.mmap(-1, DMA_WRITE) as aligned:
        def write_aligned(data):
            if not data or len(data) > DMA_WRITE or len(data) % 16:
                raise ValueError(f'H2C chunk must be 16-byte aligned and <= {DMA_WRITE} bytes')
            if stop.is_set():
                raise InterruptedError('H2C sender cancelled')
            count = len(data)
            aligned[:count] = data
            with memoryview(aligned)[:count] as view:
                n = os.write(fd, view)
            if n != count:
                raise RuntimeError(f'short H2C write {n}/{count}; reset required')

        # Send the fixed header first and arm C2H as soon as the parser enters
        # PIXELS. It uses length-based framing and deliberately ignores TLAST.
        write_aligned(header)
        if on_start is not None:
            on_start()
        for pos in range(0, len(frame), DMA_WRITE):
            write_aligned(frame[pos:pos+DMA_WRITE])


class Registers:
    def __init__(self, base):
        self.base = base

    def read(self, offset):
        out = subprocess.check_output(['busybox', 'devmem', hex(self.base+offset), '32'], text=True)
        return int(out.strip(), 0)

    def write(self, offset, value):
        subprocess.run(['busybox', 'devmem', hex(self.base+offset), '32', str(value)], check=True)

    def snapshot(self):
        return {hex(x): hex(self.read(x)) for x in
                (0x5c, 0x60, 0x80, 0x90, 0xa4, 0xa8, 0xb8, 0xbc, 0xc8,
                 0xf4, 0xf8, 0x120, 0x124, 0x128, 0x12c, 0x130)}


def discover_bar():
    found = []
    for d in Path('/sys/bus/pci/devices').iterdir():
        try:
            if int((d/'vendor').read_text(), 0) == 0x1edb and int((d/'device').read_text(), 0) == 0xabcd:
                start, end, flags = [int(x, 16) for x in (d/'resource').read_text().splitlines()[0].split()]
                if start and end-start >= 0x133 and flags & 0x200:
                    found.append((d.name, start))
        except (OSError, ValueError):
            continue
    if len(found) != 1:
        raise RuntimeError(f'expected one accessible Anlogic memory BAR0, found {found}')
    return found[0]


def stop_child(child, sig=signal.SIGTERM):
    if child is None:
        return
    if child.poll() is None:
        child.send_signal(sig)
        try:
            child.wait(timeout=15)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=5)


def process(args):
    import fcntl  # Linux only; --help/--dry-run remain usable on Windows.
    if os.geteuid() != 0:
        raise RuntimeError('run as root for PCIe devices and BAR access')
    for command in ('ffmpeg', 'ffprobe', 'busybox', 'fuser'):
        if not shutil.which(command):
            raise RuntimeError(f'missing dependency: {command}')
    root = Path(__file__).resolve().parent
    receiver = root/'rk3576/rk3576_lz77_rx'
    if not receiver.is_file() or not os.access(receiver, os.X_OK):
        raise RuntimeError('build receiver first: cd rk3576 && bash build.sh')
    if shutil.which('pgrep') and subprocess.run(['pgrep', '-x', 'gst-launch-1.0'],
                                                 stdout=subprocess.DEVNULL,
                                                 stderr=subprocess.DEVNULL).returncode == 0:
        raise RuntimeError('stop the existing GStreamer/KMS playback before starting live preview')
    devices = ('/dev/ANLOGIC-PCI0_h2c_0', '/dev/ANLOGIC-PCI0_c2h_0', '/dev/video73')
    for name in devices[:2]:
        if not Path(name).exists() or not stat.S_ISCHR(os.stat(name).st_mode):
            raise RuntimeError(f'DMA character device missing: {name}')
    lock = open('/run/lock/anlogic-mp4-fpga.lock', 'a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    if subprocess.run(['fuser', *devices], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        raise RuntimeError('stop all camera, H2C and C2H users before file processing')
    bdf, base = discover_bar()
    reg = Registers(base)
    actual = reg.read(0x5c)
    if actual not in SUPPORTED_VERSIONS:
        raise RuntimeError(f'H2V1 requires v31/v32, got 0x{actual:08x}; regenerate compress bit')
    subprocess.run([str(receiver), '--self-test-crc'], check=True)
    encoder_info = subprocess.check_output(['ffmpeg', '-hide_banner', '-h', 'encoder=mpeg4'], stderr=subprocess.STDOUT, text=True)
    if 'Encoder mpeg4' not in encoder_info:
        raise RuntimeError('FFmpeg native mpeg4 encoder unavailable')
    if args.fps is None:
        streams = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
                            '-show_entries', 'stream=avg_frame_rate,r_frame_rate', '-of', 'json', str(args.input)], text=True))['streams']
        if not streams:
            raise RuntimeError('no video stream in input')
        rate = streams[0].get('avg_frame_rate', '0/0')
        try:
            valid = 0 < Fraction(rate) <= 240
        except (ValueError, ZeroDivisionError):
            valid = False
        if not valid:
            raise RuntimeError('unknown input frame rate; specify --fps 30 or --fps 60')
        args.fps = rate
    args.output.parent.mkdir(parents=True, exist_ok=True)
    logdir = Path(tempfile.mkdtemp(prefix='mp4-fpga.', dir='/tmp'))
    print(f'BDF={bdf} BAR0={hex(base)} FPGA={hex(actual)} Logs: {logdir}', flush=True)
    tmpfd, tmpname = tempfile.mkstemp(prefix=args.output.stem+'.part-', suffix='.mp4', dir=args.output.parent)
    os.close(tmpfd)
    temporary = Path(tmpname)
    decode_cmd, encode_cmd = ffmpeg_commands(args, temporary)
    (logdir/'commands.json').write_text(json.dumps({'decode': decode_cmd, 'encode': encode_cmd}, indent=2))
    original = {off: reg.read(off) for off in (0x80, 0x90, 0xa4, 0xa8)}
    (logdir/'before.json').write_text(json.dumps(reg.snapshot(), indent=2))
    decoder = encoder = rx = None
    display = None
    preview = None
    preview_fifo = None
    writer = None
    h2c = None
    touched = False
    done = False
    stop = threading.Event()
    metas = queue.Queue(maxsize=4)
    ready = threading.Event()
    errors = queue.Queue(maxsize=1)
    decoder_thread = sender_thread = receiver_thread = encoder_thread = None
    input_frames = queue.Queue(maxsize=2)
    encode_frames = queue.Queue(maxsize=2)
    inflight_inputs = {}
    inflight_lock = threading.Lock()
    sent_cond = threading.Condition()
    started_frames = 0
    sender_done = threading.Event()
    decoder_done = threading.Event()
    received = 0
    first_frame = None
    handles = []

    def logfile(name):
        h = open(logdir/name, 'wb')
        handles.append(h)
        return h

    def pump_log(pipe, dest):
        for line in iter(pipe.readline, b''):
            dest.write(line)
            dest.flush()
            if b'PIPELINE enabled=1' in line:
                ready.set()
            match = re.match(rb'frame=(\d+) ', line)
            if match:
                try:
                    metas.put_nowait(int(match[1]))
                except queue.Full:
                    stop.set()

    def fail_worker(exc):
        try:
            errors.put_nowait(exc)
        except queue.Full:
            pass
        stop.set()
        with sent_cond:
            sent_cond.notify_all()

    def decode_worker(initial_frame):
        try:
            frame_id = 1
            current = initial_frame
            while current is not None and not stop.is_set():
                while not stop.is_set():
                    try:
                        input_frames.put((frame_id, current), timeout=0.1)
                        break
                    except queue.Full:
                        continue
                frame_id += 1
                current_buf = bytearray(INPUT_BYTES)
                current = current_buf if read_exact(decoder.stdout.fileno(), current_buf,
                                                     args.timeout, allow_eof=True) else None
                if current is not None:
                    current = bytes(current_buf)
            if decoder.wait(timeout=args.timeout) != 0:
                raise RuntimeError('FFmpeg decoder failed; see decode.log')
        except BaseException as exc:
            fail_worker(exc)
        finally:
            decoder_done.set()
            while True:
                try:
                    input_frames.put(None, timeout=0.1)
                    break
                except queue.Full:
                    if stop.is_set():
                        try:
                            input_frames.get_nowait()
                        except queue.Empty:
                            pass

    def wait_host_ready():
        deadline = time.monotonic() + args.timeout
        while not stop.is_set() and time.monotonic() < deadline:
            status = reg.read(0x124)
            if status & 0x8:
                raise RuntimeError(f'FPGA H2V1 parser entered FAULT: status={status:#010x}')
            if status & 0x2:
                return
            time.sleep(0.002)
        if stop.is_set():
            raise InterruptedError('H2C sender cancelled')
        raise TimeoutError('FPGA did not become ready for the next H2V1 frame')

    def h2c_worker():
        nonlocal started_frames
        try:
            next_id = 1
            while True:
                try:
                    item = input_frames.get(timeout=0.1)
                except queue.Empty:
                    if stop.is_set() or decoder_done.is_set():
                        break
                    continue
                if item is None:
                    break
                frame_id, pixels = item
                if frame_id != next_id:
                    raise RuntimeError(f'decoder queue order error: got {frame_id}, expected {next_id}')
                wait_host_ready()
                with inflight_lock:
                    inflight_inputs[frame_id] = pixels
                def mark_frame_started():
                    nonlocal started_frames
                    with sent_cond:
                        started_frames = frame_id
                        sent_cond.notify_all()
                # Let C2H receive while the rest of this frame is still on H2C.
                send_frame(h2c, frame_id, pixels, stop, on_start=mark_frame_started)
                next_id += 1
            sender_done.set()
            with sent_cond:
                sent_cond.notify_all()
        except BaseException as exc:
            fail_worker(exc)
            sender_done.set()
            with sent_cond:
                sent_cond.notify_all()

    def c2h_worker():
        nonlocal received
        output = bytearray(OUTPUT_BYTES)
        expected_id = 1
        try:
            while not stop.is_set():
                with sent_cond:
                    deadline = time.monotonic() + args.timeout
                    while started_frames < expected_id and not sender_done.is_set() and not stop.is_set():
                        left = deadline - time.monotonic()
                        if left <= 0:
                            raise TimeoutError(f'waiting for H2C frame {expected_id} timed out')
                        sent_cond.wait(min(left, 0.1))
                    if stop.is_set():
                        return
                    if started_frames < expected_id and sender_done.is_set():
                        return
                if not read_exact(rx.stdout.fileno(), output, args.timeout):
                    raise RuntimeError('C2H returned EOF before all H2C frames were received')
                try:
                    actual_id = metas.get(timeout=args.timeout)
                except queue.Empty:
                    raise RuntimeError('no CRC-verified frame metadata received')
                if actual_id != expected_id:
                    raise RuntimeError(f'frame ordering mismatch {actual_id}, expected {expected_id}')
                with inflight_lock:
                    original_input = inflight_inputs.pop(expected_id, None)
                if original_input is None:
                    raise RuntimeError(f'missing original frame buffer for frame {expected_id}')
                if args.mode == 0 and output != bgrx_rgb24(original_input):
                    raise RuntimeError(f'mode0 exact RGB24 round-trip mismatch, frame {expected_id}')
                for off in (0xbc, 0xc8, 0x12c, 0x120):
                    if reg.read(off):
                        raise RuntimeError(f'FPGA integrity error at BAR0+{hex(off)}')
                encoded_frame = bytes(output)
                while not stop.is_set():
                    try:
                        encode_frames.put(encoded_frame, timeout=0.1)
                        break
                    except queue.Full:
                        continue
                else:
                    return
                if preview is not None:
                    preview.offer(output)
                received += 1
                expected_id += 1
                if received == 1 or received % 30 == 0:
                    print(f'frames={received} processing_fps={received/(time.monotonic()-started):.3f} CRC=full', flush=True)
        except BaseException as exc:
            fail_worker(exc)

    def encoder_worker():
        try:
            while True:
                try:
                    frame_data = encode_frames.get(timeout=0.1)
                except queue.Empty:
                    if stop.is_set():
                        return
                    continue
                if frame_data is None:
                    return
                write_pipe(encoder.stdin.fileno(), frame_data, args.timeout)
        except BaseException as exc:
            fail_worker(exc)

    try:
        if args.display:
            display_script = root/'display_lz77_video.py'
            if not display_script.is_file():
                raise RuntimeError('display_lz77_video.py is missing from deploy')
            import stat as stat_module
            fd, fifo_name = tempfile.mkstemp(prefix='mp4-preview.', dir='/tmp')
            os.close(fd)
            os.unlink(fifo_name)
            os.mkfifo(fifo_name, 0o600)
            preview_fifo = Path(fifo_name)
            display = subprocess.Popen([
                sys.executable, str(display_script), '--fifo', preview_fifo,
                '--rx-log', logdir/'rx.log', '--mode', str(args.mode),
                '--connector', str(args.connector),
            ], stdout=logfile('display.log'), stderr=subprocess.STDOUT, bufsize=0)
            preview = LivePreview(preview_fifo, display, min(args.timeout, 5.0))
            # filesrc on a FIFO may preroll asynchronously and cannot report
            # PLAYING until it receives pixels. Wait for its FIFO reader, not
            # its ready/PLAYING state, or producer and display deadlock.
            if not preview.wait_open(10):
                raise RuntimeError('GStreamer did not open the preview FIFO; see display.log')
            print(f'Live preview enabled on connector={args.connector}; preview_queue=1 latest-wins', flush=True)
        decoder = subprocess.Popen(decode_cmd, stdout=subprocess.PIPE, stderr=logfile('decode.log'), bufsize=0)
        frame = bytearray(INPUT_BYTES)
        if not read_exact(decoder.stdout.fileno(), frame, args.timeout, allow_eof=True):
            raise RuntimeError('input has no decodable video frames')
        first_frame = bytes(frame)
        # Stop and reset BEFORE selecting the host; the selector is write-locked while enabled.
        touched = True
        reg.write(0x60, 0)
        reg.write(0x80, 2)
        reg.write(0x90, 0)
        reg.write(0xa4, args.mode)
        reg.write(0xa8, 1)
        reg.write(0x60, 2)
        time.sleep(0.05)
        for off, expected in ((0x80, 2), (0x90, 0), (0xa4, args.mode), (0xa8, 1), (0x12c, 0)):
            if reg.read(off) != expected:
                raise RuntimeError(f'FPGA register readback mismatch at {hex(off)}')
        h2c = os.open(devices[0], os.O_WRONLY | os.O_CLOEXEC)
        rx_cmd = [str(receiver), '-d', devices[1], '-n', '0', '-v', '--stdout-rgb24', '--pipeline', '--crc', 'auto', '--profile']
        rx = subprocess.Popen(rx_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        threading.Thread(target=pump_log, args=(rx.stderr, logfile('rx.log')), daemon=True).start()
        if not ready.wait(5) or rx.poll() is not None:
            raise RuntimeError('receiver startup failed; see rx.log')
        encoder = subprocess.Popen(encode_cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=logfile('encode.log'), bufsize=0)
        os.set_blocking(encoder.stdin.fileno(), False)
        reg.write(0x60, 1)
        if reg.read(0x124) & 3 != 3:
            raise RuntimeError('H2V1 input not enabled/ready')
        started = time.monotonic()
        decoder_thread = threading.Thread(target=decode_worker, args=(first_frame,), name='ffmpeg-decoder', daemon=True)
        sender_thread = threading.Thread(target=h2c_worker, name='h2c-sender', daemon=True)
        receiver_thread = threading.Thread(target=c2h_worker, name='c2h-receiver', daemon=True)
        encoder_thread = threading.Thread(target=encoder_worker, name='mp4-encoder-writer', daemon=True)
        decoder_thread.start()
        sender_thread.start()
        receiver_thread.start()
        encoder_thread.start()
        while receiver_thread.is_alive():
            receiver_thread.join(0.1)
            if not errors.empty():
                raise errors.get()
        sender_thread.join(args.timeout)
        decoder_thread.join(args.timeout)
        if sender_thread.is_alive() or decoder_thread.is_alive():
            raise TimeoutError('MP4 pipeline worker did not stop')
        if not errors.empty():
            raise errors.get()
        if not decoder_done.is_set() or not sender_done.is_set():
            raise RuntimeError('MP4 input/sender workers ended without EOF completion')
        encode_frames.put(None, timeout=args.timeout)
        encoder_thread.join(args.timeout + 2)
        if encoder_thread.is_alive():
            raise TimeoutError('MP4 encoder input worker did not stop')
        if not errors.empty():
            raise errors.get()
        encoder.stdin.close()
        if encoder.wait(timeout=args.timeout) != 0:
            raise RuntimeError('FFmpeg encoder failed; see encode.log')
        if preview is not None:
            preview.close()
            if preview.error:
                raise RuntimeError(f'Live preview failed: {preview.error}')
        if reg.read(0x128) != received or reg.read(0xb8) != received:
            raise RuntimeError('FPGA input/output frame count mismatch')
        (logdir/'after.json').write_text(json.dumps(reg.snapshot(), indent=2))
        # Confirm the finished container carries every processed frame.
        info = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
                         '-show_entries', 'stream=width,height,nb_frames', '-of', 'json', str(temporary)], text=True))['streams'][0]
        if (info.get('width'), info.get('height'), int(info.get('nb_frames', -1))) != (WIDTH, HEIGHT, received):
            raise RuntimeError(f'output MP4 geometry/frame count mismatch: {info}')
        # Same-directory hard link publishes atomically and refuses an existing target.
        os.link(temporary, args.output)
        temporary.unlink()
        done = True
        summary = {'input': str(args.input), 'output': str(args.output), 'mode': args.mode,
                   'frames': received, 'fps': args.fps, 'geometry': [WIDTH, HEIGHT],
                   'pipeline': 'bounded H2C producer overlaps CRC/C2H/encode/display',
                   'input_format': 'BGRX8888', 'crc': 'full', 'c2h_read_size': 4096,
                   'mode0_exact_check': args.mode == 0, 'audio': False,
                   'live_preview': args.display,
                   'preview_dropped_frames': preview.dropped if preview is not None else 0}
        (logdir/'result.json').write_text(json.dumps(summary, indent=2))
        print(f'PASS frames={received}; output={args.output}; logs={logdir}', flush=True)
    finally:
        stop.set()
        if preview is not None:
            preview.close()
            if preview.error:
                print(f'Live preview stopped: {preview.error}; MP4 processing continues independently',
                      file=sys.stderr, flush=True)
        stop_child(decoder)
        stop_child(rx, signal.SIGINT)
        if decoder_thread is not None:
            decoder_thread.join(2)
        if sender_thread is not None:
            sender_thread.join(args.timeout + 2)
        sender_stuck = sender_thread is not None and sender_thread.is_alive()
        if sender_stuck:
            print('H2C DMA still pending; do not change FPGA source/reset until driver timeout retires it',
                  file=sys.stderr, flush=True)
        if receiver_thread is not None:
            receiver_thread.join(2)
        if encoder_thread is not None and encoder_thread.is_alive():
            try:
                encode_frames.put_nowait(None)
            except queue.Full:
                pass
            encoder_thread.join(2)
        if h2c is not None and not sender_stuck:
            os.close(h2c)
        stop_child(encoder)
        stop_child(display, signal.SIGINT)
        if touched and not sender_stuck:
            reg.write(0x60, 0)
            reg.write(0x60, 2)
            time.sleep(0.05)
            for off, value in original.items():
                reg.write(off, value)
            reg.write(0x60, 0)
        for h in handles:
            h.close()
        if preview_fifo is not None:
            try:
                preview_fifo.unlink()
            except FileNotFoundError:
                pass
        if not done and temporary.exists():
            temporary.unlink()
        print(f'FPGA stopped; logs retained: {logdir}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path, help='input MP4/video path on RK3576')
    parser.add_argument('--mode', type=int, choices=(0, 8, 9), required=True)
    parser.add_argument('--output', type=Path, required=True, help='new output MP4 path; existing files refused')
    parser.add_argument('--frames', type=int, default=0, help='limit decoded input frames; 0 processes entire video')
    parser.add_argument('--fps', type=int, help='output playback FPS override, default input average FPS; input frames never dropped')
    parser.add_argument('--timeout', type=float, default=30, help='per-frame timeout in seconds')
    parser.add_argument('--display', action='store_true', help='show FPGA-returned frames during processing; preview drops old frames if display is slow')
    parser.add_argument('--connector', type=int, default=188, help='KMS connector id for --display')
    parser.add_argument('--dry-run', action='store_true', help='print commands/protocol; no device access or output files')
    args = parser.parse_args()
    args.input = args.input.expanduser().resolve()
    args.output = args.output.expanduser().resolve()
    if not args.input.is_file():
        parser.error('input video does not exist')
    if args.output.exists() or args.output == args.input:
        parser.error('output must be a new path, different from input')
    if args.frames < 0 or (args.fps is not None and not 1 <= args.fps <= 60) or not 10 <= args.timeout <= 300 or args.connector < 0:
        parser.error('require frames>=0, fps=1..60, timeout=10..300')
    if args.output.suffix.lower() != '.mp4':
        parser.error('output filename must end in .mp4')
    if args.dry_run:
        args.fps = args.fps or 'INPUT_AVERAGE_FPS'
        commands = ffmpeg_commands(args, args.output)
        print('Requires FPGA v31/v32 H2V1; v32 uses T0=40/omega=85/bias=8; full CRC BLK1; C2H read=4096; H2C max=255 pages')
        if args.display:
            print(f'Live preview: existing display_lz77_video.py, connector={args.connector}; latest-frame queue')
        for command in commands:
            print(shlex.join(command))
        return 0
    def interrupted(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        process(args)
        return 0
    except KeyboardInterrupt:
        print('Interrupted; FPGA stopped and no final MP4 published', file=sys.stderr)
        return 130
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
