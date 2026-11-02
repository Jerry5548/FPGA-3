# RK3576 C2H receiver

2026-10-16 software candidate: see `../RX_PIPELINE_20261016.md` in deploy.
Copy `rx_crc.h`, `rx_read_pipeline.h` and `rx_output_pipeline.h` with the C source.
The new build needs POSIX threads and C11; use `bash build.sh` on Linux/RK3576.
`--build-info` prints `rx-pipeline-20261016`; `--self-test-crc` tests available CRC backends.
Character devices default to a bounded three-stage pipeline; regular files default to serial.
Use `--pipeline` or `--serial` for explicit comparisons. C/ARM/pthread regression checks have passed on the user's RK3576 board.

`rk3576_lz77_rx.c` is a userspace receiver for the Anlogic SGDMA C2H character
device. It accepts arbitrary `read()` fragment sizes, searches for `LZ77`,
waits for the `END!` footer, validates payload length and reflected CRC32, and
decodes the phase-1 FPGA token stream.

The 2026-10-06 receiver (`--version`: `lz77-rx-geometry-20261006b`) also
requires `raw_len == width * height * 3` for character-device input. A
payload CRC alone is not image acceptance. Missing-footers are bounded by
the worst-case two-byte literal payload size. Regular protocol files keep
their generic length semantics; use `--expect-rgb24` for image-file tests.

Run `python3 test_rgb24_geometry.py --receiver ./rk3576_lz77_rx` after
building on RK3576. The continuous-frame failure and remaining FPGA work
are documented in `../uisrc/06_doc/lz77_continuous_failure_20261006.md`.

## Build on RK3576

```sh
bash build.sh
# For a Linux cross compiler: CC=aarch64-linux-gnu-gcc bash build.sh
```

If the RK3576 rootfs has a native compiler, use `gcc` instead. The program has
no external dependencies beyond libc/POSIX threads.

## File/vector test on a host

```sh
python3 make_test_frame.py
python3 test_lz77_frame.py
mkdir -p test_vectors/decoded
./rk3576_lz77_rx -d test_vectors/sample_frame.lz77 -o test_vectors/decoded/frame -n 1 -v
```

The C program writes decoded output as `frame_000007.bin` when `-o` is given.
The final line reports frames, compression ratio, CRC errors, decode errors,
throughput and elapsed time.

## Real FPGA C2H test

After the PCIe bitstream and driver are loaded:

```sh
ls -l /dev/sgdma0_c2h_0
./rk3576_lz77_rx -d /dev/sgdma0_c2h_0 -o /userdata/lz77/frame -n 100 -v
```

The current driver uses the normal blocking C2H read path. Keep the FPGA
compression mode enabled and use 1920x1080; the RTL automatically bypasses
compression for other dimensions. The footer CRC is the CRC32 of the compressed
Token payload, matching `lz77_frame_formatter.v`.

## Protocol

Header: `LZ77`, width/height (u16 LE), reserved raw length (u32 LE), frame id
(u32 LE). Payload: two bytes per token, literal `00,value`, match
`80|length,distance`. Footer: `END!`, raw bytes, compressed bytes, token count,
reflected CRC32 (all u32 LE). `END!` is safely detectable at token boundaries
because controls 0x01..0x7f are reserved and literals start with 0x00.
