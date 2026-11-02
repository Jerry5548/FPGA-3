# YOLO 识别框补全

对照官方 rk3576_yolov5s_pcie.py：它在后处理得到 boxes/scores/classes 后调用
draw_results（rectangle/putText），再用 imshow 显示同一张图。
我们此前只接入数量/FPS，并独立预览原始视频，没有调用框绘制。无框的直接原因是
移植尚未完成这一环节，而不是官方教程少了依赖。

默认优先使用 YOLO_VIEW=stats：显示分支独立运行并叠加最新检测框/类别/分数，同时展示性能统计。YOLO_VIEW=boxes 和 boxes-sync 用于逐帧同步模式：每帧先完成 YOLO，再画框显示，显示帧率跟随 YOLO。stats 会缓存稀疏透明框和标签 tile，仅在检测结果变化时重建。若 downstream 不接受 composition metadata，overlaycomposition 仍会逐帧软件混合；用 OVERLAY 的 blend 和 overlay_stage_ms 判断。60 FPS 仍需板端实测。

本更新只处理识别框及显示模式，不恢复用户已取消的退出顺序修改。
官方目录、模型、内核驱动、FPGA 和接收 C 程序不变。

## 更新与验证

停止播放，把包内文件合并覆盖到 /home/linaro/deploy，保留其他文件。
无需烧录或重新编译 C 接收程序。先在板端验证现有 OpenCV 的画框能力：

```bash
cd /home/linaro/deploy
python3 test_yolo_async_overlay.py --gst
```

通过后先用原图模式 0 对照官方彩色模型：

```bash
YOLO_MODEL=/home/linaro/rock/yolo/yolov5s_relu.rknn bash play_raw_video.sh 0 188
```

灰度模式保持原命令，停止上一次播放后执行：

```bash
YOLO_MODEL=/home/linaro/rock/yolo/yolov5s_relu.rknn bash play_raw_video.sh 1 188
```

没有 DET 时不生成假框；FPS 大于零仅表示推理完成，不表示检测到目标。
目前官方模型是 COCO 80 类，不是参考裂缝演示中的定制裂缝模型。
可先把人、椅子、瓶子等对应类别目标放到镜头前；灰度/边缘模式准确率仍需单独验证。
置信度与 NMS 阈值维持官方 0.45，未通过降低阈值掩盖问题。

默认 stats 模式：独立视频显示＋YOLO 异步检测框＋统计：

```bash
YOLO_VIEW=stats YOLO_MODEL=/home/linaro/rock/yolo/yolov5s_relu.rknn bash play_raw_video.sh 1 188
```

LZ77 播放器使用同一个 stats 异步叠框模式；只有设置 YOLO_MODEL 才启用推理。

## OpenCV 与颜色

官方使用 imshow 需要 GUI 后端；我们不使用 imshow，OpenCV 只处理 resize、
copyMakeBorder、cvtColor、rectangle、getTextSize、putText。headless 版本通常也有
这些功能，不应为修复无框而盲目删除 cv2 或重装所有依赖。
原图保持 RGB，按官方样例在缩放后转 BGR 给模型；画框不交换整帧通道。
模型输入顺序继续通过 YOLO_INPUT_ORDER 选择，模型准确率仍须上板对照。

## 验证范围

本机验证了缓存 composition 重用、过期/空结果清除和有界 overlay tile；实际 GStreamer blend 路径、NPU/HDMI FPS 仍需板端验证。
若 DET>0 仍无框，保留本轮 gst.log；若 DET=0，先核对模式 0、模型类别和原图识别。


## 2026-10-21 asynchronous boxes update

`YOLO_VIEW=stats` is preferred for higher display rate; it pre-renders bounded transparent strips/labels only when detection results change and reuses the cached composition. This avoids repeated Python/Cairo drawing, but if downstream rejects composition metadata GStreamer still software-blends cached tiles each frame. Compare `blend` and `overlay_stage_ms`; hardware-plane use is not currently configured. `boxes` and `boxes-sync` display the inferred frame synchronously.

Local regression covers queue topology, inference pacing/stop, result ownership and ordering, box clipping, empty result, expiry, timestamp guards, cached composition reuse, bounded tiles and fake-RKNN worker publication. The board-only `test_yolo_async_overlay.py --gst` checks GstVideo composition APIs, actual 1080p overlay pixels and that display does not wait for a delayed fake 25 FPS inference branch. Real NPU, camera, KMS frame rate and class/box accuracy still require board verification.

## DRM plane capability

Run `bash diag_kms_overlay.sh /home/linaro/kms-overlay-diag.log` for a read-only kmssink/DRM plane inventory. Confirm a separate plane supports BGRA, alpha, z-order, placement/scaling and connector 188 before considering hardware composition. The current player does not select or program a second plane. If the log reports `blend=software`, the cached composition is still software-blended for each frame. The diagnostic only inventories capability; it does not prove the current sink selected a separate plane.
