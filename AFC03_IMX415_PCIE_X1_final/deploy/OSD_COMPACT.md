# 小字体 OSD 与低帧率定位

只覆盖本包 play_lz77_video.sh、display_lz77_video.py 到 /home/linaro/deploy。
保留已有 YOLO 模块、模型、C 接收程序；无需重新编译或烧录。

本次设置 auto-resize=false、Monospace 16、line-alignment=left，距离左上角
16/12 像素，白字黑边，无额外阴影。两行内容示例（数字仅为格式示例）：

```text
1920x1080 FPS:3.9 LZ77:3.9 GRAY
YOLO FPS:3.9 NPU:28.7ms DET:0
```

原先 auto-resize 默认开启会按画面缩放字体，line-alignment 默认为 center。
此次文字只在 500 ms 定时器中更新且内容未变时不重新设置，减少重复文字渲染。
不承诺解决 3.9 FPS，仍需板端检查。

启动 YOLO：

```bash
cd /home/linaro/deploy
YOLO_MODEL=/home/linaro/deploy/yolo/yolov5s_relu.rknn bash play_lz77_video.sh 1 188
```

字号可通过 OSD_FONT_SIZE=12 再缩小（允许 8～32），默认 16。

保持同一场景运行约 20 秒后 Ctrl+C，保存打印的最近五条 PERF。
再执行无 YOLO 对照，同样运行约 20 秒后 Ctrl+C：

```bash
cd /home/linaro/deploy
YOLO_MODEL= bash play_lz77_video.sh 1 188
```

将两轮终端 PERF 输出或各自 rx.log、gst.log 发回。
read_wait_ms 包括上游等待、驱动和读调用；crc_ms、decode_ms 分别为校验和解码；
output_ms 包括向显示管道复制和等待。不要将 read_wait 高直接判成 PCIe 带宽不足。
截图中 28.7 ms 是一次 NPU 调用耗时，不包括预处理、后处理和等帧，因此不能直接
推算视频应该达到 35 FPS。三项 FPS 都为 3.9 提示共享链路供帧/背压可能受限，
不能单凭截图确定瓶颈。原工程时序未闭合问题也未由本次软件改动解决。

本机 Python/Bash 语法检查通过，字体实际效果及帧率改善仍需 RK 上板确认。

属性依据：https://gstreamer.freedesktop.org/documentation/pango/GstBaseTextOverlay.html
