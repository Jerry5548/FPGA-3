# 2026-10-14 候选上板验证

目标：验证 Gen2 x1 稳定性及 27 MHz MCLK 修正后的 1080p 源帧率。
本次候选并未消除 USR-6144，不能把上板功能通过当作完整时钟签核。
脚本未连接板卡执行；Windows 环境无可用 Bash，板端先运行 bash -n 检查。

## 下载前后

使用原工程 phy_1 中 2026-10-14 17:01 生成的候选，而不是 test2 回退文件：

`imx415_pcie_4k_Runs/phy_1/imx415_pcie_4k.bit`

SHA-256：`a9a4188e04a4762f48552ec4b74b0697ef5326c7ffbb7b347ea3574f88359b90`

FPGA 候选与旧 v26 均返回 0x56440026，所以版本寄存器无法区分两者。
通过已有 TD 下载方式配置 FPGA，并确保新 FPGA 已就绪后 RK3576 再枚举 PCIe。
仅 JTAG 易失性配置时，不要在配置后给 FPGA 断电，否则可能丢失候选配置。
保持既有可用驱动；脚本不重载驱动、不修改设备树、不写 PCIe 配置空间。

将原工程 deploy 的脚本及 rk3576 源码合并到 /home/linaro/deploy；保留
板端已有驱动和配置。新加入文件为 validate_board_clock.sh 和本说明。
不要同时启动官方 YOLO 摄像头程序或第二个 V4L2/C2H 读取进程。

## 命令（root，RK3576）

```bash
cd /home/linaro/deploy
bash -n validate_board_clock.sh
bash validate_board_clock.sh preflight
```

枚举和驱动正常后分阶段执行。每一步确认结果，再执行下一步：

```bash
# 1080p 原图；不压缩、不推理、不显示，持续 60 秒。
bash validate_board_clock.sh raw

# 同样条件开启显示，持续 60 秒；默认 connector=188。
bash validate_board_clock.sh display
```

更新接收源码时，在运行压缩测试前编译并自测：

```bash
cd /home/linaro/deploy/rk3576
bash build.sh &&
./rk3576_lz77_rx --version &&
python3 test_rgb24_geometry.py --receiver ./rk3576_lz77_rx &&
python3 test_video_output.py --receiver ./rk3576_lz77_rx
cd /home/linaro/deploy

# 模式 0、1、5、6 各 3 帧，任一失败就停止。
bash validate_board_clock.sh lz77

# 灰度+LZ77，不重启系统，连续启动/停止 10 次，每次 3 帧。
bash validate_board_clock.sh repeat
```

上述检查通过后，再记录八种显示/推理/压缩组合，每种 60 秒：

```bash
cd /home/linaro/deploy
YOLO_MODEL=/home/linaro/rock/yolo/yolov5s_relu.rknn \
    bash validate_board_clock.sh benchmark
```

benchmark 脚本自身完成不代表全部测试通过，须检查八个 case 的退出码和数据。
定时结束的 124/130 不代表完整性或帧率达标。lz77/repeat 中的帧数测试则应 exit=0。

## 验收与解释

| 项目 | 本轮目标 / 解释 |
|---|---|
| PCIe | FPGA 1edb:abcd，传输期间 LnkSta 为 5 GT/s、Width x1；无降速/掉链 |
| 源输出 | raw 稳定后 HARDWARE camera_per_s 目标约 60（初筛 59–61） |
| 真实采集 | raw 的 OUTPUT source=V4L2 fps 目标约 60；持续观测 60 秒 |
| 显示 | DISPLAY source=V4L2 fps 目标约 60，须显示器/输出模式支持 60 Hz |
| 格式 | V4L2 1920×1080 RGB24；每帧像素 6220800 字节 |
| 压缩完整性 | 每组 frames=3；receiver_exit=test_exit=0；CRC/decode/format 错误均为 0 |
| FPGA 完整性 | COMP_ERRORS/CAM_FIFO_DROPS/DDR_INVALID/DDR_WRITE_ERR/DDR_READ_ERR/DDR_CAP_DROPS 均为 0；选中中值/Sobel 的错误为 0 |
| 正常跳帧 | DDR_STARTUP_SKIPS 应为 1；DDR_NO_SLOT 可非零，表示整帧跳过，不等于帧内损坏，但必须计入吞吐损失 |
| 二次启动 | repeat 十次均通过，不能再次出现第一轮成功、第二轮 timeout |
| 驱动 | 采集期间无新增 AER、DMA timeout、desc_wb 不完成、IOMMU fault、掉链或图像损坏 |
| LZ77+YOLO 最终目标 | 1080p、有效新画面 FPS 与检测完成 FPS 均 20–30；本次未加宽编码器，不保证达标 |

HARDWARE camera_per_s 是 pack4 被接受的帧末事件（0x88 低 24 位），不是传感器
XVS 或 MCLK 频率。若它已接近 60 而 OUTPUT 仍约 27，优先查后级 DMA/V4L2；
若两者均约 26.7，先确认是否真正下载新位流，再测 MCLK 和前级。
MCLK=27 MHz 需示波器/频率计或独立、已核验的硬件测频；当前 Bash 寄存器读数
不能代替实测。不要用 v4l2 --set-parm=60 当作实际帧率证据。

程序内 NPU/decode 时间不是摄像头到屏幕的端到端延迟。用同一高速视频画面
拍摄事件源及显示输出，逐帧计时；统计至少 20 次中位数、P95、最大值。
本轮先记录基线，不捏造延迟达标数值。

## 日志

每阶段保存到 /home/linaro/pcie-board-tests/<stage>.XXXXXX，包含：
pcie.before/after.log、link.timeline.log、dmesg.before/after.log、阶段日志，
以及该阶段播放器/完整性诊断产生的原始日志副本。
benchmark 的 pcie-video-report.*.zip 会一并复制，保留其准确子测试数据。
不要仅根据退出末尾的几行评估 60 秒稳态；排除最初约 5 秒后检查持续输出与错误增长。
出现新增错误先保留本轮日志并停止后续阶段，使用独立 test2 v26 做 A/B 回退比较。
