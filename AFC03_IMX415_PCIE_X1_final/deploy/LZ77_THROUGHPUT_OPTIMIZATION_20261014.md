# v28 四字节 LZ77 与四槽 DDR 队列候选

本次直接修改原 `imx415_pcie_4k.al` 工程引用的 RTL，不新建 fix 工程，不修改 test2/v26。
候选寄存器版本为 **0x56440028**。用户自行在原工程综合、实现并生成 compress bit；
本次仅做 RTL/协议仿真，没有运行综合、实现、bitgen 或烧录。

## 有效路径

`lz77_rgb_c2h_path.v` 的主模块现在连接：

1. `rgb128_quad_stream`：128-bit 输入由两级 held beat/lookahead 转为每拍一个 32-bit group。
   连续帧无额外逐字节收集气泡；保留孤立尾部拒绝、提前 SOF 关闭旧帧、固定几何边界检查。
2. `lz77_quad_encoder`：每次握手接受四字节，在四个 lane 上顺序展开 distance=1 重复状态。
   重复状态跨 group 和 128-bit beat 保留。每批最多六个 token（12 payload bytes），包含
   旧的 1–2 个待决重复字节，最大 match 127、最小 match 3，帧首有 literal seed。
3. `lz77_quad_formatter`：批量处理 token、raw/comp/token 累计和 IEEE reflected CRC32。
   2/4/6/8/10/12 payload bytes 的 CRC 更新由 GF(2) 并行 XOR 网络计算，零字节批次不更新。
   格式仍是 LZ77 + 尺寸 + reserved=0 + ID / token payload / END! + raw/comp/tokens/CRC。
4. `lz77_quad_packer`：每批最多 16 字节压入 128-bit 输出，允许上一输出被接受时同步填入下一拍；
   中间 EOP 包为 16 KiB，只有最终 TLAST 允许 partial TKEEP。carry 和 frame footer 不丢弃。

原串行 wrapper 保留为同文件内的 `lz77_rgb_c2h_path_serial`，不是板上主路径。
并行模块均放在已被工程引用的 `lz77_rgb_c2h_path.v` 内，无需手工添加新的设计文件。
协议兼容不表示生成的 token 切分逐字节与旧 encoder 相同；相同原图必须解出相同像素。
0xb0 保持历史 literal=1/match=2 计数语义，不是线上的 payload 字节数；以接收端 footer 为准。

## 帧槽与地址

`ddr_frame_store_axi.v`、`ddr_camera_frame_path.v` 增加 `SLOT_COUNT` 参数，默认 2 保持旧实例兼容；
板上 `pcie_ddr_camera.v` 显式设为 4。每槽 stride=8 MiB，占用 DDR [0,32 MiB)，每帧仍为
6,220,800 字节。槽必须经历 FREE → WRITING → READY → READING → FREE；读完最后一个正确
AXI R beat 才释放，读响应异常继续 halt，短帧/坏写响应不发布。

READY 槽索引进入有界 FIFO，按成功发布顺序回放；分配指针环绕查找空槽，不覆盖读者或未回放帧。
队列独立处理同拍 publish/dequeue，拒绝帧不会占 READY 队列。首次错误快照及原有错误计数保留。
多槽配置下，0xec 的 [31:24] 为槽数，[23:16] 为 READY 队列深度，低位保留原 FSM/前两槽状态。
四槽只吸收突发/短时背压，不能改变长期生产/消费速率差；FIFO 排队也可能增加队列等待延迟。

## 已完成仿真

- `run_frames.ps1`：100 帧包含随机字节、常量、RGB 重复分量，完整像素与 Python 参考解码、
  ID、几何、CRC 对照；异常 SOF/LAST/孤立尾、TKEEP/TLAST、背压稳定性通过。
- `tb_quad_runs`：重复长度 1..260，跨四字节 lane，源间隙和输出随机停顿，逐字节 scoreboard 通过。
- `tb_quad_throughput`：无背压、不可压缩数据 82,944 原始字节在 20,743 拍内完整发出，
  包含 header/footer 和 C2H packetization，约 4 字节/拍。125 MHz 对应模型约 500 MB/s 原始输入能力，
  不代表 PCIe、DDR 或板端消费也有该吞吐。
- DDR 默认两槽和四槽：100 帧随机 AXI/异步时钟回归、满槽保护、无覆盖、FIFO 顺序、
  48 曝光不等待回放的并发压力/指针回绕、读写故障与复位、startup guard 均通过。
- DDR → 四字节 LZ77 的两槽/四槽/startup 组合，完整像素/CRC/源帧号对照通过。
- 模式 5/6 预处理→RGB24打包→四槽 DDR→四字节 LZ77 的像素、CRC、帧号对照通过。

这些是行为仿真；没有实际器件资源、setup/hold 和板端 FPS 结论。并行 encoder 组合链、CRC XOR 网络、
宽 packer 的资源与时序均需 TD 核验。旧 v27 +0.322/+0.019 ns 不覆盖新设计。
历史 `tb_edge_runtime` 的 mode3/frame8 预处理像素不匹配仍是独立未修问题，本次不把整个 edge suite 记为通过。

## 上板步骤

1. 关闭 TD 工程后重新打开原 `imx415_pcie_4k.al`，重新运行综合、实现。检查没有错误，
   确认 final Setup/Hold WNS 均非负、TNS 为零，核对约束/时钟警告和新增资源占用。
2. 用户生成新的 `imx415_pcie_4k_compress.bit`，确认时间/哈希后下载。
3. 把现有 `deploy_current_20261009/deploy` 更新目录内容合并到板端 deploy（保留驱动/模型），
   或使用现有原文件名的完整 ZIP。板端 SHA256SUMS 必须随同文件复制。
4. `sha256sum -c SHA256SUMS`；读取版本：`busybox devmem 0x2120005c 32` 应为 0x56440028。
   旧 bit 不会因为复制 deploy 而更新。此次无需重编内核驱动，用户态保留 4096 read；协议不变。
5. 先运行 `bash test_lz77_frames.sh 0x21200000 3 0`，应收到三帧、CRC/decode/format 和硬件错误均为零。
6. 再运行 `YOLO_MODEL= bash play_lz77_video.sh 0 188` 约 30 秒，按 Ctrl+C。
   保存 rx/gst/hardware/after/first_fault/dmesg，比较当前基线约 4.7 FPS。

若需重新编译接收程序，可进入 rk3576 执行 build.sh 及 test_rgb24_geometry/test_video_output；
接收协议和 4 KiB read 未改。本次不恢复有丢字节证据的 16/64 KiB 用户请求。
不关闭 CRC、不放宽几何、不重复帧凑 FPS。

## 吞吐与验收边界

目标仍为 1080p 普通 60 FPS、LZ77+YOLO 同时 20–30 FPS，但本次不保证已达到。
原图 distance=1 token 在现有场景约膨胀至 1.86–1.89 倍，多 lane 不会自动改善压缩率；
CPU CRC/解压仍串行、4 KiB 同步 DMA 仍有提交开销，YOLO native heap abort 尚未修复。
更多帧槽不能弥补这些长期限制。若源为60而消费者20–30，整帧跳过可仍约30–40/s；
只有整个消费者持续追上60，才有条件要求 DDR_NO_SLOT 稳态接近零。


---

?????????????????????? v28 ?????

# LZ77 吞吐优化候选（2026-10-14）

本轮关闭 YOLO 后，接收仍约 2.65 FPS；相机计数约 60/s，压缩帧约 2.5–3/s，DDR_NO_SLOT
持续增长。这说明 LZ77/DDR 帧槽吞吐不足是主要限制；尚无证据表明 PCIe 物理链路故障。

实现了两项候选改动：

- `uisrc/01_rtl/lz77_repeat_encoder.v`：literal seed 发射时同步接受下一字节，消除每个
  literal 间的收集空拍，协议、CRC、帧头尾格式保持不变。
- `uisrc/01_rtl/imx415_pcie_top.v`：C2H EOP 从 256 formatter words（约 1 KiB）提升到
  4096 words（约 16 KiB）。
- `rk3576/rk3576_lz77_rx.c`：64 KiB read 候选在上板测试中未通过。2026-10-16 恢复
  4 KiB 对齐请求；FPGA 16 KiB EOP 分包保留，用户态跨多次 read 重组完整帧。

## 本机验证

- C2H 多帧、TKEEP/TLAST、CRC、ID、几何及像素还原回归通过。
- DDR/帧存/启动跳过/故障快照和 DDR→LZ77 完整回归通过。
- 无重复 literal 编码器 A/B：10,000 bytes，基线 20,000 cycles，候选 10,002 cycles。
- 16 KiB packetizer 仿真确认 EOP 间隔 1024 个 128-bit beats，最终短包正常结束。
- 编码器长度 1..260 的重复段、输入间隙、输出停顿，通过字节级 scoreboard。
- 模式 5/6 预处理→DDR→LZ77 像素、CRC、捕获帧号对照通过；扩展模式切换测试
  `tb_edge_runtime` 在 mode=3/frame=8/beat=0 像素不匹配。该测试不实例化本次修改的
  编码器/分包器，需独立处理；不能把整个 edge regression 标为通过。

这些是 RTL 仿真结果，不代表综合时序闭合或板端 FPS。用户在原工程自行综合、实现、审查 setup/hold
并生成 compress bit；本次未运行 bitgen、未烧录，也不覆盖 v26 回退目录。
现有 Windows 环境没有 Linux C 编译器，接收程序的重新构建、几何和 RGB24 输出自测需在板端执行。
接收版本标识保持兼容脚本的 `lz77-rx-video-perf-20261009`，修正后 START 行应打印 `read_size=4096`。
FPGA 版本寄存器同样保持 0x56440027；不能靠该值区别旧 bit 与候选，应记录新 compress bit 的哈希。

125 MHz 单字节输入的理论上限仍约 125 MB/s；1080p RGB24 在 20 FPS 需 124.416 MB/s 原始输入，
几乎没有吞吐余量。30 FPS 需 186.624 MB/s，超出单字节通道上限。实际压缩率随图像变化，
literal payload 还可能膨胀，因此不能仅凭局部仿真承诺目标 FPS。

完成本机修改后，需把新 `rk3576_lz77_rx.c` 同步到 deploy，板端重新 `bash build.sh`。新 compress bit
烧录后，先执行 `YOLO_MODEL= bash play_lz77_video.sh 0 188` 观察 10–30 秒，再测 YOLO。保留 rx/gst/
hardware/dmesg 日志；记录完整接收 FPS、显示 FPS、comp_frames、DDR_NO_SLOT、CRC/decode/format 错误
及整帧跳过数。硬件错误需为零，且报告跳帧率，不能只凭显示 FPS 验收。

## 2026-10-16 板端读取尺寸对照

相同 FPGA/驱动条件下：64 KiB 抓包首帧按 footer 声明少 358,928 字节；16 KiB 抓包
首帧通过，但第二帧缺 480 字节且帧头丢失。4 KiB 抓包共 33,555,018 字节，其中两个
完整帧（ID 1、2）均通过 CRC、token、RGB24 几何和参考解码，第三帧 ID 15 因抓取上限
只保留前缀。帧 ID 跳变仍反映 DDR 整帧跳过，不应当解释为采集已达 60 FPS。

该结果支持继续调查多描述符 early-EOP 完成/停止/重提交及长度统计，尚未证明驱动内
具体哪条指令导致缺口；短 read 本身合法。先使用 4 KiB 路径恢复完整性，再测连续播放。
本次仅回退用户态请求尺寸，不改 bit 或驱动，不需重新烧录。两帧通过不是长时间或性能验收。

## 2026-10-16 RK3576 software pipeline candidate

See RX_PIPELINE_20261016.md for the current three-stage receiver, runtime ARM/slice8 CRC, two reusable image buffers, verification status and exact board commands. Keep the already-tested v28 bit; this software update needs no new FPGA build or driver replacement. The user has now passed C compilation and native ARM/pthread regressions on RK3576; measured original LZ77 is about 12 FPS and grayscale LZ77+YOLO about 22.7 FPS. See DMA_PROFILE_20261016.md for the next optional driver-timing candidate.
