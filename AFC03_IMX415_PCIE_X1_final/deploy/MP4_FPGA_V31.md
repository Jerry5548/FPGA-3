# MP4 经 FPGA 处理并保存（v31/v32 候选）

输入 MP4 在 RK3576 由 FFmpeg 解码，BGRX8888 像素通过 PCIe H2C 进入 FPGA，
复用摄像头的 image_preprocess_quad（mode 0/8/9）和 RGB24 packer，
再经原有 BLK1、完整 CRC、C2H 返回，由 FFmpeg 编码成新的 MP4。
低照度增强与去雾均由真实 RTL 完成，软件不执行增强替代算法。

当前是仿真及综合通过的候选，尚未进行板端 MP4 验证，也未完成本版最终布局布线时序验证。
不含新 bit。用户需运行原工程完成综合、布局布线、检查最终时序并生成 compress bit。
v30（0x56440030）不具备 H2V1 输入功能；v31=0x56440031 为串行 MP4 候选，v32=0x56440032 加入并行传输与较亮去雾。
v26/v28 独立回退未修改；本轮修改前 v30 项目与 deploy 已备份到原工程 backups/before_mp4_h2c_v31_*。

## 准备

停止所有摄像头播放、DMA 测试后更新 /home/linaro/deploy，避免形成 deploy/deploy。
下载用户自行生成并通过最终时序检查的 ?????? v32 compress bit，恢复 PCIe 枚举后执行：

```bash
cd /home/linaro/deploy
sha256sum -c SHA256SUMS
command -v ffmpeg ffprobe busybox fuser
# 缺少 ffmpeg/ffprobe 时：apt-get update && apt-get install -y ffmpeg
python3 test_mp4_fpga.py
cd rk3576
bash build.sh
./rk3576_lz77_rx --self-test-crc
cd /home/linaro/deploy
```

程序自动从 sysfs 查找唯一 1edb:abcd 设备和 BAR0，不依赖固定 0x21200000。
H2C/C2H 使用原有 anlogic_pci 驱动，不新增内核接口。
保持 C2H 4096 字节 read；H2C 使用页对齐缓冲，按驱动上限每次最多 255 页 write。
每帧先发送 16 字节 H2V1 头并启动 C2H，再并行发送 payload；H2C/C2H 双向 DMA、CRC/C2H
与 MP4 解码/编码由有界队列重叠。H2C TLAST 不作为帧边界。

## 指定视频

将待测文件放到 /home/linaro/videos/input.mp4；这只是示例路径，替换为自己的实际路径。
首次先验证原图往返 30 帧，再分别验证增强效果。输出路径必须不存在。

```bash
mkdir -p /home/linaro/videos /home/linaro/fpga-results
cd /home/linaro/deploy

# 原图基准：CRC 之外还逐字节比对解码输入和 FPGA 返回 RGB24
python3 process_mp4_fpga.py /home/linaro/videos/input.mp4 \
  --mode 0 --frames 30 --output /home/linaro/fpga-results/bypass30.mp4

# 暗光素材：先处理 300 帧
python3 process_mp4_fpga.py /home/linaro/videos/input.mp4 \
  --mode 8 --frames 300 --output /home/linaro/fpga-results/lowlight300.mp4

# 有雾素材：先处理 300 帧，换用自己的有雾视频路径
python3 process_mp4_fpga.py /home/linaro/videos/hazy.mp4 \
  --mode 9 --frames 300 --output /home/linaro/fpga-results/dehaze300.mp4

# 去掉 --frames 即处理整个文件
python3 process_mp4_fpga.py /home/linaro/videos/input.mp4 \
  --mode 8 --output /home/linaro/fpga-results/lowlight_full.mp4
```

处理时同时在 connector 188 预览（输出 MP4 仍保留全部通过 CRC 的帧）：

```bash
python3 process_mp4_fpga.py /home/linaro/videos/hazy.mp4 \
  --mode 9 --frames 300 --display --connector 188 \
  --output /home/linaro/fpga-results/dehaze_preview.mp4
```

显示使用现有 `display_lz77_video.py` GStreamer/KMS 管线。预览采用单帧 latest-wins
队列，显示端慢时丢弃旧预览帧，不阻塞 H2C/CRC/MP4 完整输出；因此屏幕只代表经过处理
的视频时刻，不保证每帧都显示。Ctrl+C 结束处理并停止 FPGA。当前实测离线处理约 5.6 FPS，
预览也约按该速率更新，尚非源视频 30 FPS 实时播放。
启动预览前先 Ctrl+C 停止正在显示的 GStreamer/KMS 视频；脚本会检测并拒绝与现有
`gst-launch-1.0` 播放进程同时占用显示输出。
FIFO reader 建立后才开始 H2C；不等待 GStreamer 完成首帧 preroll，避免显示端和生产端互等。

先测试命令参数而不访问硬件：

```bash
python3 process_mp4_fpga.py /home/linaro/videos/input.mp4 \
  --mode 8 --output /home/linaro/fpga-results/preview.mp4 --dry-run
```

视频统一等比例缩放并补边为 1920×1080；所有解码帧按序送入 FPGA，不用 fps 滤镜丢帧。
输出默认采用输入平均帧率，以 CFR 保存；可用 --fps 30 或 --fps 60 指定播放帧率。
VFR 原始逐帧时间戳不会保留。--frames 表示解码输入帧数，不表示处理时长。
处理速度取决于 PCIe 双向传输、FPGA 和 CPU 编解码，不承诺实时 30/60 FPS。
输出为不含音轨的 MPEG-4 Part 2/yuv420p MP4，是有损编码；严格像素校验在编码前执行。
H2C 输入 bypass 摄像头 Bayer/黑电平/AWB/原有 ISP，只经过选定项目预处理模块。

## 预期及日志

- 最后打印 PASS frames=N，输出 MP4 存在，ffprobe 确认 1920×1080 且帧数一致。
- mode 0 原始 RGB24 往返逐字节一致；mode 8 提亮暗部；mode 9 检查去雾效果、过暗和光晕。
- CRC/decode/format 错误、COMP_ERRORS、CAM_FIFO_DROPS、HOST_ERRORS、PRE_DEHAZE_ERRORS 均为 0。
- 输入输出 FPGA 计数与 N 一致；host 模式不经 DDR 实时捕获，因此不应靠 DDR_NO_SLOT 判定性能。
- 日志保存在 /tmp/mp4-fpga.XXXXXX，包括 rx.log、FFmpeg 日志、前后寄存器、命令和 result.json。
- mode 8/9 的 CRC 正确只能证明传输完整；算法像素由 RTL 仿真验证，实拍画质仍需人工比较。

任何坏帧头、帧号、长度、tkeep 会锁定输入并累加 HOST_ERRORS，需软复位后重新运行。
程序拒绝覆盖输入/已有输出，成功核对帧数后才发布最终 MP4；失败时保留诊断日志。
Ctrl+C/SIGTERM 会终止子进程并停止 FPGA，恢复进入前的 source/mode 配置，但不会自动重新播放摄像头。

处理完成后可将输出 MP4 复制到电脑播放，或板端执行：

```bash
gst-launch-1.0 playbin uri=file:///home/linaro/fpga-results/lowlight300.mp4 \
  video-sink="kmssink connector-id=188"
```

## 寄存器及 H2V1 协议

BAR0+0x80：1=摄像头（上电默认），2=主机视频。只允许在 CTRL.enable=0 时切换；切换后软复位。
Host 仅支持 cam_mode=0、compress_mode=1、preprocess_mode=0/8/9。

| 偏移 | 内容 |
|---|---|
| 0x124 | HOST_STATUS：bit0 enable，bit1 ready，bit2 busy，bit3 fault，bits7:5 状态 |
| 0x128 | 已交给 encoder 的完整帧数 |
| 0x12C | Host 输入错误计数 |
| 0x130 | 当前帧号 |

每帧先发送 16 字节 little-endian header：magic='H2V1'，uint16 width=1920、height=1080，
uint32 frame_id（从 1 连续递增），uint32 payload_bytes=8294400。
之后严格跟随 W×H×4 字节，内存像素顺序 B,G,R,X；X 被 RGB24 packer 丢弃。
帧边界由 header/固定长度决定，不使用 H2C DMA write 的 TLAST 作为帧尾。
Host 完整 RGB24 帧交给 encoder 并等待 4096 个空闲时钟后才接收下一帧头。
信用计数涵盖预处理行缓存、管线和 1024-entry FIFO，限制至 1000 个输入组，
防止非停顿预处理模块在 C2H 背压时溢出；不额外复制 mode8/9 算法资源。

## 本地验证结果（2026-10-18）

真实 RTL 的 H2V1 输入、共享预处理、FIFO、RGB24 packer、BLK1 encoder 已完成小图、
奇数高度、连续帧、间隙输入、C2H 背压和 1920×1080 mode0/8/9 仿真。
输出逐像素与独立 Python 参考一致，CRC/RGB 顺序/连续帧号通过。
坏 magic、长度、帧号和 header/payload tkeep 均拒绝，软复位恢复通过。
共享链的 camera 入口 mode0/8/9 小图回归通过。
离线脚本 6 项测试验证页对齐 DMA 写、字节流、短写拒绝、取消、RGB 顺序与原文件保护。
本机没有 FFmpeg 和板卡，因此实际编解码及驱动双向传输仍需在 RK3576 验证。

首轮新增组合路径 Gate WNS=-1.193 ns。输入 mux 后增加寄存器后，最终综合报告：

| 项目 | 结果（综合阶段） |
|---|---:|
| Setup WNS/TNS | +0.027 ns / 0 |
| ERAM20K | 246/272 |
| DSP | 74/240 |
| LUT（综合报告 #lut） | 47365 |
| 寄存器 | 41954 |

以上并非最终 Routed 时序，裕量很小；须由用户跑布局布线后检查 setup 和 hold。
SDC/PCIe IP 未修改；未消除历史 USR-6144，不使用错误频率或 false path 掩盖问题。
原 ISP ui_zhenghe.v 的 3 条 SYN-5079 异步置位/复位告警仍存在，v30 中也已存在。
最终综合目录：imx415_pcie_4k_Runs/h2c_video_v31_registered_syn_20261018。
仿真目录：imx415_pcie_4k_Runs/h2c_video_v31_validation_20261018。

## v32 pipeline/dehaze candidate (2026-10-21)

The current source candidate is FPGA version 0x56440032. It overlaps H2C input,
C2H receive/full CRC, FFmpeg output encoding and optional KMS preview with bounded
two-frame queues. H2C uses 255-page (1,044,480-byte) aligned writes, within the
existing driver desc_blen_max=1 MiB; C2H remains on the validated 4096-byte read.
Frame headers, BLK1, frame IDs and CRC are unchanged.

Mode 9 parameters: A=220, T0=40, omega=85%, saturating RGB output bias=8.
An independent synthetic reference vector measured mean luma 113.33 at v31
(T0=25, omega=95%, bias=0) and 125.68 at v32 (about +12.35/255); median rose
119 to 132. This demonstrates the direction on synthetic data only, not the
actual hazy1.mp4. Compare the same clip against hazy1_original.mp4 on the board.

Small, odd-height, continuous, gap, backpressure and 1080p mode0/8/9 RTL
simulation passed. Nine offline MP4 transport tests passed. v32 synthesis,
placement, routing and bit generation completed in the original project. Routed
results: setup WNS=+0.269 ns/TNS=0, hold WNS=+0.020 ns/TNS=0, STA coverage 99.55%;
248/272 ERAM20K, 74 DSP, 43175 registers, LUT6=36059. The v32 compress bit is
`imx415_pcie_4k_Runs/phy_1/imx415_pcie_4k_compress.bit`, SHA256
`A23D9447C6192ABC7E3B2EE48BC663BA9E409492C0CF5DB85B78843D9F46EABE`. It is not
included in deploy. RK3576 v32 MP4/H2V1 board validation, real FFmpeg execution,
and visual A/B for hazy1.mp4 remain pending. The earlier ~5.6 FPS board observation
is a pre-v32/v31 result and must not be attributed to v32. v31 remains compatible
but lacks the larger H2C writes and updated dehaze algorithm.
