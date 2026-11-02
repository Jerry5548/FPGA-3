"""Validate BLK1 CRC XOR equations (not the generator) against zlib."""
from pathlib import Path
import random
import re
import zlib

s=(Path(__file__).resolve().parents[2]/'01_rtl/lz77_rgb_c2h_path.v').read_text()
s=s.split('function [31:0] crc_bytes;',1)[1].split('endfunction',1)[0]
rng=random.Random(357629)
cases=0
for size in range(2,17,2):
    body=re.search(rf"5'd{size}:begin(.*?)\bend\b",s,re.S).group(1)
    equations={int(bit):re.findall(r'([cd])\[(\d+)\]',expression)
               for bit,expression in re.findall(r'crc_bytes\[(\d+)\]=(.*?);',body)}
    assert set(equations)==set(range(32))
    for _ in range(128):
        state=rng.getrandbits(32)
        data=rng.randbytes(size)
        word=int.from_bytes(data,'little')
        result=0
        for bit,terms in equations.items():
            parity=0
            for name,index in terms:
                parity^=((state if name=='c' else word)>>int(index))&1
            result|=parity<<bit
        expected=zlib.crc32(data,state^0xffffffff)^0xffffffff
        assert result==expected,(size,result,expected)
        cases+=1
print(f'PASS BLK1 CRC equations: {cases} states/payloads, all even lengths 2..16')
