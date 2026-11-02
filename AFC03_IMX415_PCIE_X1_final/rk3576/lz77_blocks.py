#!/usr/bin/env python3
"""Reference BLK1 payload codec for the next LZ77 wire-format candidate.

The outer LZ77 header/footer and payload CRC stay unchanged. Header reserved
word is BLK1 (0x314b4c42), and payload blocks are either raw bytes or the
existing two-byte LZ77 token stream. Raw fallback never expands a block.
"""
import struct
import zlib
from make_test_frame import make_tokens

MAGIC = b"LZ77"
END = b"END!"
BLOCK_MAGIC = 0x314B4C42
BLOCK_HEADER = 8

def _header(kind, raw_len, stored_len):
    if kind not in (0, 1) or not 0 <= raw_len <= 0xFFFFFF:
        raise ValueError("invalid BLK1 block")
    return bytes((kind,)) + raw_len.to_bytes(3, "little") + struct.pack("<I", stored_len)

def encode_blocks(raw, block_size=65536):
    if not 1 <= block_size <= 0xFFFFFF: raise ValueError("invalid block size")
    payload = bytearray(); tokens_total = 0; blocks = []
    for off in range(0, len(raw), block_size):
        chunk = raw[off:off + block_size]
        token_bytes, token_count = make_tokens(chunk)
        if len(token_bytes) < len(chunk):
            kind, stored = 1, token_bytes; tokens_total += token_count
        else: kind, stored = 0, chunk
        payload += _header(kind, len(chunk), len(stored)) + stored
        blocks.append((kind, len(chunk), len(stored), token_count if kind else 0))
    return bytes(payload), tokens_total, blocks

def _token_count(payload):
    if len(payload) % 2: raise ValueError("odd BLK1 token payload")
    pos = count = 0
    while pos < len(payload):
        control = payload[pos]; pos += 2; count += 1
        if control != 0 and not control & 0x80: raise ValueError("reserved BLK1 token")
    return count

def _decode_tokens(payload, raw_len):
    out = bytearray(); pos = 0
    while pos < len(payload):
        if pos + 2 > len(payload): raise ValueError("truncated BLK1 token")
        control, value = payload[pos], payload[pos + 1]; pos += 2
        if control == 0: out.append(value)
        elif control & 0x80:
            length, distance = control & 0x7F, value
            if length < 3 or not distance or distance > len(out): raise ValueError("invalid BLK1 match")
            for _ in range(length): out.append(out[-distance])
        else: raise ValueError("reserved BLK1 token")
        if len(out) > raw_len: raise ValueError("BLK1 expands too far")
    if len(out) != raw_len: raise ValueError("BLK1 raw length mismatch")
    return bytes(out)

def decode_blocks(payload, raw_len, token_count):
    out = bytearray(); pos = tokens = 0; blocks = []
    while pos < len(payload):
        if len(payload) - pos < BLOCK_HEADER: raise ValueError("truncated BLK1 header")
        kind = payload[pos]; block_raw = int.from_bytes(payload[pos + 1:pos + 4], "little")
        stored_len = struct.unpack_from("<I", payload, pos + 4)[0]; pos += BLOCK_HEADER
        if kind not in (0, 1) or not block_raw or stored_len > len(payload) - pos or block_raw > raw_len-len(out): raise ValueError("invalid BLK1 block")
        stored = payload[pos:pos + stored_len]; pos += stored_len
        if kind == 0:
            if stored_len != block_raw: raise ValueError("raw BLK1 length mismatch")
            decoded = stored
        else:
            if not stored_len or stored_len % 2 or stored_len >= block_raw:
                raise ValueError("invalid BLK1 compressed block length")
            decoded = _decode_tokens(stored, block_raw); tokens += _token_count(stored)
        out += decoded; blocks.append((kind, block_raw, stored_len))
    if len(out) != raw_len or tokens != token_count: raise ValueError("BLK1 footer count mismatch")
    return bytes(out), blocks

def make_block_frame(raw, width, height, frame_id=0, block_size=65536):
    payload, tokens, _ = encode_blocks(raw, block_size)
    footer = END + struct.pack("<IIII", len(raw), len(payload), tokens, zlib.crc32(payload) & 0xFFFFFFFF)
    return MAGIC + struct.pack("<HHII", width, height, BLOCK_MAGIC, frame_id) + payload + footer

if __name__ == "__main__":
    raw = bytes(range(256)) * 1000; payload, tokens, blocks = encode_blocks(raw)
    assert decode_blocks(payload, len(raw), tokens)[0] == raw
    assert len(payload) <= len(raw) + len(blocks) * BLOCK_HEADER
    print(f"PASS BLK1 self-test raw={len(raw)} payload={len(payload)} blocks={len(blocks)}")
