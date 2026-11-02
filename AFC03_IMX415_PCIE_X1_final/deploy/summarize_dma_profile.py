#!/usr/bin/env python3
"""Summarize aggregate kernel timings. Waiting includes hardware AND scheduling."""
import argparse
from pathlib import Path

OUTER = ('user_map', 'submit', 'user_unmap')
INNER = ('dma_map', 'request_build', 'desc_lock', 'desc_build', 'queue_start',
         'poll_kick', 'completion_wait', 'completion_reap', 'submit_cleanup')


def parse(text):
    values = {}
    for line in text.splitlines():
        if '=' in line:
            key, value = line.strip().split('=', 1)
            if key in values:
                raise ValueError(f'duplicate key {key}')
            values[key] = value
    if values.get('version') != 'dma-profile-20261016':
        raise ValueError('unexpected driver profile version')
    for key in ('calls', 'errors', 'short_reads', 'zero_reads', 'completed_bytes',
                'elapsed_ns', 'total_ns', 'max_total_ns', 'poll_empty') + tuple(
                    name+'_ns' for name in OUTER+INNER):
        values[key] = int(values[key])
        if values[key] < 0:
            raise ValueError(f'negative {key}')
    if not values['calls']:
        raise ValueError('no measured 4096-byte char ST C2H reads')
    optional = ('wait_spin_calls', 'wait_spin_ready', 'wait_spin_ns')
    if any(key in values for key in optional):
        for key in optional:
            values[key] = int(values[key])
            if values[key] < 0:
                raise ValueError(f'negative {key}')
        if values['wait_spin_ready'] > values['wait_spin_calls']:
            raise ValueError('wait spin ready count exceeds attempts')
    return values


def report(v):
    calls, total, elapsed = v['calls'], v['total_ns'], v['elapsed_ns']
    print(f"DMA_PROFILE calls={calls} errors={v['errors']} short_reads={v['short_reads']} "
          f"zero_reads={v['zero_reads']} poll_empty={v['poll_empty']}")
    print(f"completed_bytes={v['completed_bytes']} elapsed_s={elapsed/1e9:.6f} "
          f"payload_MBps={v['completed_bytes']*1000/elapsed if elapsed else 0:.3f}")
    print(f"measured_call_avg_us={total/calls/1000:.3f} max_call_ms={v['max_total_ns']/1e6:.3f}")
    print('OUTER stages (partition of measured call; excludes initial checks and summary-update cost):')
    for name in OUTER:
        ns = v[name+'_ns']
        print(f'  {name:20s} avg_us={ns/calls/1000:9.3f} share_total={100*ns/total if total else 0:6.2f}%')
    print('INNER stages (inside submit; do not add these to the outer submit value):')
    submit = v['submit_ns']
    for name in INNER:
        ns = v[name+'_ns']
        print(f'  {name:20s} avg_us={ns/calls/1000:9.3f} share_submit={100*ns/submit if submit else 0:6.2f}%')
    print('completion_wait includes FPGA data waiting, DMA, polling/notification and task scheduling.')
    print('completion_reap includes normal transfer teardown and its DMA unmap when applicable.')
    print('poll_empty counts all ST C2H engines while enabled; short EOP reads may be valid.')
    if 'wait_spin_calls' in v:
        count = v['wait_spin_calls']
        print(f"WAIT_SPIN attempts={count} ready_before_sleep={v['wait_spin_ready']} "
              f"ready_percent={100*v['wait_spin_ready']/count if count else 0:.2f} "
              f"avg_us={v['wait_spin_ns']/count/1000 if count else 0:.3f}")
        print('wait_spin_ns is nested inside completion_wait_ns; do not add it again. '
              'Ready means state changed; check transfer errors separately.')
    print('Profiling adds overhead; compare throughput again with profiling disabled.')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('stats', type=Path)
    args = ap.parse_args()
    try:
        report(parse(args.stats.read_text(encoding='utf-8-sig')))
    except (KeyError, ValueError, OSError) as exc:
        ap.exit(1, f'Cannot summarize DMA profile: {exc}\n')


if __name__ == '__main__':
    main()
