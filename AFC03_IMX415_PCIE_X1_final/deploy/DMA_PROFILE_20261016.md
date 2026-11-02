# DMA 分段计时诊断候选（2026-10-16）

这一步用于定位瓶颈，**尚未实现 DMA 缓冲复用或描述符预提交，也不宣称提升 FPS**。
在原工程的 `deploy/sgdma_drv` 加入默认关闭的计时，保留已验证的 4 KiB 请求、轮询参数、
描述符与 EOP 行为、帧协议及完整 CRC。无需重新综合或烧录 bit。

板上环境已由用户确认：Linux 6.1.99/aarch64，构建目录链接指向
`/usr/src/linux-headers-6.1-rockchip`。链接存在不代表头文件完整或版本一定匹配，需以编译和 vermagic 为准。
当前参数：poll_mode=1、enable_st_c2h_credit=1、force_st_c2h_wb=0、interrupt_mode=1、
desc_blen_max=1048576、C2H/H2C timeout=10 秒。timeout 是超时阈值，不表示每次 read 都等待 10 秒。

## 已有板端证据

- 新接收器 CRC 三后端、流水线、FIFO/满队列、停止/异常、缓冲复用回归由用户在板上全部 PASS。
- 原图显示约 12.24 FPS，无显示约 12.74 FPS；300 帧跳过 RGB24 输出仍约 12.13 FPS。
  后者包括脚本约一秒启动等待，payload 3,540,153,024 字节，ratio=1.896944，所有完整性错误为零。
- 灰度 LZ77 接收约 26.80 FPS；灰度 LZ77+YOLO 接收约 24.01、显示约 22.73、
  稳定阶段检测采样均值约 22.71 FPS。原图 20–30 FPS 仍未达标。
- 300 帧隔离测试新出现一条 `not get comp desc`，不能据此单独判定根因。

## 改动和边界

新增 `sgdma_drv/st_c2h_profile.c/.h`，Makefile 必须包含新目标文件。
在 cdev、sgdma_xfer_submit 的原执行路径增加可选时间点，原导出 API 保持不变。
计时仅覆盖同步字符设备、ST C2H、请求长度恰好 4096 的读取；H2C、V4L2 和其他长度不纳入调用统计。
`poll_empty` 则记录启用期间所有 ST C2H 引擎的空完成提示，测试时应保持唯一读者。

启用：`echo 1 > /sys/module/anlogic_pci/parameters/st_c2h_profile`，同时清空统计并更新 epoch。
关闭：`echo 0 > .../st_c2h_profile`，保留统计；已开始的调用可在完成后入账。
读取：`cat /sys/module/anlogic_pci/parameters/st_c2h_profile_stats`。
重置不会将旧 epoch 的在途调用混入新统计。采集脚本在停止测试后关闭计时、读取快照。

外层阶段：用户页与 SG 准备、整个 submit、用户页/SG 回收。
submit 内层：DMA map、请求分配、描述符锁等待、描述符构建、入队/启动、轮询线程唤醒、
完成等待、完成处理/transfer 回收、submit 尾部清理。

外层 submit 已包含所有内层时间，不能重复相加。
`completion_wait` 包含 FPGA 数据等待、DMA 传输、轮询/完成通知和线程调度；不是纯硬件耗时。
`completion_reap` 包括 transfer_destroy 正常路径中的 DMA unmap。
短 EOP read 可合法，`short_reads` 本身不表示丢数据；以完整帧 CRC/长度为准。
计时本身有时钟读取和汇总锁开销，开关对照仍需实测；没有每 read 打印日志。
最大调用时间可能包含相机启动等待。时间点覆盖之外的检查、统计更新和系统调用开销不计入 total_ns。

## 先编译，不先卸载正在使用的驱动

先完整更新 deploy 的源码、头文件、Makefile 和脚本，保留板上现有 .ko。
以下命令只备份旧 .ko 并编译，不重载驱动：

```bash
cd /home/linaro/deploy
sha256sum -c SHA256SUMS
set -o pipefail
B=$(mktemp -d /home/linaro/dma-driver-backup.XXXXXX)
cp -a sgdma_drv/anlogic_pci.ko "$B/"
cp -a v4l2_drv/milianke_v4l2.ko "$B/"
echo "Driver backup: $B"
make -C sgdma_drv 2>&1 | tee /home/linaro/dma-profile-build.log
modinfo -F vermagic sgdma_drv/anlogic_pci.ko
modinfo -p sgdma_drv/anlogic_pci.ko | grep st_c2h_profile
```

若 make 失败就停止，并返回 build.log；旧驱动仍在内核运行。不要卸载它。
预期编译生成 anlogic_pci.ko，vermagic 的内核版本为 6.1.99；参数表包含 st_c2h_profile 和 st_c2h_profile_stats。
本机 Windows 无可用 Linux 内核编译环境，新增驱动尚未经内核编译和板端运行验证。

## 编译成功后重载

停止所有播放和测试，先检查使用者。下面的 rmmod 失败时应停止后续操作，不强制卸载：

```bash
cd /home/linaro/deploy
fuser -v /dev/ANLOGIC-PCI0_c2h_0 /dev/video73
# 确认上面没有使用者后，在一个子 shell 中执行：
(
  set -e
  busybox devmem 0x21200060 32 0
  rmmod milianke_v4l2
  rmmod anlogic_pci
  insmod ./sgdma_drv/anlogic_pci.ko poll_mode=1 enable_st_c2h_credit=1 \
    force_st_c2h_wb=0 desc_blen_max=1048576 interrupt_mode=1 c2h_timeout=10 h2c_timeout=10
  insmod ./v4l2_drv/milianke_v4l2.ko
  cat /sys/module/anlogic_pci/parameters/st_c2h_profile_stats
)
```

预期 version=dma-profile-20261016、enabled=0、calls=0。若加载失败，保留 dmesg 报错，
使用刚才打印的备份目录中的两份 .ko 和相同参数恢复；不要从 test2 覆盖当前 FPGA 工程。

## 采集一次 300 帧

```bash
cd /home/linaro/deploy
bash collect_dma_profile.sh 300 0
```

脚本只开启统计并运行已有完整性测试，不重载驱动。预计约半分钟，现有测试自带 60 秒超时。
输出目录为 `/home/linaro/dma-profile.XXXXXX`，并生成同名 tar.gz 日志包。
包含原始 profile.stats、换算为每 read 微秒的 profile.summary、内核前后日志、驱动配置和完整测试目录。
要求 300 帧、receiver_exit=0/test_exit=0、CRC/decode/format/FPGA 完整性错误全为零。
请返回整个 tar.gz；本轮重点是阶段占比，不是以计时启用时的 FPS 验收提速。

关闭统计后可用原播放命令继续使用。本次没有改 FPGA、接收器或 v26 回退目录。
