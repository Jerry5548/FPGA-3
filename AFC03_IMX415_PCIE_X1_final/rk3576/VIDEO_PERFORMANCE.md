# 视频播放优化与 FPS

接收器版本：lz77-rx-video-perf-20261009。支持已有 FPGA v25/v26，无需重新烧录。
将更新包内容合并到 /home/linaro/deploy，保留其他文件。

```bash
cd /home/linaro/deploy/rk3576 &&
bash build.sh &&
python3 test_rgb24_geometry.py --receiver ./rk3576_lz77_rx &&
python3 test_video_output.py --receiver ./rk3576_lz77_rx &&
cd /home/linaro/deploy &&
bash play_lz77_video.sh 1 188
```

改动：

- CRC 改用 256 项 IEEE CRC32 查表，保留完整校验。
- 距离 1 的 LZ77 匹配使用 memset；不重叠匹配使用 memcpy；
  其他重叠匹配保留逐字节解码语义。
- 显示前只保留一帧等待缓冲，满时丢弃旧的完整帧。
  不丢弃压缩流片段，不改变 FPGA 双槽调度或 DMA 读取大小。
- 取消视频模式逐帧详细日志，约每秒输出 PERF 累计统计。
- 使用 fpsdisplaysink 测量显示帧率，Python GStreamer 将其以参考图片的
  左上角白色等宽文字样式显示，500 ms 更新间隔；第二行显示 LZ77 实测输出
  帧率与模式。第三行预留 YOLO FPS，当前没有接入推理程序，明确显示
  YOLO FPS:-- (NOT CONNECTED)，不是零帧率或模拟值。
  不将管线声明的 30/1 当作实测帧率。低帧率时更新仍依赖新帧到达。

FPS 依赖 fpsdisplaysink、textoverlay 以及 Python GStreamer 绑定
（python3-gi / gir1.2-gstreamer-1.0），启动前检查；缺少依赖时会报出名称。
还需复制 deploy 根目录的 display_lz77_video.py，不能只更新 Bash 文件。
显示数字是显示链路处理帧率，不是摄像头曝光帧率，也不包含端到端延迟测量。

Ctrl+C 后，从打印的 /tmp/lz77-video.XXXXXX/rx.log 读取 PERF 行。
数值为从首次收到数据开始的累计平均，启动等待基本排除：

- fps：接收端完成解码并输出的帧率，不等于显示帧率。
- interval_fps：相邻 PERF 报告间的解码输出帧率，用于左上角 LZ77 FPS。
- read_wait_ms：每个已输出帧的 read 调用累计耗时，包含上游等待和驱动处理，
  不能仅凭这一项认定 PCIe 带宽不足。
- crc_ms / decode_ms：每帧 CRC 和解码时间。
- output_ms：写 RGB24 管道时间，包含复制与下游背压；不包含完整 HDMI 延迟。
- compressed_MBps：已解码压缩负载的平均吞吐量。

其他解析、扫描、内存操作等未单列；各项之和不等于严格的端到端延迟。
性能计时本身有少量开销；具体提速必须在 RK 上测量。文字叠加也会增加显示处理开销。
帧长度/CRC/解码及 FPGA 错误检查继续有效；检测到硬件完整性错误仍会停止。

可在停止播放后单独测试 CPU/本地文件解码（不启动 FPGA、不打开 C2H）：

```bash
cd /home/linaro/deploy/rk3576
python3 benchmark_video_decode.py --receiver ./rk3576_lz77_rx
```

此测试覆盖重复数据和全字面量数据，输出到 /dev/null，不能代表 DMA 或显示性能。

本机已执行 Python 几何检查、Python 语法及 Bash 语法检查。
本机无 Linux C 编译器和 RK/HDMI 接入，C 回归及实际性能仍需上述板端命令验证。
不要将本优化当作灰度异常帧根因修复或 FPGA 时序闭合证明。

GStreamer 官方文档：
https://gstreamer.freedesktop.org/documentation/debugutilsbad/fpsdisplaysink.html
https://gstreamer.freedesktop.org/documentation/coreelements/queue.html
