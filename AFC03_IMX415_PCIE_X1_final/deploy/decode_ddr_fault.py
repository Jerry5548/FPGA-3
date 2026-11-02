#!/usr/bin/env python3
"""Decode the v26 frozen first-rejected-frame registers from a BAR snapshot."""
import re
import sys
from pathlib import Path

REASONS = (
    'new SOF before prior frame completed',
    'capture frame ID changed before frame completed',
    'LAST before expected frame length',
    'LAST missing at expected final word',
    'EOL differs from expected line boundary',
    'capture FIFO bad flag observed',
    'AXI write response or BID error',
)


def decode(text):
    regs = {int(k, 16): int(v, 16) for k, v in
            re.findall(r'BAR0\+(0x[0-9a-fA-F]+)=(0x[0-9a-fA-F]+)', text)}
    if regs.get(0x5c) not in (0x56440026, 0x56440027, 0x56440028, 0x56440029, 0x56440030, 0x56440031, 0x56440032):
        raise ValueError('First-fault decoding requires FPGA v26/v27/v28/v29/v30')
    offsets = list(range(0x100, 0x120, 4))
    if any(off not in regs for off in offsets):
        raise ValueError('Snapshot is missing v26 registers 0x100..0x11c')
    reason, fid, words, index, pos, flags, seen, expected = [regs[o] for o in offsets]
    if not reason & 0x80000000:
        return ['FIRST_FAULT: none captured (valid=0)']
    lines = [f'FIRST_FAULT: frame_id={fid} reason=0x{reason:08x}']
    lines += [f'  cause: {label}' for bit, label in enumerate(REASONS) if reason & (1 << bit)]
    lines += [f'  accepted_words={words} accepted_bytes={words * 16}',
              f'  expected_words={expected} expected_bytes={expected * 16}',
              f'  first_error_index={index} row={pos >> 16} column_word={pos & 0xffff} (zero based)',
              f'  first_event_seen_id={seen} write_state={(flags >> 12) & 7} flags=0x{flags:08x}']
    if (flags >> 12) & 7 == 4:
        lines += [f'  BRESP={(flags >> 6) & 3} BID={(flags >> 8) & 15}',
                  '  For a B response, index/position indicate the next input word after that burst;',
                  '  no individual failing DDR byte can be inferred. Input marker fields do not apply.']
    else:
        lines += [f'  observed SOF={flags & 1} EOL={(flags >> 1) & 1} LAST={(flags >> 2) & 1} BAD={(flags >> 3) & 1}',
                  f'  expected EOL={(flags >> 4) & 1} LAST={(flags >> 5) & 1}']
    lines += ['  The mask aggregates causes for the rejected frame; position/flags describe its FIRST event.',
              '  Accepted words include an early LAST beat, but exclude an interrupting next-frame SOF.',
              '  The record stays frozen until FPGA reset. Do not reset before saving these logs.']
    return lines


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: python3 decode_ddr_fault.py after.log')
    try:
        print('\n'.join(decode(Path(sys.argv[1]).read_text(encoding='utf-8-sig'))))
    except (OSError, ValueError) as exc:
        raise SystemExit(str(exc))
