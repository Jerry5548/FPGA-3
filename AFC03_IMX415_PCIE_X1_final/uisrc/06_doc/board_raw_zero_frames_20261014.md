# 首次候选 raw 上板结果：零帧，未通过

输入：用户粘贴的 raw.4EbfhQ 终端日志；子目录 raw-video.g5PpbB。
目前没有读取到板端 hardware.log、before/after.log 或 link.timeline.log。

- 初始 PCIe LnkSta 为 5 GT/s x1、Anlogic-pcie 已绑定。
- milianke-v4l2 启动 1920x1080 mode=0，6220800 字节缓冲区。
- DMA 线程启动时间 1216.697808，首个 timeout 时间 1216.801469，
  间隔约 0.103661 秒，明显早于最终 Ctrl+C/定时退出。
- 多次 BUSY、completed_desc_count=0、DMA error -512。
- 最后 stop_streaming: 0 frames captured。没有 OUTPUT FPS 样本。
- timeout 返回 124；旧封装将预定超时视为流程正常结束并返回 0。
  该结果不能用于图像通过或 FPS 验收。已在封装中增加零输出失败检查；
  正数 FPS 只证明观察到输出，不证明无错误或已达 60 FPS。

本地 V4L2 源码 DMA_TIMEOUT_MS=100，与初始约 104 ms 超时相符，
但仅此不能确定根因是启动慢、无输入、帧末标记错误或 DMA 状态问题。
rkcif-mipi-lvds 的 remote sensor 报错不能直接当作 PCIe FPGA 传感器故障证据；
同一日志已明确显示实际启动的是 milianke-v4l2。

下一步先取本次原始寄存器快照与 HARDWARE 增量：
camera、raw_gate_pass/drop、cam_fifo_drop 及 camera status。
零前级计数优先查时钟/I2C/MIPI/enable；前级有帧但 DMA 无完成则查 gate、FIFO、
EOP/TLAST 与 DMA。两种情形都需要后续证据，当前不判定硬件损坏，亦不把
USR-6144 直接定为根因。先保留日志，不继续 display/lz77/benchmark。

## 本轮硬件日志补充

读取用户后续粘贴的 raw.4EbfhQ 快照：链路每次采样均 5 GT/s x1；
camera_value 几乎全程为 0，仅最后一条变为 1；raw_gate_pass 为 0→1→2，
raw_gate_drop 与 cam_fifo_drop 全程为 0。因此没有持续的完整打包帧输出，
不能以链路速率正常认定像素数据或 DMA 正常。

camera_status=0x01002015 / 0x01002017：I2C done=1、delay done=1、
I2C bus error 采样值=0、曾见 SOF=1、MIPI best_len[11:6]=0。
auto_delay_ctl.v 的 ST_APPLY 在 best_len=0 时选用固定 tap=32，并仍在
ST_DONE 置 done=1。故 done 不代表找到采样窗口；零窗口是进一步查 MIPI
校准/数据有效性的线索，但不能单独确定故障位置。
MIPI alive 是瞬时边沿检测值，读到 0 不足以证明恢复时钟已停止。

raw_gate_pass_per_s=2133909858.626 是监测期间计数器被复位、模减法误认为
32 位回绕造成的伪速率。monitor_video_perf.py 已将下降区间标为
discontinuity 并重建基线，不发布该区间速率；模拟 5→0 与持续递增 camera
的调用验证通过。现增加 control/status、MIPI best_len、debug_state、DMA
beat 和 0x88 高 8 位阶段标志的读回，避免只看截断的帧计数。

validate_board_clock.sh 新增 source 阶段：不启动 DMA/V4L2，短时使能 raw
摄像头/ISP 并观察 pack4 输出。该工程 cam_tready 固定为 1，因此可观察
上游完整打包帧是否持续产生；下游 FIFO 满和门控跳帧在该场景是预期现象，
不能用于数据完整性验收。source 仅用于区分前级输出和 DMA 依赖，脚本自身
结束码不是 source FPS 达标声明。需先复制更新的两个脚本到板端再运行。
