
# frame_reset_sync has four serial DFFs: async assertion, four-clock release.
# controller_rst_n reaches ONLY the ASYNC reset inputs of this chain.
# Exempt this source/destination pair, NOT the D-input stage-to-stage paths
# or the synchronized drst_n output feeding the DDR datapath.
set ddr_reset_source [get_regs {u_pcie_ddr/controller_rst_n}]
set ddr_reset_chain [get_regs {u_pcie_ddr/path/dr/sync[*]}]
if {[llength $ddr_reset_source] != 1 || [llength $ddr_reset_chain] != 4} { error "DDR reset exception must resolve to one source and four synchronizer registers" }
set_false_path -from [get_regs {u_pcie_ddr/controller_rst_n}] -to [get_regs {u_pcie_ddr/path/dr/sync[*]}]

