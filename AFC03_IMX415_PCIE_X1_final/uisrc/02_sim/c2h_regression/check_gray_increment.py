"""Exhaustively check direct Gray toggle versus binary increment + Gray.

For each width, exercise all pointer values, increment/no-increment, and wrap.
The RTL simulation additionally asserts actual registered pointers equal Gray(bin).
"""
from pathlib import Path

rtl=(Path(__file__).resolve().parents[2]/'01_rtl/frame_async_fifo.v').read_text()
for stem,index in (('w','wi'),('r','ri')):
    assert f'!{stem}bin[0]' in rtl
    assert f'!{stem}bin[{index}] && (&{stem}bin[{index}-1:0])' in rtl
    assert f'(&{stem}bin[ADDR_BITS-1:0])' in rtl

cases=0
for address_bits in range(1,15):
    mask=(1<<(address_bits+1))-1
    for binary in range(mask+1):
        gray=(binary>>1)^binary
        toggle=0
        if not binary&1:
            toggle|=1
        for bit in range(1,address_bits):
            if not (binary>>bit)&1 and binary&((1<<bit)-1)==(1<<bit)-1:
                toggle|=1<<bit
        if binary&((1<<address_bits)-1)==(1<<address_bits)-1:
            toggle|=1<<address_bits
        assert toggle and toggle&(toggle-1)==0
        for increment in (0,1):
            after=(binary+increment)&mask
            expected=(after>>1)^after
            assert gray^(toggle if increment else 0)==expected
            cases+=1
print(f'PASS Gray pointer: {cases} exhaustive values/enables, address widths 1..14, wrap and one-bit transition')
