# Current deploy: v32 MP4/H2V1 overlap and brighter mode9 candidate; v30/v31 retained

The deploy now also includes a loopback-only Windows web control console. See
WEB_CONTROL_CONSOLE.md; it can start/stop playback and control TF-card captures
over SSH, with an editable board IP. This first version has no network video preview.

Read MP4_FPGA_V31.md. The v32 compress bit (0x56440032) has been generated and routed; SHA256 A23D9447C6192ABC7E3B2EE48BC663BA9E409492C0CF5DB85B78843D9F46EABE. Routed setup WNS=+0.269 ns, hold WNS=+0.020 ns, TNS=0; STA coverage=99.55%; resources: 248/272 ERAM20K, 74 DSP, 43175 registers, LUT6=36059. The bit is stored in the original Runs/phy_1 directory and is not included in deploy. Board programming and RK3576 v32 MP4 validation remain pending. v30 has no H2V1, and v31 H2C is serial. MP4 decoding/encoding is software; FPGA performs modes 0/8/9 with full BLK1 CRC and silent 1080p output. H2C batches up to 255 pages (1,044,480 bytes), within the driver's 1 MiB cap; C2H retains validated 4 KiB reads. Decode/H2C and C2H/CRC/encode/display overlap in bounded two-frame queues. Mode9 uses A=220, T0=40, omega=85%, saturating RGB bias=8. Synthetic vectors show mean luma +12.35/255, but visual A/B against hazy1.mp4 remains unverified on board. The ~5.6 FPS observation is a pre-v32/v31 processing measurement, not a v32 board result or 30 FPS claim. Camera scripts retain v30/v31 compatibility. The file `yolo/yolov5s_relu.rknn` now contains the supplied person/car INT8 three-head model, so the existing model path and launch command stay unchanged. Its SHA256 is bba6346f33c41d629a063167c3cb7693abaa86c6bc1d7b8108b1ef2976f9c0fe. The current backend selects COCO80 (nc=80) or person/car (nc=2) from raw output shapes. It accepts flattened heads [1,3*(5+nc),H,W] and explicit-anchor heads [1,3,5+nc,H,W]. The board probe confirms head 0 is [1,3,7,80,80], which the previous shape validator rejected before reporting the remaining heads; the expected other grids are 40x40 and 20x20; support and numerical layout-equivalence tests are now included in test_yolo_output_profile.py and test_yolo_head_layout.py. Run both tests and probe_rknn_yolo.py on RK3576 before playback. Shape validation does not prove detection accuracy, colors, anchors or box placement; verify on labeled images. Preferred YOLO_VIEW=stats gives independent display with cached transparent overlay tiles and counters. Tiles rebuild only when detections change. The GStreamer overlay element may still software-blend every frame; compare OVERLAY blend and overlay_stage_ms. diag_kms_overlay.sh collects read-only DRM plane capabilities. The player does not currently configure a second DRM plane. YOLO_VIEW=boxes and boxes-sync are aliases for same-frame synchronous display paced by YOLO. Board FPS must be measured after overlay caching. Original COCO80 model is backed up locally at `backups/before_person_car_yolo_replace_20261021_194621/deploy/yolo/yolov5s_relu.rknn` (SHA256 418ccc10ddd9aea78658fb477a09b12d613e3e359eb5c829b4ddd00b3ef8cfe7).


---

# Historical v30 color lowlight/dehaze + v29 BLK1

2026-10-18: read MODE8_9_V30.md first. Mode 8 is color gamma enhancement;
mode 9 is color dehaze. Modes 0..6 remain available; mode 7 remains reserved.
New modes require FPGA 0x56440030; scripts reject them on older bitstreams.
Routed setup WNS=+0.102 ns, hold WNS=+0.020 ns, both TNS=0.
235/272 ERAM20K, 74 DSP, 42337 registers, 34889 LUT6. STA coverage=99.54%.
The v30 compress bit was generated in the original project's
imx415_pcie_4k_Runs/mode8_9_v30_phy_20261018/ directory. No board programming
was performed. Board integrity, image quality and FPS for mode8/9 are pending.
Historical PCIe USR-6144 (requested 62.5 MHz vs actual 125 MHz) remains.
Keep 1080p, 4 KiB user DMA reads, 16 KiB EOP, BLK1 and full CRC.
Existing matched kernel drivers and receiver protocol do not require changes.
Use the board commands in MODE8_9_V30.md. Earlier sections below are history.

---

# Current deploy: v28 FPGA + RK3576 receiver pipeline software candidate

2026-10-17 BLK1 update: read LZ77_BLOCKS_20261017.md first.
Active v29 RTL explicitly selects 32 KiB blocks (two 2048x128-bit RAMs).
Encoder/formatter pipelines, direct Gray updates and one Sobel sum register
improve full-project Gate Setup WNS from -4.012 ns to +0.100 ns and TNS from
-1890.067 ns to 0.000 ns. Resources: 219/272 ERAM20K (80.51%), 40017 registers,
43837 LUTs. Margin is small; this is synthesized timing, not routed setup/hold
signoff (STA coverage 99.49%). 34 BLK1 frames, 12000-batch encoder equivalence,
async FIFO/DDR and 1080p edge regressions passed. No implementation or bitgen.
Keep v28 on board while final implementation is pending. Rerun Synthesis and
Implementation in the original TD project; this independent Gate validation
does not refresh the GUI's old syn_1 result. The latest C length-based parser
still needs its board regression. Existing ZIP name and rollback trees retained.

2026-10-16 software update: read RX_PIPELINE_20261016.md first.
Keep the v28 bit already tested on the board; the receiver pipeline update requires
no FPGA build or programming. Receiver C/ARM/pthread tests have now passed on the
user's board. See DMA_PROFILE_20261016.md for the subsequent optional kernel
profiling candidate; that candidate requires a driver build/reload and remains
pending native kernel compilation and board validation. Profiling defaults OFF.
The earlier v28 FPGA development instructions below are historical context;
they do not require repeating FPGA builds for this software update.

Observed updated playback: original LZ77 about 12.24 FPS, grayscale LZ77 26.80 FPS;
grayscale LZ77+YOLO display about 22.73 FPS, steady detection samples 22.71 FPS.
These measurements precede the optional kernel profiling candidate.

---

Candidate FPGA identity: 0x56440028. This replaces the v27 serial compression path
with four-byte input, batch tokens/CRC/output, and four DDR frame slots.
The original project source now contains a Gate-synthesized v29 BLK1 candidate
(source version 0x56440029). The board must continue using the tested v28 bit until
TD synthesis, implementation, timing and bitgen for v29 are completed.
The original project and the original full ZIP filename are retained.
The v26 rollback under test2 was not modified.

Read LZ77_THROUGHPUT_OPTIMIZATION_20261014.md first: its v28 section contains
the design, regressions, limitations and exact board steps in Chinese.
The original project's uisrc/06_doc/lz77_quad_v28_20261016.md is the source report.

No synthesis, placement, routing, bitgen or board programming was run for v28.
Generate a NEW compress bit in the ORIGINAL TD project and review new timing
and resources; v27 timing results do not cover this RTL.
Copy updated deploy scripts and SHA256SUMS to the board before testing v28.
Do not replace kernel drivers. Keep user read_size=4096; larger requests remain
unvalidated after the earlier missing-byte captures. Existing protocol is unchanged.
If the receiver binary is still the 64 KiB version, rebuild it under rk3576.

After programming the candidate:

```bash
cd /home/linaro/deploy
sha256sum -c SHA256SUMS
busybox devmem 0x2120005c 32
# Must read 0x56440028
bash test_lz77_frames.sh 0x21200000 3 0
# Only after the three-frame integrity test passes:
YOLO_MODEL= bash play_lz77_video.sh 0 188
```

Run for about 30 seconds, Ctrl+C, then send rx.log, gst.log, hardware.log,
after.log, first_fault.log and dmesg.log. Target is improvement over the v27
4.7 FPS baseline with zero received-frame integrity errors. No 20-30 FPS or
zero-DDR_NO_SLOT claim is made yet. A 60 FPS source and slower consumer still
overfill finite slots. YOLO native heap abort and historical mode-3 runtime
preprocessing mismatch are not fixed by this change.

The directory/ZIP name deploy_full_v27_20261014 is a retained filename only:
its updated contents support v28; it is not an immutable v27 rollback package.
