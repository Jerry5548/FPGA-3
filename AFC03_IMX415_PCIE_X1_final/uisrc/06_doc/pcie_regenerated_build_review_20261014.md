# PCIe IP 重生成后构建检查：2026-10-14

检查的是原工程 syn_1 / phy_1 最新 run.log，而非 10 月 11 日的 reset_review 报告。
IP clock_ctrl 文件时间 16:39:32；综合结束 16:51:07；最终布线报告生成
17:00:50，bitgen 于 17:01:25 完成。综合日志明确读取重生成的 clock_ctrl 文件。

## 结论

- USR-6144 **仍存在**，phy_1/run.log 第 1930、1931 行分别对应 core_clk、pcie_user_clk：
  Requested 62.500 MHz / Actual 125.000 MHz。
- 此处 Actual 是 TD 推导频率，不是硬件测量；不能认定动态时钟签核完成。
- 已分析路径的最终 setup/hold 通过，fast/slow 双角检查，STA coverage 99.48%。

| 指标 | 本次结果 |
|---|---:|
| 全局 setup WNS / TNS | +0.075 ns / 0 |
| 全局 hold WNS / TNS | +0.020 ns / 0 |
| Setup / hold 违例端点 | 0 / 0 |
| PCIe user/core 约束频率 | 125 MHz / 125 MHz |
| PCIe user 时钟域 setup / hold WNS | +0.442 ns / +0.020 ns |

最紧 setup 路径位于 DDR dfi_clk 域：capture_fifo/ramread0_syn_203.clkb
到 capture_fifo/rgray_reg[6]_syn_2.imf，裕量 +0.075 ns。
它不是 PCIe 时钟频率失配路径。裕量较小，后续实现变更需重新检查。

## 尚存问题

check_timing：no-clock 6、dummy-node 类别 5、PLL/clock 2、no-input-delay 33、
no-output-delay 55、abnormal-input-delay 3；invalid constraint / combinational
loop / shadowed-or-ignored exception 均为 0。
日志另有 MIPI 混合时钟扇出、DDR BUFG 级联，以及 ISP valid_width 寄存器同时
描述异步 set/reset 的告警。本次时序通过不等于全部约束覆盖及 CDC/硬件检查通过。

## 文件

- `imx415_pcie_4k_Runs/phy_1/run.log`
- `imx415_pcie_4k_Runs/phy_1/final_timing.rpt`
- `imx415_pcie_4k_Runs/phy_1/imx415_pcie_4k_chk.timing`
- `imx415_pcie_4k_Runs/phy_1/route_flow.status`
- 新生成 `imx415_pcie_4k.bit` 与 `imx415_pcie_4k_compress.bit`，仅为候选，未由本次检查烧录。

本次只核对报告，不修改 IP/SDC、RTL 或 v26 回退。后续需明确动态 PLL 下
Gen1/Gen2 分场景约束与告警处理依据，再做板上链路速率、时钟和有效帧率测量。
