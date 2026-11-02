# Run from imx415_pcie_4k_Runs/syn_1. Check scope before placement as well.
import_device ph1_90.db -package PH1A90SEG324 -speed 2
open_project imx415_pcie_4k.prj -noanalyze
import_db imx415_pcie_4k_gate.db
clear_user_sdc
read_sdc ../../uisrc/04_pin/imx415_pcie.sdc
update_timing
report_timing_status -file reset_scope_gate.ts
check_timing -file reset_scope_gate_check.timing
export_sdc -file reset_scope_gate.sdc
exit
