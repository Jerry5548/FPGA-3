# 1080p 约 26.7 FPS：摄像头输入时钟与寄存器配置不匹配

## 结论与证据等级

已确认源码存在明确的时钟配置错误：摄像头 INCK/MCLK 由 24 MHz 二分频成
12 MHz，但模式 0/2 的传感器时钟配置对应 27 MHz / 891 Mbps 每 lane。
按当前行场参数和时钟比例推算帧率为 26.669123 FPS，与用户上传 benchmark
中的无显示输出 26.669 FPS 一致。这是源端低帧率的高置信度解释。

仍未在摄像头连接器上实测 MCLK/读取芯片真实寄存器，尚未下载修正版并做 A/B。
所以区分“源码错误已证实”与“硬件改正后恢复 60 FPS 已验证”；后者尚未完成。
这次只新增审计脚本、机器可读结果和报告，没有改动工作位流/RTL/驱动/deploy。

## 1. 实际时钟链

工程使用 imx415_pcie_4k.al 中 al_ip/ui_pll.ipc，GeneratedFiles 为 ui_pll.v。
不是另一份参考 MIPI 工程的 PLL。

当前 ui_pll.v 为外部 C0 反馈：

| 项目 | 源码/结果 |
|---|---|
| FIN | 100 MHz |
| REFCLK_DIV / FBCLK_DIV | 2 / 3 |
| C0 | 150 MHz |
| CLKC0_DIV | 8，VCO 为 1200 MHz |
| CLKC2_DIV | 50，C2 为 24 MHz |
| 顶层 clk2_out | 接 cam_24m |
| 顶层每次 cam_24m 上升沿 | cam_mclk_r <= ~cam_mclk_r |
| 传感器 cam_mclk | 12 MHz |

独立证据：phy_1/rebuild_ddr_v26.console.log 第 79 行衍生时钟从 100 MHz 除以
4.1667；route_clock_utilization.txt 中 C2 周期为 41.666 ns，符合 24 MHz。
顶层 cam_mclk 引脚约束在 imx415_pcie.adc 为 A18、LVCMOS18。

顶层“6–27MHz, 12MHz OK”注释错误。Sony E19504 第 1/78 页列出的输入
频率为 24、27、37.125、72、74.25 MHz；12 MHz 不是该手册列出的配置频率。
参考：[Sony IMX415 手册](https://dl.khadas.com/products/add-ons/cameras/imx415/datasheet/imx415-datasheet.pdf)。

## 2. 传感器表采用 27 MHz 配置

模式 0（1080p）和模式 2（同传感器模式加 FPGA 裁剪）的关键值：

| 寄存器 | 当前值 |
|---|---:|
| BCWAIT_TIME 有效位 | 0x05D |
| CPWAIT_TIME 有效位 | 0x042 |
| SYS_MODE / 0x3033 | 0x05 |
| INCKSEL1 | 0x00 |
| INCKSEL2、INCKSEL5 | 0x23、0x23 |
| INCKSEL3、INCKSEL4 | 0x00C6、0x00E7 |
| TXCLKESC_FREQ | 0x06C0 |
| INCKSEL6、INCKSEL7 | 0、1 |

这组值与 Linux 主线 IMX415 驱动的 lane_rate=891000000、inck=27000000 配置
吻合，也与 Sony 手册第 80 页的 891 Mbps / 27 MHz 表吻合。
[Linux IMX415 驱动](https://github.com/torvalds/linux/blob/master/drivers/media/i2c/imx415.c)。

注意 0x300B 写值为 0xA0，但 CPWAIT_TIME 高有效位只有 [1:0]，故有效值仍为
0x042；保留位写法应在整理传感器表时核对，不能把 0xA042 当作有效等待值。

顶层和 ui_imx415_reg.v 的 SHA256 均与 v26 release_manifest.json 一致。
该 manifest 未收录顶层 al_ip/ui_pll 文件，PLL 的构建状态通过上述 TD 日志交叉核实，
不伪称这些 IP 文件也有发布哈希匹配证明。

## 3. 数值如何解释实测值

当前 HMAX=0x021E=542，VMAX=0x08EB=2283。
以 27 MHz 配置所对应的 74.25 MHz 行时序基准估算：

```text
名义行场时序 = 74,250,000 / (542 × 2283) = 60.005528 FPS
输入仅12MHz  = 60.005528 × (12 / 27)     = 26.669123 FPS
预测帧周期   ≈ 37.4965 ms
```

这里的按比例推算是对异常输入时钟下现象的解释，不是保证传感器在非标时钟
工作正常的公式，也不意味着当前定制 RAW10/binning 配置经 Sony 60 FPS 认证。

同理，名义 891 Mbps/lane 按 12/27 缩放为约 396 Mbps/lane，MIPI 时钟约
198 MHz。工程 SDC 恰好把 mipi_hs_clk 约束为 200 MHz（5 ns），也符合当前
低速状态。恢复 27 MHz 同时会改变 MIPI 速率，不能沿用 5 ns 当作新时序约束。

实测对照（pcie-video-report.x4c9d2i1.zip）：

- raw headless 输出平均 26.669 FPS；显示开启后 26.666 FPS。
- FPGA 打包末端帧计数约 26.7 FPS；普通模式 raw gate/drop、CAM_FIFO_DROPS 为零。
- 0x88 不是传感器 XVS：来自 pack4 模块被接受的 m_frame_last，低 24 位计数。
  因而它只能独立排除显示限速，不能仅凭这个计数排除 MIPI/ISP 在更前级丢帧。
- 时钟配置错误与实测比例一致，把“60FPS 数据被 KMS/YOLO 限制为27FPS”列为
  当前主因已没有依据。仍需源侧分级计数/时钟实测完成物理层闭环。

## 4. 为 60 FPS 修复准备的变更边界

1. 统一传感器输入时钟与配置表。模式 0 的直接候选是稳定、合法的 27 MHz，
   可由 TD PLL/IP 工具生成独立输出，再按器件允许的时钟输出结构送到 cam_mclk。
   现有 1200 MHz VCO 整数分频不能直接得到 27 MHz，不能把 DIV=50 随意改成44
   冒充27 MHz。I2C 当前使用 cam_24m，PHY 参考使用150 MHz，需保持或重新核算。
2. 不能只删 toggle：这只能将 12 MHz 变成24 MHz，仍不匹配27 MHz表；若其余
   时序线性跟随，推算也仅约53.34 FPS。不能用 `--set-parm=60` 修复 FPGA 时钟。
3. 不能承诺“换27 MHz必然稳定60”：手册第59页的标准4-lane binning表在
   891 Mbps列为30 FPS、MDBIT=1；当前工程使用 MDBIT=0（RAW10）、不同HMAX/VMAX。
   需验证这组定制RAW10模式的行长度、总行数、帧尾与最高速率，或选择正式支持的
   60 FPS模式并相应调整接收器。直接复制 RAW12 配置给 RAW10 unpacker 不成立。
4. 4K 模式使用另一组24 MHz时钟参数（B4/FC、SYS_MODE=8），新MCLK必须同步
   处理这张表或明确暂不启用该模式；不能把所有模式无条件变成27 MHz。
5. 验证新的 MIPI D-PHY/CSI 时钟、采样、自动延时校准、约束及跨时钟域。
   27 MHz/891 Mbps候选的 clock lane 名义445.5 MHz，对应约2.245 ns；其余模式
   使用各自速率。不要盲目提高PCIe user_clk；v26原有负时序裕量仍需处理。

建议用于板端闭环的只读诊断：

- CSI Frame Start（HS域事件，计数后可靠CDC）、MIPI转AXI SOF握手、裁剪后SOF、
  ISP后SOF、预处理后SOF、打包后EOF分别计数；不把多位异步计数直接2FF同步。
- 基于已知参考时钟测 MCLK 与源帧周期，使用独立复位/有效标志，避免第一次周期
  从复位开始计时；同时记录I2C配置完成/NACK、行数和有效像素数。
- 先运行无压缩、无YOLO、无显示采集，验证前级真正输出约60帧，再验证DMA和显示。
  1080p60 RGB24像素负载373.248 MB/s，当前27 FPS成功不证明后级已能承受60 FPS。

下载修复位流后的验收：时钟与模式匹配、采集帧率约60、完整图像尺寸正确、无帧内
损坏/超时、分级计数一致，再分别评估显示与YOLO/LZ77。实际MCLK/CSI测量和新位流
A/B属于待完成工作，不能把本次静态审计标成60 FPS已实现。

## 可复现审计

在原工程根目录执行：

```powershell
python uisrc/06_doc/audit_camera_clock.py --output uisrc/06_doc/camera_clock_audit_20261010.json
```

脚本从生成PLL参数、IPC、实际顶层toggle、模式寄存器表计算，不依赖“60fps”注释。
它不访问设备、不编译位流、不改变deploy。若顶层时钟结构改变，它会要求重新审查
模型，避免把旧推算套到新实现上。JSON保留源码哈希及明确的推算/非实测标记。
