# v27 MIPI 修正候选：上板步骤

本包在原工程构建，修正 PH1A IDELAY 使能及扫描档位/长度。
版本寄存器应为 **0x56440027**。已完成的本地验证见 reports 和 manifest.json；
source 60 FPS、raw 采集和端到端表现尚待板卡验证，PCIe USR-6144 仍存在。

1. 用已有 TD 下载方式配置本包 `imx415_pcie_4k_mipi_v27.bit`。
   确保新 FPGA 配置就绪后 RK3576 枚举 PCIe。仅 JTAG 易失配置时，勿在
   下载后给 FPGA 断电导致丢失候选。不要选旧默认名称的 v26 bit。
2. 将本包 deploy 内容合并到板端 /home/linaro/deploy，同名文件覆盖，保留
   板端已有 sgdma_drv、v4l2_drv、启动配置和 YOLO 模型。
3. 停止所有旧 V4L2/C2H/YOLO 摄像头读取程序，按顺序验证。

```bash
cd /home/linaro/deploy
sha256sum -c SHA256SUMS
bash -n validate_board_clock.sh
busybox devmem 0x2120005c 32
# 必须读到 0x56440027。BAR 地址若已改变，以 preflight 自动识别结果为准。
bash validate_board_clock.sh preflight
bash validate_board_clock.sh source
```

source 稳态 camera_per_s 目标约 60，查看 mipi_best_len 和 camera_stage_flags。
曾见标志 0xff 不能代替持续帧计数；无 DMA 消费者时门控跳帧可增长。
不再以 source 测试退出码 0 判断源帧率达标，需查看上述计数。

源端持续产帧后再执行：

```bash
cd /home/linaro/deploy
bash validate_board_clock.sh raw
```

raw 目标为稳态 OUTPUT FPS 约 60、完整缓冲无 DMA timeout，持续 Gen2 x1。
若 source 仍为 0，保存该目录，暂停 raw/display/LZ77，继续查上游。
若 source 约 60 而 raw 无完成帧，继续查 DMA/EOP/FIFO，不将其混作 MCLK 失败。

接收源码已随包带上，但本次未修改接收协议。若板端需重编译：

```bash
cd /home/linaro/deploy/rk3576
bash build.sh && ./rk3576_lz77_rx --version &&
python3 test_rgb24_geometry.py --receiver ./rk3576_lz77_rx &&
python3 test_video_output.py --receiver ./rk3576_lz77_rx
```

raw 通过后才继续 display、lz77、repeat、benchmark。
完整性要求及 MCLK=27 MHz 的独立测量要求沿用前次验收说明。
日志保存在 /home/linaro/pcie-board-tests/；v26 独立回退在
D:/FPGA/AFC03_IMX415_PCIE_X1_test2/IMX415_PCIE_X1。
