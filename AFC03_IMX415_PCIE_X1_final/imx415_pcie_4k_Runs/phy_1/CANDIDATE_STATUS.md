# Candidate status, updated 2026-10-14

## v27 built and packaged

Source now reports 0x56440027 and fixes PH1A MIPI delay enable, scan range,
and full-window length counting. RTL/vendor-delay regression, synthesis,
place/route and explicit v27 bitgen completed on October 14.
Final routed setup WNS +0.412 ns, hold WNS +0.020 ns; zero failing endpoints.
USR-6144 and coverage/interface warnings remain; board validation pending.
The latest final_timing.rpt/phy.ts and mipi_v27_* console logs describe v27.
Named v27 output: imx415_pcie_4k_mipi_v27.bit.
Checked package: ../debug_release_mipi_v27_20261014.zip.
See ../../uisrc/06_doc/mipi_v27_fix_20261014.md.

## Previous v26 PCIe candidate, 17:01

The user regenerated PCIe IP and reran synthesis/place/route/bitgen.
The archived earlier timing and GUI run.log (2026-10-14 ~17:01) report:
setup WNS +0.075 ns, hold WNS +0.020 ns; zero failing endpoints.
Two USR-6144 warnings persist (62.5 MHz requested / 125 MHz derived).
Default imx415_pcie_4k.bit and imx415_pcie_4k_compress.bit were generated
by that earlier run and remain v26. User board tests subsequently found
zero continuous frames; use the explicit v27 filename for the new candidate. See
../../uisrc/06_doc/pcie_regenerated_build_review_20261014.md.

## Historical checkpoint, 2026-10-11

The October 11 reviewed routed timing is in `reset_review_*`:
setup WNS +0.318 ns, hold WNS +0.020 ns; zero failing endpoints.
PCIe dynamic-clock/coverage warnings still require review.

NO BITSTREAM was generated for that October 11 reviewed checkpoint.
Earlier failing candidates are archived in `timing_fail_20261011_1745` and
`timing_fail_20261011_1944`. They are not the v26 rollback.

Rollback release:
`D:/FPGA/AFC03_IMX415_PCIE_X1_test2/IMX415_PCIE_X1/imx415_pcie_4k_Runs/debug_release_ddr_v26_20261009`

Full change/validation report: `../../uisrc/06_doc/timing_improvement_20261011.md`.
