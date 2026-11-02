# 未压缩视频、FPS 与模式切换

本更新沿用原工程及 v25/v26 位流，无需重新烧录或编译 C 接收程序。
将包内文件合并覆盖到 /home/linaro/deploy，保留已有文件和模型。

未压缩路径：FPGA 预处理→PCIe→V4L2 /dev/video73→显示/可选 YOLO。
关闭 LZ77 不会关闭 PCIe。该路径不运行 rk3576_lz77_rx，不使用 LZ77 帧头和 CRC 验收。
使用相同的小字体左上角两行状态，未压缩时第一行显示 COMP:OFF，不伪造 LZ77 FPS。

模式编号：0 原图；1 灰度；2 高斯；3 直方图均衡；4 高斯＋均衡；
5 灰度＋中值；6 灰度＋Sobel；7 预留。当前显示脚本固定 1080p RGB24。

一个终端依次操作。先 Ctrl+C 停止当前播放器，等出现 shell 提示符再启动：

```bash
cd /home/linaro/deploy
# 灰度，不压缩，仅显示 FPS
YOLO_MODEL= bash play_raw_video.sh 1 188
```

停止后换模式，修改第一个参数即可：

```bash
bash play_raw_video.sh 0 188
bash play_raw_video.sh 5 188
bash play_raw_video.sh 6 188
```

以上每条都会持续播放，不要一起粘贴执行。每次按 Ctrl+C 停止后再执行下一条。
脚本调用 mode_control.sh BAR0 MODE 0 关闭压缩并设置预处理。
V4L2 驱动在 STREAMON 时负责复位和启动，在 STREAMOFF 时停止。
不手动再启动第二个 C2H 接收程序，也不在运行中切换压缩开关。

开启 YOLO（已复制此前提供的模型）：

```bash
YOLO_MODEL=/home/linaro/deploy/yolo/yolov5s_relu.rknn bash play_raw_video.sh 1 188
```

它从同一条未压缩视频分支推理，不再另开 /dev/video73。模型沿用官方 COCO 模型，
灰度/中值/Sobel 上的检测准确率尚未验收。仅开启 YOLO 才显示真实 YOLO FPS。
模型和 C 接收程序未包含在本次小更新包中，保留此前安装。

回到 LZ77 压缩显示，先 Ctrl+C，再用既有命令：

```bash
YOLO_MODEL= bash play_lz77_video.sh 1 188
```

play_lz77_video.sh 会重新设置 compress=1，不要仅手动改寄存器后继续使用旧播放器。
手动控制脚本参数仍是 bash mode_control.sh BAR0 PREPROCESS COMPRESS，
末尾 0=关闭 LZ77，1=开启 LZ77。单独运行它不会显示视频或启动接收。

可选环境变量：VIDEO_DEVICE=/dev/video73（默认）、V4L2_IO_MODE=mmap（默认，
也可选 dmabuf）、OSD_FONT_SIZE=16（默认）。dmabuf 并不保证整条链路无复制或更快，
使用 YOLO/textoverlay 会访问像素。默认先沿用官方 YOLO 示例支持的 mmap。

停止后日志在 /tmp/raw-video.XXXXXX，含 gst.log、before.log、after.log、dmesg.log。
gst.log 每约半秒记录 DISPLAY source=V4L2 fps=...，启用 YOLO 时另记录推理统计。
未压缩对照能帮助判断 LZ77 链路开销，但它使用不同的驱动取图/分包方式，不能单凭
帧率差异认定是压缩算法或 PCIe 物理带宽的单一瓶颈。

已完成本机 Python/Bash 语法检查；没有板端执行权限，V4L2 显示、启停和 YOLO
联合运行需上板验证。缺设备或依赖时脚本直接报错，不更改设备树或加载新内核模块。

GStreamer V4L2 来源说明：
https://gstreamer.freedesktop.org/documentation/video4linux2/v4l2src.html
