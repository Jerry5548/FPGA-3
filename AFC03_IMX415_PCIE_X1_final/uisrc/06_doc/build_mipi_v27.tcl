# Run from original syn_1, then phy_1. phy settings stop before bitgen.
if {[catch {source D:/TD_Release_2026.1_SP2.200.067/scripts/DefaultFlow.tcl} msg]} {
    puts $msg
    exit 1
}
exit
