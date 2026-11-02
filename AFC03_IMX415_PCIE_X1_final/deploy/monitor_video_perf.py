#!/usr/bin/env python3
"""Read-only frame/counter and frequency samples; never opens DMA or V4L2."""
import argparse
import signal
import subprocess
import time
from pathlib import Path


def delta_counter(current, previous, bits=32):
    return (current - previous) & ((1 << bits) - 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--bar0', type=lambda v: int(v, 0), default=0x21200000)
    ap.add_argument('--compressed', action='store_true')
    args = ap.parse_args()
    stopped = False

    def stop(_sig, _frame):
        nonlocal stopped
        stopped = True

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, stop)

    def reg(offset):
        result = subprocess.run(['busybox', 'devmem', hex(args.bar0 + offset), '32'],
                                capture_output=True, text=True, timeout=2, check=True)
        return int(result.stdout.strip(), 16)

    version = reg(0x5c)
    if version not in (0x56440025, 0x56440026, 0x56440027, 0x56440028, 0x56440029, 0x56440030, 0x56440031, 0x56440032):
        raise SystemExit(f'Unsupported FPGA register map: {version:#010x}')
    # Upper byte of CAM_FRAME_COUNT holds sticky flags, not frame count.
    counters = {'camera': (0x88, 24), 'raw_gate_pass': (0xa0, 32),
                'raw_gate_drop': (0x9c, 32), 'cam_fifo_drop': (0xc8, 32)}
    if args.compressed:
        counters.update(comp_frames=(0xb8, 32), comp_bytes=(0xb0, 32),
                        ddr_no_slot=(0xd4, 32), ddr_invalid=(0xd8, 32))
    if version in (0x56440030, 0x56440031, 0x56440032):
        counters['dehaze_errors'] = (0x120, 32)
    state = {}
    while not stopped:
        fields = []
        # Diagnostic words are read sequentially, not an atomic snapshot.
        fields.append(f'control={reg(0x60):#010x}')
        camera_status = reg(0x84)
        fields.append(f'camera_status={camera_status:#010x}')
        fields.append(f'mipi_best_len={(camera_status >> 6) & 63}')
        fields.append(f'debug_state={reg(0x74):#010x}')
        fields.append(f'dma_beats={reg(0x7c)}')
        if args.compressed and version in (0x56440028, 0x56440029, 0x56440030, 0x56440031, 0x56440032):
            queue_status = reg(0xec)
            fields.append(f'ddr_slot_capacity={(queue_status >> 24) & 255}')
            fields.append(f'ddr_ready_queued={(queue_status >> 16) & 255}')
        for name, (offset, bits) in counters.items():
            raw_value = reg(offset)
            value = raw_value & ((1 << bits) - 1)
            now = time.monotonic()
            fields.append(f'{name}_value={value}')
            if name == 'camera':
                fields.append(f'camera_stage_flags={(raw_value >> 24) & 255:#04x}')
            if name in state:
                previous, sampled = state[name]
                elapsed = now - sampled
                # A sampled decrease may be soft reset OR counter rollover.
                # Without a reset epoch, neither can be assumed: rebase and
                # omit that interval's rate instead of inventing billions/sec.
                if value < previous:
                    fields.append(f'{name}_discontinuity=1')
                else:
                    change = delta_counter(value, previous, bits)
                    fields.append(f'{name}_per_s={change / elapsed:.3f}')
            state[name] = value, now
        for pattern, attribute in (('/sys/devices/system/cpu/cpufreq/policy*', 'scaling_cur_freq'),
                                   ('/sys/class/devfreq/*npu*', 'cur_freq'),
                                   ('/sys/class/thermal/thermal_zone*', 'temp')):
            for folder in sorted(Path('/').glob(pattern.lstrip('/'))):
                try:
                    fields.append(f'{folder.name}_{attribute}={(folder / attribute).read_text().strip()}')
                except OSError:
                    pass
        print('HARDWARE ' + ' '.join(fields), flush=True)
        until = time.monotonic() + 2
        while not stopped and time.monotonic() < until:
            time.sleep(0.1)


if __name__ == '__main__':
    main()
