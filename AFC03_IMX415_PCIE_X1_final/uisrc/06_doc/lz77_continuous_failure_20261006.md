# 2026-10-06 continuous C2H failure

## Board evidence

The user confirmed FPGA version `0x56440021`. This is not the earlier byte
packing deadlock. A single 1080p RGB24 image must contain 6,220,800 raw bytes.
The first two packets reported 17,525,488 and 7,741,920 raw bytes despite
matching payload CRCs. The third accumulated bytes until the 256 MiB limit.
The continuous image acceptance test failed; the two packets are not valid
1080p image frames.

## Source findings and limits

- `cam_video_source.v` drops `preprocess_stream_valid` beats, including frame
  markers, when its 1024-entry `u_demo_fifo` is full. The preprocessing
  pipeline has no output ready input; backpressure cannot preserve all of
  this data.
- `rgb128_byte_stream.v` resets its accepted-beat counter on every SOF.
  If later camera SOFs arrive before a full image has survived, the fixed
  frame-size safety counter never reaches its limit. Its old error test
  (`i_sof && active` inside an `i_ready=!active` branch) is unreachable.
- `lz77_rgb_c2h_path.v` does not propagate serializer or formatter errors;
  BAR0 `0xBC` only reports encoder errors.
- The reported large frame IDs contain camera sticky debug flags in bits
  31:24; they are not a clean full-width sequence counter.
- The last implementation still has severe setup and hold violations.
  Source simulation cannot exclude additional physical timing failures.

`tb_rgb_repeated_sof.sv` intentionally reproduces SOF-reset starvation with
shortened camera frames. It is a reproduction, not a passing acceptance
test. The existing six-frame regression used a lossless, ready-compliant
source and does not cover FIFO overflow or physical timing.

## Receiver changes

`rk3576_lz77_rx.c` now reports version `lz77-rx-geometry-20261006b`. Character
device input enforces `raw_len == width * height * 3` before allocating or
accepting an image. `--expect-rgb24` enables the same checks for input files.
Generic short protocol fixtures remain supported for regular files.
Missing-footer accumulation is bounded by the two-byte literal worst case,
`16 + 2 * width * height * 3 + 20`, rather than 256 MiB (12,441,636 bytes for
1080p). These checks reject invalid data; they do not recover missing pixels.

Python geometry and existing protocol regressions passed locally. Native
C compilation and C geometry regressions require the RK3576 GCC environment:

```bash
cd /home/linaro/deploy/rk3576
bash build.sh
./rk3576_lz77_rx --version
python3 test_rgb24_geometry.py --receiver ./rk3576_lz77_rx
```

Only receiver software/tests and this reproduction were changed in this
update. No new FPGA bitstream or hardware acceptance result is claimed.

## Remaining hardware work

The compression input needs complete-frame admission/storage or sufficient
processing throughput so backpressure never truncates an admitted camera
frame. Error counts must expose drops and malformed frame boundaries, frame
IDs must be captured separately from sticky flags, and physical timing must
be resolved. Arbitrarily increasing the RK accumulator, changing the device
tree, or repeated reboots cannot restore dropped camera pixels.
