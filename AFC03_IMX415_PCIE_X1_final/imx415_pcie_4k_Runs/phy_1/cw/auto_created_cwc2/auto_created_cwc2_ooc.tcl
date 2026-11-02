import_device ph1_90.db -package PH1A90SEG324
set_param flow ooc_flow on
read_verilog -file "auto_created_cwc2_watcherInst.sv"
optimize_rtl
map_macro
map
pack
report_area -file auto_created_cwc2_gate.area
export_db -mode ooc "auto_created_cwc2_ooc.db"
