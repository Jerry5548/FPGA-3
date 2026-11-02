# LZ77 解压视频＋YOLO 实测 FPS（开发版）

在原 PCIe 工程 deploy 中开发，官方参考目录未修改。无需重新烧录 FPGA。
支持 v25/v26，接收程序版本为 lz77-rx-video-perf-20261009。

将更新包内容合并到 /home/linaro/deploy，保留其他文件。停止旧播放器及官方 YOLO
程序/自启动服务，避免同时打开视频设备。不要启动官方 start_yolov5_pcie.sh。

首次更新：

```bash
cd /home/linaro/deploy/rk3576 &&
bash build.sh &&
python3 test_rgb24_geometry.py --receiver ./rk3576_lz77_rx &&
python3 test_video_output.py --receiver ./rk3576_lz77_rx &&
cd /home/linaro/deploy &&
python3 test_yolo_reference.py
```

灰度＋LZ77 解压显示＋YOLO：

```bash
cd /home/linaro/deploy
YOLO_MODEL=/home/linaro/deploy/yolo/yolov5s_relu.rknn bash play_lz77_video.sh 1 188
```

只显示视频（YOLO 显示未接入）：

```bash
cd /home/linaro/deploy
YOLO_MODEL= bash play_lz77_video.sh 1 188
```

左上角为白色等宽文字：

```text
1920x1080 DISPLAY FPS:实测值
LZ77 FPS:实测值  MODE:GRAY
YOLO FPS:实测值  NPU:实测毫秒  DET:目标数
```

- DISPLAY FPS：显示分支处理速度，不是 HDMI 刷新率。
- LZ77 FPS：相邻统计窗口的完整解码输出帧数/时间。
- YOLO FPS：完成预处理、推理和后处理的帧数/时间，包含等帧时间；不是 1000/NPU毫秒。
- NPU：单次 inference 调用耗时；DET：最近一次结果数量。
- 本阶段接入检测统计，不叠加检测框。异步检测与显示不是同一时刻的帧，不能把旧框
  直接画到新帧上；后续画框需增加帧号/时间戳对齐策略。

显示和推理从同一条解压数据 tee 分支，只有 C 接收程序打开 C2H。推理分支 queue 和
appsink 各最多保留一个待处理帧，丢旧帧，限制排队。线程并不能保证 CPU/GIL/NPU
完全互不影响，是否降低延迟仍需 RK 实测。YOLO FPS 缺少新完成结果时会超时归零；
无新视频帧时显示器上的旧画面本身仍会停留。

依赖：Python gi/GStreamer、cv2、numpy、rknnlite，以及与 RK3576 匹配的 RKNN runtime。
不自动安装驱动、修改设备树或运行 pcie_setup。缺依赖时将报错原文发回。
NPU 加载失败会停止整条测试，保存 /tmp/lz77-video.XXXXXX 中 rx.log/gst.log/after.log。

官方参考采用 640x640、NPU_CORE_0、BGR 输入、三个 255 通道 YOLOv5 输出头和 COCO
80 类。默认保留 BGR 顺序以便对照官方；可设置 YOLO_INPUT_ORDER=RGB 做受控对照，
模型导出元数据未提供，最终准确率需验证。灰度/边缘图并非该通用模型的训练输入分布。
新模型须另行核对类别、anchors、输出布局、量化及预处理，不能随意替换 .rknn。

来源：用户提供的 2G内存yolo识别/rock/yolo。
官方 Python SHA256：da1d576c2cf1151ccda11c7219f83885ee1db0c8105f1a970447eaa92b7d3f67。
模型 SHA256：418ccc10ddd9aea78658fb477a09b12d613e3e359eb5c829b4ddd00b3ef8cfe7。
仅摘取模型常量、letterbox 和后处理，未移植官方每帧 gc、定期 JPEG 保存、OpenCV
窗口、V4L2 取图和自启动。未提供模型许可信息，本包仅供用户现有板卡开发验证。

本机通过 Python 语法与 Bash 语法检查；缺少 RKNN、OpenCV、Linux C 编译器和板卡，
尚未运行新分支 NPU 推理、C 性能回归及 HDMI 画面验证。test_yolo_reference.py
需在板端运行。首次测试应同时保留 rx.log 和 gst.log，不宣称达到目标帧率。


## INT8 person/car drop-in model (2026-10-21)

The deploy file `yolo/yolov5s_relu.rknn` is the supplied person/car INT8 3-head model; the established filename/path is retained. The backend accepts both flattened NCHW heads `[1,3*(5+nc),H,W]` and explicit-anchor heads `[1,3,5+nc,H,W]`, and selects labels for COCO80 (`nc=80`) or person/car (`nc=2`). The RK3576 log confirms head 0 has shape `[1,3,7,80,80]`; the previous backend rejected this explicit-anchor layout before it could print the remaining heads. It keeps the existing 640 letterbox, BGR input, anchors, YOLOv5 raw-head decode and per-class NMS.

Before using the camera, on RK3576 run:

```bash
cd /home/linaro/deploy
python3 test_yolo_output_profile.py
python3 test_yolo_head_layout.py
python3 probe_rknn_yolo.py /home/linaro/deploy/yolo/yolov5s_relu.rknn
```

The model probe loads RKNNLite, initializes one NPU core, sends a zero 640x640 frame and prints every output shape before validating it. The expected three shapes are `[1,3,7,80,80]`, `[1,3,7,40,40]`, and `[1,3,7,20,20]`. Only head 0 is confirmed by the uploaded RKNNLite 2.3.0 log; rerun the updated probe to check all heads. Both these and flattened `[1,21,H,W]` outputs are accepted. The zero-frame probe verifies runtime compatibility and geometry, not detection accuracy. Then test a known person/car sample and inspect labels, box positions and confidence:

```bash
YOLO_MODEL=/home/linaro/deploy/yolo/yolov5s_relu.rknn YOLO_VIEW=stats bash play_raw_video.sh 0 188
```

The backend labels class 0 as `person` and class 1 as `car`. Verify that class ordering against the training/export metadata and labeled samples before relying on the labels. Mode 8/9 can be tested after baseline mode 0; this model/backend change does not require FPGA programming.

The previous COCO80 binary is preserved on the workstation at `backups/before_person_car_yolo_replace_20261021_194621/deploy/yolo/yolov5s_relu.rknn`; SHA256 `418ccc10ddd9aea78658fb477a09b12d613e3e359eb5c829b4ddd00b3ef8cfe7`. It must be transferred to the board before restoring the model there.


## YOLO display modes (2026-10-21)

The preferred `YOLO_VIEW=stats` shows live video, latest asynchronous detection boxes, labels and performance statistics. It uses an independent display queue plus a latest-frame, leaky inference queue, so display does not wait for NPU completion. `YoloWorker` defaults to 30 samples/s (`YOLO_MAX_FPS=30`). It publishes a bounded box snapshot. New detections create bounded transparent tiles and a cached `GstVideoOverlayComposition`; subsequent frames reuse the same composition.

`YOLO_VIEW=boxes` and `YOLO_VIEW=boxes-sync` are aliases for synchronous display: the worker copies the input frame, runs YOLO, draws on that same frame, then pushes it to the display. Display FPS therefore follows completed YOLO FPS. Use this mode when frame/box synchronization is preferred over display rate.

The launch scripts run `display_lz77_video.py --check` before enabling FPGA/V4L2 capture. This preflight parses the selected complete GStreamer graph, including the synchronous appsink/appsrc branch, so malformed properties or separators fail before DMA starts.

Stats-mode overlay results retain inference PTS and acquisition time. The display reuses them only while stream-time and wall-clock age are at most 250 ms. Empty detections clear previous boxes; future, out-of-order, or stale results are ignored. Configure age with `YOLO_BOX_TTL_MS=250` (50..2000). The OSD reports mode/status; `OVERLAY` lines report display samples, boxed frames, age, draw cost and expired/rejected results.

Before camera playback, test the installed Pycairo/GstVideo composition path without opening the camera, FPGA or NPU:

```bash
cd /home/linaro/deploy
python3 test_yolo_async_overlay.py
python3 test_yolo_async_worker.py
python3 test_yolo_async_overlay.py --gst
```

Run the preferred stats mode with a visible person or car in the scene:

```bash
cd /home/linaro/deploy
YOLO_MODEL=/home/linaro/deploy/yolo/yolov5s_relu.rknn \
YOLO_VIEW=stats YOLO_MAX_FPS=30 YOLO_BOX_TTL_MS=250 \
bash play_raw_video.sh 0 188
```

For display synchronized to YOLO, choose either alias. The console reports `SYNC_BOXES enabled=1`, and the OSD marks this path `SYNC`:

```bash
YOLO_MODEL=/home/linaro/deploy/yolo/yolov5s_relu.rknn YOLO_VIEW=boxes bash play_raw_video.sh 0 188
# or YOLO_VIEW=boxes-sync
```

Synchronous display FPS should follow YOLO FPS. Stats mode targets near 60 FPS independently of 20?30 FPS inference. Confirm the actual `DISPLAY`, `YOLO frames` and `OVERLAY` lines on RK3576; previous stats measurements without boxes do not prove the RGB565 overlay path reaches 60 FPS. Both modes are software-only and require no driver, receiver, model or FPGA rebuild.


The synchronous boxes/boxes-sync mode now uses two separate GStreamer pipelines: capture/appsink inference and appsrc display. Startup preflight parses both complete graphs before enabling FPGA/V4L2 capture; the graphs are not concatenated with a semicolon. 

## Cached overlay and DRM plane check (2026-10-23)

In stats mode, Cairo creates bounded transparent BGRA strips and label tiles only when detections change. Repeated video frames reuse the same immutable `GstVideoOverlayComposition`; the draw callback only selects the current composition and checks its age. `OVERLAY` reports `render_ms` (tile construction), `callback_ms`/`draw_ms` (Python selection callback), `overlay_stage_ms` (the complete overlaycomposition stage), and `blend` (`downstream-meta` or `software`). When metadata is not accepted, cached tiles may still be software-blended into every video frame; caching alone does not guarantee 60 FPS.

Collect the board's read-only kmssink/DRM plane inventory before deciding whether a distinct hardware overlay plane can be used:

```bash
cd /home/linaro/deploy
bash diag_kms_overlay.sh /home/linaro/kms-overlay-diag.log
```

To verify that candidate plane 108 can coexist with the active HDMI connector 188 CRTC, first build and run the atomic TEST_ONLY probe:

```bash
cd /home/linaro/deploy
bash test_kms_overlay_atomic.sh /dev/dri/card0 188 108 0
```

The probe creates a temporary transparent 64x64 ARGB buffer and submits only `DRM_MODE_ATOMIC_TEST_ONLY`; with a final argument of `0`, it never commits a plane or modeset. Run it while HDMI remains active. `PASS` confirms that this alpha-capable plane can coexist with a currently active plane on connector 188's CRTC for the tested geometry and z-order. `Permission denied` means the current DRM master/lease prevents the check; it is not proof that the plane is incompatible. Any other `FAIL` includes the kernel rejection reason.

After the TEST_ONLY check passes, perform the short visible scanout test:

```bash
cd /home/linaro/deploy
set -o pipefail
bash test_kms_overlay_atomic.sh /dev/dri/card0 188 108 3 \
  2>&1 | tee /home/linaro/kms-overlay-visible-test.log
```

With `3`, the tool atomically shows a small green 64x64 outline in the upper-left area, moves it between two positions as fast as synchronous atomic commits allow for three seconds, and disables plane 108 before freeing the framebuffer. It does not set a display mode or alter the active video plane. Run with the HDMI display connected and the video visible. Confirm the green outline appears over the live picture and disappears afterward; the log reports `active_updates`, monotonic `elapsed_ms`, `update_hz`, commit latency, and successful property restoration. If active commits fail with `Permission denied`, the DRM master/lease must be resolved before enabling an independent plane in the application. Do not start cached-box integration until the visible test and uncapped update rate are confirmed.

The earlier TEST_ONLY run confirmed that plane 108 can coexist with active plane 56 on HDMI CRTC 72 using ARGB8888, alpha, and `zpos=2`. The user confirmed the green outline was visible over live video, moved, and cleared. An uncapped 3-second run measured 60.16 updates/s with 16.25 ms average atomic commit. The YOLO path now uses this plane through a persistent direct-DRM helper rather than a second GStreamer KMS sink; board performance for the new helper is pending.

The user confirmed the green test box was visible over live video, moved, and disappeared. The uncapped visible run measured 60.16 atomic updates/s over 3 seconds (average synchronous commit 16.25 ms, max 16.40 ms). This verifies small-buffer scanout and update cadence on the active 1280x800 HDMI mode; it does not prove 1080p placement or RKNN-to-plane operation.

An opt-in stats path sends cached detection boxes to a persistent direct-DRM helper for plane 108. The initial appsrc/secondary-`kmssink` version measured `last_push_ms` of 320–399 ms and made display FPS fall to 24–28 when boxes appeared. The first direct-DRM version removed that long push but still submitted an atomic plane commit and a full 4 MiB buffer on each YOLO result; board testing showed display FPS dropping to 32–34 during frequent box updates. The current helper allocates one scanout buffer and enables plane 108 once, then updates only the dirty rectangle covering old/new boxes by writing the mapped scanout buffer directly; later detection updates issue no atomic commit and transfer only the patch. It uses the visible-test z-order (`zpos=2`) and premultiplied alpha. The default software-composition path is unchanged. It assumes the verified HDMI mode is 1280x800 and the video image occupies 1280x768 at y=16. The board needs `cc`, `pkg-config`, libdrm headers and metadata to build the helper during preflight. To try it:

```bash
cd /home/linaro/deploy
sha256sum -c SHA256SUMS
set -o pipefail
timeout --signal=INT --kill-after=15s 35s \
env YOLO_MODEL=/home/linaro/deploy/yolo/yolov5s_relu.rknn \
YOLO_VIEW=stats YOLO_KMS_OVERLAY=1 YOLO_MAX_FPS=30 YOLO_BOX_TTL_MS=250 \
bash play_raw_video.sh 0 188 \
2>&1 | tee /home/linaro/yolo-kms-overlay-stats.log
```

Check first for `KMS_PLANE_READY` and final `KMS_PLANE_STOP ... atomic_updates=0` in the new run's `gst.log`, then check box alignment, expiration clearing, and removal after playback stops. Compare `DISPLAY`, `YOLO frames`, and `KMS_OVERLAY` reports; `last_patch_bytes` should be far below 4 MiB for localized boxes, and `push_ms` should measure only the small patch transfer rather than a vblank wait. `play_raw_video.sh` redirects detailed output to `gst.log` inside a newly created `/tmp/raw-video.*` directory. Inspect only the path printed by the current run. If direct-DRM compilation, permission or plane setup fails, preflight should stop before enabling capture. Return to the default software path by leaving `YOLO_KMS_OVERLAY` unset or `0`.

## On-demand screenshots and recording

Enable the bounded capture tap while starting playback. Hotkeys work in this same terminal; the output folder is printed when the player starts:

```bash
cd /home/linaro/deploy
VIDEO_CAPTURE=1 YOLO_MODEL=/home/linaro/deploy/yolo/yolov5s_relu.rknn \
YOLO_VIEW=stats YOLO_KMS_OVERLAY=1 YOLO_MAX_FPS=30 \
bash play_raw_video.sh 0 188
```

While playback is running, press `P` to capture a JPEG, `R` to start an MKV recording, `S` to stop and finalize only the recording (video playback continues), and `I` to show recording status. Press `Ctrl+C` to stop playback; an active recording is finalized automatically. The command-line controller remains available if needed:

```bash
SOCKET=/tmp/raw-video.XXXXXX/capture.sock
python3 /home/linaro/deploy/video_capture_ctl.py "$SOCKET" snapshot
python3 /home/linaro/deploy/video_capture_ctl.py "$SOCKET" record-start
python3 /home/linaro/deploy/video_capture_ctl.py "$SOCKET" status
python3 /home/linaro/deploy/video_capture_ctl.py "$SOCKET" record-stop
```

Screenshots are JPEG files; recordings are MKV containers with H.264 video and no audio. By default, files are saved to `/mnt/tf/FPGA_Captures`; the launcher verifies `/mnt/tf` is mounted and the destination is writable before capture starts. Set `VIDEO_CAPTURE_DIR=/mnt/tf/another-folder` to choose a different directory on the card. Recording uses its own GStreamer pipeline fed by the bounded latest-frame capture tap, so pressing `S` ends only the recording pipeline and does not send EOS through the live display pipeline. Finalization runs in a worker thread while video playback continues. The encoder prefers Rockchip MPP or V4L2 hardware H.264 and uses a short leaky queue; if it cannot keep up, the recording may drop frames. The captured source video excludes the display OSD and separate hardware detection-box plane. Stopping playback finalizes an active recording.

Compare a new 35-second run against the previous stats baseline (roughly 20 FPS with `blend=software`) using the same mode, model and NPU cap:

```bash
cd /home/linaro/deploy
set -o pipefail
timeout --signal=INT --kill-after=15s 35s \
env YOLO_MODEL=/home/linaro/deploy/yolo/yolov5s_relu.rknn \
YOLO_VIEW=stats YOLO_MAX_FPS=30 YOLO_BOX_TTL_MS=250 \
bash play_raw_video.sh 0 188 2>&1 | tee /home/linaro/yolo-stats-cached.log
```

Compare `DISPLAY source=V4L2 fps`, `YOLO frames`, `OVERLAY callback_ms`, `overlay_stage_ms`, `render_ms`, `cache_reuses`, `blend`, and hardware camera/drop counters. A good cache result has `render_updates` near YOLO frame count and `cache_reuses` growing with display frames. If `blend=software` and `overlay_stage_ms` remains high, tile caching reduced Python/Cairo work but per-frame native blend is still the limiter; do not claim the 60 FPS target until measured.
