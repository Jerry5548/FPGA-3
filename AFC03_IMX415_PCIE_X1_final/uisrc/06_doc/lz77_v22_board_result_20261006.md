# v22 real-camera diagnostic result

User-provided board output confirmed version `0x56440022` and receiver
`lz77-rx-geometry-20261006b`, preprocessing mode 4, compression enabled.

- First packet: 1920x1080, raw 6,220,800 bytes, payload 5,218,214 bytes,
  matching payload CRC. Packet geometry/decode passed, but the session
  counters below do not prove pixel identity against a complete camera frame.
- Second packet: footer raw length 2,202,608 instead of 6,220,800 bytes.
  The receiver correctly rejected it as a format error. The old mixed-frame
  accumulator overflow did not recur in this run.
- Receiver read 7,477,768 bytes. No DMA polling timeout is shown in this
  diagnostic output. PCIe/C2H transport is working for these fragments;
  this does not establish DMA or link reliability over time.
- `BAR0+0xC8=0x000559BC` means 350,652 processed FIFO input beats were
  counted as lost while FIFO full and camera enabled. This is direct
  evidence of camera-pipeline data loss.
- `BAR0+0xBC=0x00087CC2` means 556,226 aggregated compression-path error
  events. These include orphan input beats and frame-boundary faults,
  not 556,226 bad image frames.
- FPGA `0xB8=2` counts completed formatter packets, including the rejected
  short packet. It is not the number of accepted RGB24 images.

The serial RGB encoder consumes at most one raw byte per user-clock cycle,
and stalls reduce that rate further. At the top-level nominal 125 MHz this
ceiling is 125 MB/s; nominal 1080p60 RGB24 source data is 373.248 MB/s.
The camera FIFO (1024 entries, four pixels/entry plus one output slot) is
burst buffering, not a complete 6.22 MB frame store. The rate mismatch is
a structural constraint. Severe unclosed timing also remains a possible
additional source of data corruption; this result does not rule out timing
or hardware problems and does not identify every upstream loss location.

## Next comparison without rebuilding FPGA

The updated `deploy/test_lz77_frames.sh` supports a third argument for
preprocessing mode. Copy that script into the board's deploy directory.
Run one at a time, preserving each separate `/tmp/lz77-diag.*` directory:

```bash
cd /home/linaro/deploy
bash test_lz77_frames.sh 0x21200000 3 0
bash test_lz77_frames.sh 0x21200000 3 1
```

Mode 0 bypasses the project preprocessing output; mode 1 selects grayscale.
All parallel algorithm branches still exist and clock, so a bypass-mode
comparison does not prove timing closure or remove those branches from the
FPGA. If loss persists in modes 0/1, it cannot be attributed only to selecting
equalization. If they pass and mode 4 fails, investigate preprocessing
drain/blanking/handshake and selected-path timing next.

This diagnostic determines the next hardware change; it does not improve
compression throughput. Robust continuous capture requires sufficient
throughput and burst buffering, or complete-frame storage/admission with
a controlled source rate. Simply increasing the RK timeout or accumulator,
or removing geometry validation, cannot repair dropped pixels. No device
tree change is indicated by this evidence.
