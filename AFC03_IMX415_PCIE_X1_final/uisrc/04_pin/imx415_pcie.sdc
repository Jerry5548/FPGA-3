## ============================================================

## SDC for IMX415 Camera + PCIe (PH1A90SEG324 migration)

## PH1A90SEG324-2, PCIe Gen2 x1

## Clock domains: sys_clk, sgdma_pll, ui_pll, PCIe, MIPI HS

## ============================================================



## 25MHz system clock (T16) 锟斤拷 drives sgdma_pll only

create_clock -name sys_clk -period 40 -waveform {0 20} [get_ports {sys_clk}]



## MIPI HS clock: 445.5MHz (DDR 891Mbps/lane for 4-lane RAW10/binning)

## This is the recovered clock from the MIPI CSI-2 clock lane

create_clock -name mipi_hs_clk -period 2.244669 [get_ports {mipi_clk_hs_rx_p}]



## Let TD auto-derive all internal clocks (PLL outputs, etc.)

create_clock -name board_ref_100m -period 10 -waveform {0 5} [get_ports {mipi_ref_clk_p}]
derive_clocks



## ============================================================

## Async clock groups

## Clock families (related clocks stay in the same group):

##   1. sgdma_pll outputs (core_clk 125MHz, app_auxclk 25MHz)

##   2. board_ref_100m, DDR dfi_clk, UI PLL C0=150MHz / C2=54MHz

##      NOTE: clkc[1] (cam_100m) is reserved/unused, optimized out by TD

##   3. PCIe internal clocks (pcie_user_clk + core_clk from al_pcie_ip.sdc)

##   sys_clk is the 25MHz SGDMA PLL reference; no datapath is clocked by it.

##   4. MIPI HS clock and its derived clocks (recovered from camera)

##   The unused UI PLL C1=90MHz output is optimized out.

## ============================================================

# DDR and camera PLLs share mipi_ref_clk_p; keep them with their reference
# clock in one synchronous group. PCIe/SGDMA and recovered MIPI HS remain
# independent domains and cross through their CDC FIFOs or synchronizers.
set ref_domain_clks [get_clocks {board_ref_100m u_ui_pll/pll_inst.clkc[0] u_ui_pll/pll_inst.clkc[2] *dfi_clk}]
set core_clks [get_clocks {u_sgdma_pll/pll_inst.clkc[0] u_sgdma_pll/pll_inst.clkc[1]}]
set pcie_clks [get_clocks {*pcie_user_clk *core_clk}]
set hs_clks [get_clocks {mipi_hs_clk u_cam_video_source/u_mipi_csi_rx/u_csi_rx_phy/u_rx_clk_gen/U_io_clk_div_0.clkout u_cam_video_source/u_mipi_csi_rx/u_csi_rx_phy/u_rx_clk_gen/U_io_clk_div_1.clkdivout}]
set groups {}
foreach clocks [list $ref_domain_clks $core_clks $pcie_clks $hs_clks] { if {[llength $clocks] > 0} { lappend groups -group $clocks } }
if {[llength $groups] > 2} { eval set_clock_groups -asynchronous $groups }

# BEGIN DDR_RESET_ENTRY_EXCEPTION
# frame_reset_sync has four serial DFFs: async assertion, four-clock release.
# controller_rst_n reaches ONLY the ASYNC reset inputs of this chain.
# Exempt this source/destination pair, NOT the D-input stage-to-stage paths
# or the synchronized drst_n output feeding the DDR datapath.
set ddr_reset_source [get_regs {u_pcie_ddr/controller_rst_n}]
set ddr_reset_chain [get_regs {u_pcie_ddr/path/dr/sync[*]}]
if {[llength $ddr_reset_source] != 1 || [llength $ddr_reset_chain] != 4} { error "DDR reset exception must resolve to one source and four synchronizer registers" }
set_false_path -from [get_regs {u_pcie_ddr/controller_rst_n}] -to [get_regs {u_pcie_ddr/path/dr/sync[*]}]
# END DDR_RESET_ENTRY_EXCEPTION
