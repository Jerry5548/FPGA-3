# 官方模型目录与 27/4 FPS 对照

用户报告：未压缩 27 FPS，压缩约 4 FPS。它支持把排查重点放在压缩专用路径，
但不能区分 FPGA 压缩器、DDR、DMA 小包、CPU 解码和显示背压的各自贡献。
若两轮均为 1080p RGB24，27 FPS 对应原始像素数据量约 167.96 MB/s（推算值，
不是 PCIe 独立吞吐基准）。需要同场景、同模式、同 YOLO 状态的日志进行进一步分析。

此前命令的 YOLO_MODEL 应指向模型 .rknn，而不是官方启动脚本 .py。
用户提供的官方源码 MODEL_PATH='yolov5s_relu.rknn'。检查板端文件：

```bash
ls -lh /home/linaro/rock/yolo/yolov5s_relu.rknn
```

文件存在时，在旧播放器上也可直接改路径（先停止当前播放）：

```bash
cd /home/linaro/deploy
YOLO_MODEL=/home/linaro/rock/yolo/yolov5s_relu.rknn bash play_raw_video.sh 1 188
```

不同时启动官方 rk3576_yolov5s_pcie.py，它另开 V4L2 摄像头并显示自己的窗口。
本播放器通过 RKNNLite 加载官方模型，不调用官方启动脚本。
只有 .py 文件存在，不能证明模型、Python 依赖及 NPU runtime 均可用。

本更新包合并覆盖到 /home/linaro/deploy，无需重编译 C 接收程序或烧录 FPGA。
新命令自动查找模型：

```bash
cd /home/linaro/deploy
YOLO_MODEL=auto bash play_raw_video.sh 1 188
```

自动查找顺序：/home/linaro/rock/yolo/yolov5s_relu.rknn → 当前 deploy/yolo/同名模型 →
/home/rock/yolo/同名模型。启动时打印实际选中的完整路径。
显式指定的路径不存在时直接报错，不偷偷换模型；误填 .py/.sh 也会明确报错。
不自动启用 YOLO：不设置或清空 YOLO_MODEL 仍然只播放视频。

如果官方程序用的是虚拟环境 Python，可指定同一个解释器：
YOLO_PYTHON=/实际环境/bin/python3 YOLO_MODEL=auto bash play_raw_video.sh 1 188。
这个 Python 必须同时具备 gi/GStreamer、numpy、cv2 和 rknnlite。
本更新不安装或替换任何 NPU 驱动，若仍失败，请提供完整报错和 gst.log。

停止两轮播放后，打包现有日志及 PCIe 状态：

```bash
cd /home/linaro/deploy
python3 collect_video_perf.py
```

下载打印的 /tmp/pcie-video-report.XXXXXX.zip。工具不启动采集、不打开 C2H/V4L2，
不写寄存器；仅收集各自最新的一轮日志以及 lspci/驱动参数。
如最新目录不属于目标测试，可用 --raw /tmp/raw-video.实际后缀
--lz77 /tmp/lz77-video.实际后缀 明确选择。两轮数据时间和条件应由测试者核对。

本机模型查找回归、Python/Bash 语法检查通过。没有板端访问权限；无法仅凭当前
描述确认这次 YOLO 失败的具体报错，也不能宣称压缩帧率已改善。
