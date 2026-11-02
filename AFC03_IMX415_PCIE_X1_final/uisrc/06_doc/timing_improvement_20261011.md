# 1080p 时钟与数据通路时序改进（2026-10-11）

本次在原工程 `imx415_pcie_4k.al` 上修改，未创建 fix 工程。
当前布线数据库按完整工程 SDC 复查后，已分析路径 setup/hold 均通过。
这是时序候选检查点，未生成与本次结果对应的新 bit，未烧录、未实测新帧率。

## 修改内容

- UI PLL C0/C1/C2 = 150/90/54 MHz；顶层 MCLK 由 C2 二分频得到 27 MHz。
  I²C 分频为 539，复位默认摄像头模式为 0（1080p）。
  RAW10、2×2 binning 表的 HMAX=542、VMAX=2283，计算帧率约 60.0055 FPS；
  该数值是配置计算结果，不是传感器或显示实测。4K 模式未纳入本次验收。
- 直方图均衡化：去掉深组合除法，改为每 bin 35 周期的精确逐位除法，
  256 bins 共 8960 周期。保留前一帧 LUT、平滑与首帧直通行为；
  帧间空闲时间需覆盖 LUT 更新。
- 中值滤波：九级奇偶交换排序流水线，四个像素通道并行，保持每拍四像素。
  新增九拍延迟并同步传递帧/行标记，保留边界像素复制。
- DDR 状态读回：增加复位、校准错误与阶段状态的两级同步。
  多位校准诊断值在稳定后可读；这不是校准过程中的原子多位握手机制。
- 时钟分组：共用板上 100 MHz 参考的 UI/DDR 时钟保留相关性；PCIe/SGDMA、
  摄像头恢复时钟按各自时钟族分组。
- 复位入口例外：仅 `u_pcie_ddr/controller_rst_n` 到
  `u_pcie_ddr/path/dr/sync[*]` 四级复位同步器。该源在此处只连接异步复位入口。
  同步器级间数据、`drst_n` 输出到 DDR 数据通路仍接受时序检查。
  SDC 检查必须匹配一个源寄存器与四个同步寄存器，否则报错。

TD 的约束须经 `read_sdc` 加载，在 `start_timer` 时应用；在普通 Tcl 中
`eval` 相同片段未产生有效时序例外。SDC 内 Tcl 检查写在一行，避免 TD 的
逐行读取导致 `missing close-brace`。本次最终复查使用完整 SDC，而非只叠加片段。
另外对综合后数据库执行 `check_reset_sdc_gate.tcl`，确认相同范围检查在布局前也能
解析，无效约束为 0；其综合阶段估算 WNS −0.700 ns 不替代最终布线 +0.318 ns。

## 时序量化

| 检查点 | Setup WNS | Setup TNS | Hold WNS | Hold TNS |
|---|---:|---:|---:|---:|
| 本次改动前备份 | −23.263 ns | −14823.741 ns | −1.345 ns | 见备份报告 |
| 流水线、CDC、时钟分组修正后，复位入口例外前 | −0.709 ns | −1.418 ns | +0.020 ns | 0 |
| 完整 SDC 复查后 | **+0.318 ns** | **0** | **+0.020 ns** | **0** |

最终 setup/hold 违例端点均为 0。例外前仅余两个异步复位 recovery 端点。
同步器内部三条级间路径独立检查：setup 最差 +6.742 ns、hold +0.147 ns。
同步后复位输出的报告仍列出受检查路径，所列最差 setup +2.049 ns、hold +0.157 ns。
检查 fast/slow 双角，STA coverage 99.48%。Hold 裕量较小，重新布局布线后必须重查。

最终报告位于 `imx415_pcie_4k_Runs/phy_1/`：

- `reset_review_phy.ts`、`reset_review_final.timing`、`reset_review_flow.status`
- `reset_review_chain.timing`、`reset_review_release.timing`
- `reset_review_check.timing`、`reset_review_export.sdc`
- `reset_review_pr.db` 为带本次约束的布线数据库；原 `imx415_pcie_4k_pr.db`
  保留例外前状态。不要用旧 `final_timing.rpt` 替代本次复查报告。

从 `phy_1` 目录复查：

```powershell
& 'D:/TD_Release_2026.1_SP2.200.067/bin/td_commands_prompt.exe' ../../uisrc/06_doc/recheck_reset_timing.tcl
```

## 最终物理资源

| 资源 | 使用 / 总量 | 占用 |
|---|---:|---:|
| LUT6 | 30280 / 64320 | 47.08% |
| FF | 40768 / 128640 | 31.69% |
| Slice | 38112 / 64320 | 59.25% |
| ERAM20K | 195 / 272 | 71.69% |
| DSP | 62 / 240 | 25.83% |

来源：`imx415_pcie_4k_phy.area`。使用最终物理统计，不用中间 QoR 的打包估算代替。

## 已通过的功能验证

- `run_edge_port.ps1`：小图模式 0–6、有间隙、多帧；1080p 中值/Sobel 各两帧，逐像素及标记检查。
- `run_histogram_1080p.ps1`：三帧，精确比较前帧 LUT 结果，协议错误为 0。
- 除法算法 CDF=0…2073600 的 Python 穷举比对通过。
- `run_ddr_status.ps1`：异步时钟、三次重启、1021 个状态采样通过。
  DDR IP 用接口 stub，验证范围为外围状态同步，不代表真实 DDR 校准或亚稳态验证。

以上回归日志在 `uisrc/02_sim/edge_port` 与 `uisrc/02_sim/c2h_regression`。

## 尚未完成的签核与性能验证

- PCIe IP 的 `PH1_LOGIC_PCIE.ipc` 明确配置为 Gen2，官方时钟关系为
  Gen1=62.5 MHz、Gen2=125 MHz、Gen3=250 MHz；因此 62.5 MHz 是 IP
  的 Gen1 动态 PLL 表项/FIN 元数据，不是本设计 Gen2 用户时钟。
  `PH1_LOGIC_PCIE.sdc` 和顶层 SDC 均按 **125 MHz、8 ns 周期**约束，
  并已复查通过。`PH1_LOGIC_PCIE_ph1_pcie_clock_ctrl.v` 保留 Gen1/2/3
  DRP 表，链路训练后按协商结果切换。TD 仍打印 USR-6144，因为生成的
  `PH1_LOGIC_PCIE_ph1_pcie_core_pll.v` 固定 `.FIN("62.500")`，这属于
  IP 生成器元数据与动态 PLL 的实现告警；仅改 SDC 无法修正它。
  不应把 `.FIN` 直接改成 125，也不能删告警或用 false path 掩盖。若要
  核验版本一致性，可在 TD 中重新生成 Gen2 IP 并比较 core PLL、DRP 表与 SDC。
  当前安装版的厂商模板也固定 FIN=62.500，因此重生成并不保证消除告警。
  Actual frequency 是工具推导值，并非板上测量；动态时钟与 Gen1 降速签核仍待完成。
- `check_timing` 仍列 no-clock 6、dummy-node 4、PLL/clock 2，以及输入/输出延时问题。
  无效约束、组合环、被忽略/遮蔽例外均为 0。需区分复位/状态伪时钟和真正的外部接口约束。
- 板上需确认连接器 MCLK=27 MHz、MIPI/ISP 源帧率约 60 FPS、无错误增长，
  再比较 raw、LZ77、YOLO、两者同时开启的有效新帧 FPS 与端到端延迟。
- 此次没有加宽 LZ77 编码器，也没有修改 YOLO 推理链路；不能据此宣称组合模式
  达到 20–30 FPS。后续需处理逐字节压缩吞吐、DMA 调度和显示/推理排队。

## 候选与 v26 回退

独立回退目录：`D:/FPGA/AFC03_IMX415_PCIE_X1_test2/IMX415_PCIE_X1`。
其 `imx415_pcie_4k_Runs/debug_release_ddr_v26_20261009/SHA256SUMS` 的
239 项全部校验匹配，本次未修改此目录。该历史版本用于回退，不意味着其旧时序已通过。

原工程中旧失败 bit 已归档到 `phy_1/timing_fail_20261011_1745` 与
`phy_1/timing_fail_20261011_1944`，不能与本次通过的布线数据库混用。
当前 RTL 的版本寄存器仍为 `0x56440026`，候选不是独立发布的新版本；
后续正式打包须分配新版本、重新构建并记录 bit 哈希，避免只靠版本寄存器辨认。
本次保留报告和源文件检查点，不提供新烧录命令。
