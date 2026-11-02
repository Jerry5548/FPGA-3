# PCIe 62.5/125 MHz 核验（2026-10-14）

## 结论

工程配置为 PH1A90、x1、Gen2：

- `al_ip/PH1_LOGIC_PCIE.ipc`：`PCIE_GEN=Gen2`、`LINK_SPEED_GENERATION=Gen2`。
- `al_ip/PH1_LOGIC_PCIE.sdc`：`core_clk` 为 8 ns，`pcie_user_clk` 由其 1:1 派生。
- routed STA：`core_clk=125.000 MHz`、`pcie_user_clk=125.000 MHz`。

因此，当前用户逻辑的 125 MHz 约束是正确的；不能把它改成 62.5 MHz。

## 告警来源

生成的 `al_ip/PH1_LOGIC_PCIE_ph1_pcie_core_pll.v` 第 67 行固定有：

```verilog
.FIN("62.500"),
```

其输入来自 `al_pcie_ip_ph1_clock_ctrl.v` 的 `core_clk_sclk`。同一个时钟控制模块
包含 Gen1、Gen2、Gen3 的 DRP 配置表，并在链路训练后根据协商结果切换 PLL。
因此 TD 在重新分析时打印：requested 62.5 MHz / actual 125 MHz（USR-6144）。
这个 62.5 MHz 来自 PCIe IP 生成模板的 FIN/Gen1 元数据，不是顶层 SDC 把用户
逻辑误约束为 62.5 MHz。

## 已做的核验

1. 从 `.ipc`、`.sdc`、生成的 PLL 和动态 DRP 表逐项检查频率来源。
2. 综合后数据库与布线数据库均读取完整 SDC；PCIe 两个时钟均为 125 MHz。
3. 布线复查：setup WNS +0.318 ns、hold WNS +0.020 ns、违例端点为 0。
4. 没有直接把 `.FIN` 改成 125、没有删除告警、没有用 false path 掩盖它。

## 是否已经修正

Gen2 SDC 侧频率一致；IP 告警尚未消除。当前安装版本的厂商 PLL 模板也固定
使用 `.FIN("62.500")`，所以重新生成 Gen2 x1 是版本一致性核验步骤，不能保证
消除 USR-6144。须比较新生成的 core PLL、DRP 表、`.ipc`、`.sdc` 和综合日志。
告警 Actual frequency 是 TD 推导结果，不是板上实测。Gen1 降速场景及动态 PLL
相关签核仍需检查，不能仅凭 Gen2 配置或一次 STA 通过宣称硬件时钟已核验完毕。
没有证据支持直接修改 `.FIN` 或动态配置表来消除告警。

重新生成前后应检查：

```powershell
Select-String -Path al_ip/PH1_LOGIC_PCIE.ipc -Pattern 'PCIE_GEN|LINK_SPEED_GENERATION|REF_CLK_FREQ|AUX_CLK_FREQ'
Select-String -Path al_ip/PH1_LOGIC_PCIE.sdc -Pattern 'create_clock|core_clk|pcie_user_clk|period'
Select-String -Path al_ip/PH1_LOGIC_PCIE_ph1_pcie_core_pll.v -Pattern 'FIN|REFCLK_DIV|FBCLK_DIV|CLKC0_DIV'
Select-String -Path imx415_pcie_4k_Runs/phy_1/td_*.log -Pattern 'USR-6144|Requested frequency|Actual frequency'
```

任何 IP 重生成必须在原工程进行，并先复制当前 `al_ip`、`uisrc/03_ip/sgdma`
和 `.al` 工程文件作为可回退快照；`AFC03_IMX415_PCIE_X1_test2` 的 v26
发布目录不修改。

## 用户重生成后的实际比较（2026-10-14）

已读取生成前备份 `ip_regeneration_snapshots/20261014_163513_190025` 与
生成后的四文件差异，结果如下：

- `.ipc` 完全相同，参数变化为 0。
- core PLL `.v` 仅文件头版权、路径、日期、TD 版本发生变化；
  `.FIN("62.500")`、分频与占空比参数均未变化。
- clock_ctrl `.v` 有功能变化：增加 6 位 `smlh_ltssm_state` 输入与 aux
  域采样；WAIT_LINK 计数条件增加 `smlh_ltssm_state_aux == 6'h11`；
  非仿真等待时间从 10 ms 改为 30 ms；WAIT_DBI 清除 user_link_aux；
  DONE 在 pll_ready 失效时返回 WAIT_DBI，旧版为 JUDGE。
  源码标注该修改关联 `ipdev-1903`。Gen1/2/3 DRP 表赋值完全相同。
- SDC core_clk 周期仍为 8 ns，派生 user 时钟参数未变；新增
  `smlh_ltssm_state_aux[*]` 的厂商跨域入口 false-path。
- 主生成文件 `PH1_LOGIC_PCIE.v` 将新增状态输入连接到
  `smlh_ltssm_state` 信号，未见该输入悬空；不能据此替代跨域或硬件验证。

因此这次重生成确实取得新版链路状态处理逻辑，但没有改变 62.5/125 MHz
关系。不能沿用 10 月 11 日的布线结果给新逻辑签核，也不能认定 USR-6144
已消失；需要重新综合、布局布线并检查新日志。尚未验证新逻辑在板上的效果。
比较工具最后一句是固定说明文本，不是新日志的告警检测结果。
