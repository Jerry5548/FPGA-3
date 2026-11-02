# PCIe DDR complete-frame path (v23)

## Implemented architecture

Camera MIPI/ISP/preprocessing runs without compression backpressure. The
existing RGB24 packer is always drained. Input is discarded until the
first valid SOF after enable, and the camera output FIFO is reset while
disabled, preventing buffered mid-frame startup data.

`pcie_ddr_camera.v` reuses the PH1A90SEG324 x16 DDR3 IP from the MIPI project.
It shares the existing T13 100 MHz reference, not a second top-level pin.
The controller uses its native `dfi_clk` for AXI. New capture and replay
FIFOs cross that clock to/from PCIe `user_clk` using Gray pointers,
synchronous ERAM reads and synchronized reset release.

`ddr_frame_store_axi.v` manages two slots at byte addresses 0 and 0x00800000.
Each contains one 1920x1080 RGB24 image (6,220,800 bytes). Slot ownership is
FREE -> WRITING -> READY -> READING -> FREE. A slot is published only after
all expected pixels, EOL/LAST markers, consistent capture ID, and successful
AXI B responses. Short/mixed/overflowed frames are not published. A slot
being read cannot be allocated by the writer. It is freed after all read
data has been copied into the replay FIFO, not while DDR reads remain.

If no slot is free, the incoming camera frame is skipped whole and counted.
This allows a slower accepted compression frame rate without unbounded
memory growth or overwriting images. It does not compress every 60 fps
exposure. AXI RRESP/RID/RLAST errors halt playback without emitting a valid
image LAST; software must soft-reset the path to recover.

LZ77 now consumes only DDR replay. Capture IDs travel with the byte stream
and survive the one-beat lookahead. Existing RGB24 LZ77 header/footer and
RK CRC decoder formats are unchanged. The original uncompressed C2H/HDMI
route remains selected when compression is disabled.

The soft-reset register resets the DDR controller and AXI requester together.
DDR reset is stretched for 256 reference-clock cycles; application reset
asserts asynchronously and releases synchronously in both FIFO domains.
DDR calibration must finish after each soft reset before enabling capture.

## Registers

Existing BAR0 controls remain: 0x60 enable/reset, 0x90 resolution,
0xA4 preprocessing, 0xA8 compression. Version at 0x5C is `0x56440023`.

| Offset | Meaning |
| --- | --- |
| 0xCC | DDR status: bit0 calibration done, bit1 PLL lock, bit2 PHY reset released, bit3 controller reset released, bits23:16 calibration step, bits31:24 calibration error |
| 0xD0 | Complete frames published to DDR READY slots |
| 0xD4 | Incoming camera frames skipped because no slot is free (expected under slow compression) |
| 0xD8 | Invalid/short/marker/overflow/write-failed frames rejected |
| 0xDC | AXI write-response errors |
| 0xE0 | AXI read/protocol errors (playback halts) |
| 0xE4 | Capture CDC FIFO beats lost (must be zero for integrity acceptance) |
| 0xE8 | Frames fully copied from DDR into replay FIFO; may lead host decode count |
| 0xEC | DDR store state; bit15 read-fault latch, bits11:8 slot states, bits4:3 read state, bits2:0 write state |

DDR counters use a handshaken status mailbox for coherent user-clock reads.
Calibration step/error are diagnostic fields sampled after becoming stable;
control uses synchronized calibration/PLL/PHY flags.

## Verification completed

ModelSim tests with AXI RAM model, unrelated clocks, variable AW/W/R/B
latency, and sink stalls passed:

- 100 complete 16x16 frames: exact raw-byte comparison.
- Busy two-slot protection and whole-frame skipping.
- Rejection of short, missing-LAST, wrong-EOL and capture FIFO loss.
- Failed write responses never publish a frame.
- Read errors halt without valid image LAST; coherent reset recovers.
- DDR -> LZ77 -> Python reference decode: 10 exact images, matching CRC,
  RGB24 geometry and capture IDs; an injected short frame is absent.
- Previous C2H/preprocessing/FIFO regression suite passed again.

Run `uisrc/02_sim/c2h_regression/run_ddr_frames.ps1` and
`run_frames.ps1` to reproduce. The RAM model verifies requester behavior,
not electrical DDR PHY operation or board timing.

Full TD synthesis passed: approximately 47.48% slices, 193/272 ERAMs,
64/240 DSPs, one DDR bank/calibration block and five PLLs. TD placement,
routing and bitgen completed on 2026-10-06. Final setup WNS is -23.238 ns
(TNS -14053.692 ns); hold WNS is -1.175 ns (TNS -9.063 ns).
Timing is NOT closed. These bitstreams are DDR functional debug artifacts,
not a stable or timing-signed-off release. Hardware/DDR PHY operation has
not been verified on the board; passing behavioral tests does not establish
physical reliability.

The independent release is
`imx415_pcie_4k_Runs/debug_release_ddr_v23_20261006/`. Use
`imx415_pcie_4k_ddr_v23.bit` from that directory. The `_compress.bit`
alternative is TD's compressed programming file for the SAME design; it
does not select camera compression. BAR0+0xA8 controls LZ77 at runtime.
The release includes source/artifact SHA256 hashes, timing reports and
build logs. Older `best_result` artifacts are not evidence for this path.

## Board procedure for the v23 debug bitstream

Copy updated `deploy/test_lz77_frames.sh` and `deploy/diag_lz77.sh` to RK.
Keep receiver `lz77-rx-geometry-20261006b` or newer. Stop GStreamer/C2H
readers, download the v23 bit and run normal PCIe driver setup. Then:

```bash
cd /home/linaro/deploy
bash pcie_setup.sh
bash test_lz77_frames.sh 0x21200000 3 1
```

The script requires v23, waits up to 10 seconds for DDR calibration, captures
receiver/register/kernel logs, and accepts whole-frame skips (D4) while
rejecting compression errors, processed FIFO loss, invalid DDR frames,
DDR bus errors and capture FIFO loss. If DDR calibration does not finish,
investigate PHY clock/reset/ROM/pin operation before attempting reception.

Only after three-frame reception passes, repeat without power cycling,
test modes 0/1/2/3/4, then run 100 frames and stability measurements. Every
accepted decoded 1080p image must be 6,220,800 bytes with zero CRC/decode/
format errors. Record skipped capture IDs/D4 separately from corruption.

No device-tree or Linux kernel-driver modification is part of this change.
