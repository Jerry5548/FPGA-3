# RK3576 接收软件优化候选（2026-10-16）

本次只修改用户态接收软件和播放脚本。保持当前已上板的 v28 bit 和内核驱动，**无需重新综合或烧录**。
保持 1080p、4 KiB 对齐 DMA read，以及现有 header/footer/token/IEEE CRC32 协议。
v26 回退目录未修改。现有总包名称保留，不新增另一份 ZIP。

## 已实现的代码

1. CRC：根据 Linux HWCAP 自动启用 ARMv8 IEEE CRC32 指令。没有此能力时使用 slicing-by-8；
   保留原单表算法用于 A/B 对照。三个后端使用相同多项式和初末取反，完整校验每一帧，
   CRC 通过后才解码和输出。不使用 CRC32C，不抽样、不跳过校验。
2. 三阶段流水线：一个线程直接读入 4 MiB 环形缓冲中的 1024 个对齐 4 KiB 槽；
   主线程进行帧重组、CRC 和解码；输出线程写完整图像。各阶段可重叠，队列满时等待，
   不覆盖正在使用的缓冲，不通过丢弃已接收帧增加接收 FPS。
3. 两个图像缓冲：按历史最大 raw_len 增长并复用，输出完成后才能重新解码到该缓冲。
   1080p 时每槽分配容量约 8 MiB。保留必要的压缩帧重组拷贝和 RGB24 pipe 输出，未实现全链路零拷贝。

读取线程在 read 系统调用之外关闭线程取消，停止时先取消并 join，再关闭 fd 和释放内存。
输出正常 EOF 或达到 -n 时排空已验证图像；坏帧、输出错误或信号时退出，避免继续显示错误数据。
设备驱动若阻塞在内核，停止仍可能要等待驱动超时，播放脚本给予最多约 12 秒正常退出时间。

源码包含三个新头文件，更新时必须一并复制：

- `rk3576/rx_crc.h`
- `rk3576/rx_read_pipeline.h`
- `rk3576/rx_output_pipeline.h`

`--version` 保留旧的脚本兼容值；`--build-info` 应输出 `rx-pipeline-20261016`。
`RX_PIPELINE=0` 选择串行调度；`RX_PIPELINE=1`（播放默认）选择流水线。
`RX_CRC=auto|table|slice8|arm` 选择 CRC；不支持 arm 时显式选择它会报错，auto 自动回退。

## 验证状态与限制

发布时 Windows 本机没有可用的 Linux C 编译器。随后用户在 RK3576 上确认编译、
ARM/table/slice8 CRC 自测和完整流水线回归全部 PASS；实际播放的板端结果见 DMA_PROFILE_20261016.md。
灰度 LZ77+YOLO 当前场景已测得约 22.7 FPS；原图 LZ77 仍约 12–13 FPS。
这不代表所有场景已验收，也不代表旧 YOLO 堆异常的根因已查明。

新增 `test_receiver_pipeline.py` 可在 Linux 测试：CRC 各后端、串行/流水线输出一致性、
大小变化/空帧/缓冲复用、碎片 FIFO、慢输出及满队列、EOF 排空、-n、SIGINT/SIGTERM、
CRC/坏 token/截断拒绝、broken pipe、读写失败、抓取上限和已有文件保护。

此前板端基线：原图约 5.82 FPS，CRC 46.9 ms/帧；灰度约 10.42 FPS，CRC 23.1 ms/帧；
Sobel 约 33.6 FPS。更新后的板端数据见 DMA_PROFILE_20261016.md。

原图约 1.896 倍的 payload 膨胀仍存在。本次不改变 token 编码或实现更广泛的字典匹配。
4 KiB 同步 DMA 的提交开销、FPGA 生产消费差额和 DDR_NO_SLOT 也不会自动消失。

## 板端操作

先停止已有播放，完整更新 deploy（包括 rk3576 下的头文件），不要只替换 C 文件。

```bash
cd /home/linaro/deploy
sha256sum -c SHA256SUMS
gcc --version
cd rk3576
bash build.sh
./rk3576_lz77_rx --build-info
./rk3576_lz77_rx --self-test-crc
python3 test_rgb24_geometry.py --receiver ./rk3576_lz77_rx
python3 test_rgb24_geometry.py --receiver ./rk3576_lz77_rx --pipeline
python3 test_video_output.py --receiver ./rk3576_lz77_rx
python3 test_video_output.py --receiver ./rk3576_lz77_rx --pipeline
python3 test_receiver_pipeline.py --receiver ./rk3576_lz77_rx 2>&1 | tee /home/linaro/rx-pipeline-test.log
```

如果 gcc 不存在，在可联网且软件源可用的板上安装 `build-essential`，无需安装 VS Code 或 Windows MinGW。
任何编译/回归失败都先停止后续性能测试，并返回完整报错。

全部通过后，做相同输入的离线 A/B：

```bash
cd /home/linaro/deploy/rk3576
python3 benchmark_video_decode.py --receiver ./rk3576_lz77_rx --serial --crc table 2>&1 | tee /home/linaro/rx-serial-table.log
python3 benchmark_video_decode.py --receiver ./rk3576_lz77_rx --serial --crc auto 2>&1 | tee /home/linaro/rx-serial-auto.log
python3 benchmark_video_decode.py --receiver ./rk3576_lz77_rx --pipeline --crc auto 2>&1 | tee /home/linaro/rx-pipeline-auto.log
```

默认每种数据 12 帧，literal 临时文件约 150 MB，结束自动清理；仅测 CPU、文件输入及 /dev/null 输出，不代表 PCIe 性能。

再运行灰度，保持相同镜头和场景，各约 30 秒后 Ctrl+C：

```bash
cd /home/linaro/deploy
RX_PIPELINE=0 RX_CRC=table YOLO_MODEL= bash play_lz77_video.sh 1 188
# 保存本次打印的日志目录，再运行下一组
RX_PIPELINE=1 RX_CRC=auto YOLO_MODEL= bash play_lz77_video.sh 1 188
```

预期新日志包含 `FEATURES rx-pipeline-20261016`、`read_size=4096`、
`CRC backend=arm verification=full`（无硬件能力时 slice8）、`PIPELINE enabled=1`。
要求 CRC/decode/format 和 FPGA 完整性错误均为 0。记录实际接收 FPS 和实际显示 FPS，不能以重复画面代替新帧。

流水线中 `PERF read_wait_ms` 是主线程等待输入槽的时间，不再等于 DMA read 系统调用耗时；
`PIPELINE_READ dma_read_s` 单列生产线程实际 read 用时及队列峰值。
各阶段时间有重叠，且可能有少量未完成帧，不能相加推算帧周期。
PERF FPS 以完整成功输出的帧计数；信号停止可能留下一个未计数的部分 RGB24 输出帧。

请返回测试日志、三组离线日志及两次播放目录中的 `rx.log`、`gst.log`、`hardware.log`、
`after.log`、`first_fault.log`、`dmesg.log`。灰度通过后再测试模式 0/6 和 YOLO。

