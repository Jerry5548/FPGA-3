# Run from imx415_pcie_4k_Runs/phy_1. Re-analyze the existing routed netlist
# with the precisely scoped reset-entry exception; do not generate a bitstream.
import_device ph1_90.db -package PH1A90SEG324 -speed 2
open_project imx415_pcie_4k.prj -noanalyze
import_db imx415_pcie_4k_pr.db
# TD applies timing constraints through read_sdc/start_timer, not Tcl eval.
# Replace USER constraints only; retain DDR/PCIe/ChipWatcher IP constraints.
clear_user_sdc
read_sdc ../../uisrc/04_pin/imx415_pcie.sdc
update_timing -mode final
report_timing_status -file reset_review_phy.ts
report_timing_summary -file reset_review_final.timing
report_timing_exception -file reset_review_exceptions.timing
check_timing -verbose -file reset_review_check.timing
flow_status -file reset_review_flow.status
report_abnormal_timing_target -file reset_review_abnormal.timing
report_timing_path -from [get_regs {u_pcie_ddr/path/dr/sync[*]}] -to [get_regs {u_pcie_ddr/path/dr/sync[*]}] -file reset_review_chain.timing
report_timing_path -from [get_regs {u_pcie_ddr/path/drst_n}] -file reset_review_release.timing
export_db reset_review_pr.db
export_sdc -file reset_review_export.sdc
exit
