# Run in original phy_1 only after routed timing has been reviewed.
import_device ph1_90.db -package PH1A90SEG324 -speed 2
open_project imx415_pcie_4k.prj -noanalyze
import_db imx415_pcie_4k_pr.db
bitgen -bit imx415_pcie_4k_mipi_v27.bit
exit
