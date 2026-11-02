# Run from imx415_pcie_4k_Runs/phy_1. Read-only query of the routed candidate.
import_device ph1_90.db -package PH1A90SEG324 -speed 2
open_project imx415_pcie_4k.prj -noanalyze
import_db imx415_pcie_4k_pr.db
foreach pattern {{u_pcie_ddr/controller_rst_n} {u_pcie_ddr/controller_rst_n*} {u_pcie_ddr/path/dr/sync[*]} {u_pcie_ddr/path/dr/sync*}} {
    puts "RESET_QUERY $pattern -> [get_regs $pattern]"
}
puts "RESET_PINS [get_pins {u_pcie_ddr/path/dr/sync*.asr}]"
help get_regs
help set_false_path
exit
