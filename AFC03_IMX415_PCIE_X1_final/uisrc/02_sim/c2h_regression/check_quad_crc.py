"""Independently verify the RTL XOR equations against zlib's IEEE CRC32."""
from pathlib import Path
import random
import re
import zlib

rtl = (Path(__file__).resolve().parents[2] / '01_rtl/lz77_rgb_c2h_path.v').read_text()
function = rtl.split('function [31:0] crc_parallel;', 1)[1].split('endfunction', 1)[0]
rng = random.Random(357628)
cases = 0
for length in (2, 4, 6, 8, 10, 12):
    branch = re.search(rf"4'd{length}: begin(.*?)\bend\b", function, re.S).group(1)
    equations = {}
    for bit, expression in re.findall(r'crc_parallel\[(\d+)\]=(.*?);', branch):
        equations[int(bit)] = [(name, int(index)) for name, index in
                               re.findall(r'([cd])\[(\d+)\]', expression)]
    assert set(equations) == set(range(32))
    for _ in range(128):
        state = rng.getrandbits(32)
        payload = rng.randbytes(length)
        data = int.from_bytes(payload, 'little')
        result = 0
        for bit, terms in equations.items():
            parity = 0
            for name, index in terms:
                parity ^= ((state if name == 'c' else data) >> index) & 1
            result |= parity << bit
        expected = zlib.crc32(payload, state ^ 0xffffffff) ^ 0xffffffff
        assert result == expected, (length, hex(result), hex(expected))
        cases += 1
print(f'PASS quad CRC XOR equations: {cases} random states/payloads, lengths 2..12, IEEE/zlib equivalence')
