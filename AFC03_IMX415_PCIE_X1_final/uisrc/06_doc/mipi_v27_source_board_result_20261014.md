# v27 源端首次上板结果：恢复约 60 FPS

用户自行构建、使用 compress 配置位流。板端版本读回 0x56440027。
本次仅分析用户提供的日志，不运行综合/实现/位流生成。
测试目录：/home/linaro/pcie-board-tests/source.kpfngU。

source 测试只使能原图摄像头/ISP，不启动 V4L2 或 C2H DMA 接收。
该工程 cam_tready 固定为 1，pack4 输出帧计数可独立于 DMA 消费观察。

## 观测结果

- pack4 帧计数：5 → 127 → 248 → 369 → 491 → 612，持续增长。
- 五个区间 camera_per_s：60.329、59.889、59.859、60.376、59.871。
  范围 59.859–60.376 FPS，区间速率算术平均约 60.065 FPS。
  不是传感器 XVS 直接测量，也不是显示/YOLO FPS。
- mipi_best_len 持续为 15，I2C done、delay done 置位，stage sticky=0xff。
- cam_fifo_drop_value 为 0。
- gate_pass 维持 1、gate_drop 持续增长：无 DMA 消费者时输出 FIFO 填满，
  门控整帧丢弃是预期现象，不据此判定图像链路失败。
- dma_beats=0：本次没有 DMA 读取，属预期值。
- 链路各次采样为 5.0 GT/s、x1。
- 用户提供的 dmesg.before.log 与 dmesg.after.log 字节完全一致，未见本轮新增内核日志。
- PCIe 前后快照 UESta/CESta 未置位。

相较此前 v26 source.IiS0tE 持续零帧、best_len=0 的表现，本轮支持 MIPI
延时修正方向有效。三个修改同时应用，不能据此孤立量化每一处修改的贡献。

## 验收边界与下一步

源端约 60 FPS 初筛通过。尚未证明 DMA、V4L2、显示能达到 60 FPS，也尚未
验证图像像素完整性或 LZ77+YOLO 性能。MCLK=27 MHz 的独立物理测量仍未提供。
PCIe USR-6144 未因此消除。

下一步使用同一位流执行：

```bash
cd /home/linaro/deploy
bash validate_board_clock.sh raw
```

目标：稳态 camera_per_s 与 OUTPUT source=V4L2 FPS 均接近 60；没有新增
DMA timeout/descriptor 不完成、FIFO 丢弃或持续 gate drops。
若源端保持 60 而 OUTPUT 偏低，定位后级 DMA/V4L2；若 DMA 再次超时，
保留该次 raw 目录完整日志，继续查传输/帧边界，不重复归因于源时钟。
