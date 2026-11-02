import argparse
import collections
import shutil
import tempfile
import tarfile
import hashlib
import ctypes
import mmap
import os
import pathlib
import subprocess
import sys
import time

parser = argparse.ArgumentParser(description="Bounded raw C2H capture for EOP/read-size A/B; no decoding.")
parser.add_argument("--read-size", type=int, choices=(4096, 16384, 65536), default=16384)
parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path("/home/linaro/lz77-capture"))
args = parser.parse_args()
if not hasattr(os, "geteuid") or os.geteuid() != 0:
    parser.error("Run as root on RK3576")
for command in ("busybox", "fuser", "dmesg"):
    if shutil.which(command) is None:
        parser.error("Missing command: " + command)
occupied = subprocess.run(["fuser", "/dev/video73", "/dev/ANLOGIC-PCI0_c2h_0"],
                          capture_output=True, text=True)
if occupied.returncode == 0:
    raise SystemExit("Device is in use; stop existing readers first. " + occupied.stdout)
if occupied.returncode != 1:
    raise SystemExit("Cannot verify device ownership: " + occupied.stderr)
args.root.mkdir(parents=True, exist_ok=True)
out = pathlib.Path(tempfile.mkdtemp(prefix=f"read{args.read_size}.", dir=str(args.root)))
print("Capture directory:", out, flush=True)
capture_log = (out / "capture.log").open("w", buffering=1)
def report(message):
    print(message, flush=True)
    capture_log.write(message + "\n")
def dmesg(name):
    with (out / name).open("wb") as log:
        subprocess.run(["dmesg"], stdout=log, stderr=subprocess.STDOUT, check=False)
dmesg("dmesg.before.log")
base = int(os.environ.get("BAR0", "0x21200000"), 0)
device = "/dev/ANLOGIC-PCI0_c2h_0"
limit = 32 * 1024 * 1024
size = args.read_size
offsets = [0x5c, 0x60, 0x84, 0x88, 0x90, 0xa4, 0xa8,
           0xac, 0xb0, 0xb4, 0xb8, 0xbc, 0xc0, 0xc4, 0xc8,
           0xcc, 0xd0, 0xd4, 0xd8, 0xdc, 0xe0, 0xe4, 0xe8,
           0xec, 0xf0, 0xf4, 0xf8] + list(range(0x100, 0x120, 4))

def reg(off, value=None):
    cmd = ["busybox", "devmem", hex(base + off), "32"]
    if value is not None:
        cmd.append(str(value))
    result = subprocess.run(cmd, check=True, capture_output=True, text=True)
    return int(result.stdout.strip(), 0) if value is None else None

def snapshot(name):
    with (out / name).open("w") as log:
        for off in offsets:
            log.write(f"BAR0+0x{off:x}=0x{reg(off):08X}\n")

version = reg(0x5c)
if version not in (0x56440026, 0x56440027, 0x56440028):
    raise SystemExit(f"Unexpected FPGA version: 0x{version:08x}")
report(f"BAR0={base:#x} VERSION={version:#x}")
fd = None
buf = None
total = reads = 0
lengths = collections.Counter()
try:
    reg(0x60, 0)
    reg(0x90, 0)
    reg(0xa4, 0)
    reg(0xa8, 1)
    reg(0x60, 2)
    for attempt in range(100):
        status = reg(0xcc)
        if status & 7 == 7 and (status >> 24) & 255 == 0:
            break
        time.sleep(0.1)
    else:
        raise RuntimeError(f"DDR not ready: {status:#x}")
    snapshot("before.log")
    buf = mmap.mmap(-1, size)
    address = ctypes.addressof(ctypes.c_char.from_buffer(buf))
    libc = ctypes.CDLL(None, use_errno=True)
    libc.read.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_size_t]
    libc.read.restype = ctypes.c_ssize_t
    with (out / "capture.bin").open("xb") as capture, (out / "read_lengths.tsv").open("x") as log:
        log.write("read\tmonotonic_ns\toffset\tlength\n")
        fd = os.open(device, os.O_RDONLY | os.O_CLOEXEC | os.O_TRUNC)
        report(f"C2H open; buffer_address={address:#x}; read_size={size}; limit={limit}")
        reg(0x60, 1)
        while total < limit:
            n = libc.read(fd, address, size)
            if n < 0:
                code = ctypes.get_errno()
                raise OSError(code, os.strerror(code))
            if n == 0:
                report("C2H returned EOF")
                break
            if n > size:
                raise RuntimeError(f"Driver returned invalid read length {n}")
            with memoryview(buf) as view:
                capture.write(view[:n])
            reads += 1
            lengths[n] += 1
            log.write(f"{reads}\t{time.monotonic_ns()}\t{total}\t{n}\n")
            total += n
            if reads <= 8 or reads % 256 == 0:
                report(f"READ {reads} got={n} captured={total}")
except KeyboardInterrupt:
    report("Capture stopped by time limit or Ctrl+C")
except Exception as exc:
    report(f"CAPTURE ERROR: {type(exc).__name__}: {exc}")
finally:
    try:
        reg(0x60, 0)
    finally:
        if fd is not None:
            os.close(fd)
        if buf is not None:
            buf.close()
    snapshot("after.log")
    report(f"END captured_bytes={total} reads={reads} common_read_lengths={lengths.most_common(8)}")
    dmesg("dmesg.after.log")
    capture_log.close()
    raw_path = out / "capture.bin"
    if raw_path.is_file():
        digest = hashlib.sha256(raw_path.read_bytes()).hexdigest()
        (out / "capture.sha256").write_text(f"{digest}  capture.bin\n", encoding="ascii")
    archive = out.with_name(out.name + ".tar.gz")
    with tarfile.open(archive, "w:gz") as tar:
        tar.add(out, arcname=out.name)
    print("Archive:", archive, flush=True)
