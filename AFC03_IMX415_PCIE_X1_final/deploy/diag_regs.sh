#!/bin/bash
# diag_regs.sh — Read all FPGA debug registers
BAR0=0xf0200000
echo "=== FPGA Register Dump ==="
echo "VERSION    (0x5C): $(busybox devmem $((BAR0+0x5C)))"
echo "CTRL       (0x60): $(busybox devmem $((BAR0+0x60)))"
echo "PADDED_BYT (0x64): $(busybox devmem $((BAR0+0x64)))"
echo "FRAME_CNT  (0x68): $(busybox devmem $((BAR0+0x68)))"
echo "DBG_0x6C   (0x6C): $(busybox devmem $((BAR0+0x6C)))"
echo "DBG_0x70   (0x70): $(busybox devmem $((BAR0+0x70)))"
echo "DBG_0x74   (0x74): $(busybox devmem $((BAR0+0x74)))"
echo "DBG_0x78   (0x78): $(busybox devmem $((BAR0+0x78)))"
echo "DBG_0x7C   (0x7C): $(busybox devmem $((BAR0+0x7C)))"
echo "SOURCE_SEL (0x80): $(busybox devmem $((BAR0+0x80)))"
echo "CAM_STATUS (0x84): $(busybox devmem $((BAR0+0x84)))"
echo "CAM_MODE   (0x90): $(busybox devmem $((BAR0+0x90)))"
echo "AE_GAIN    (0x98): $(busybox devmem $((BAR0+0x98)))"
echo ""
echo "=== DMA Engine Status ==="
BAR1=0xf0400000
echo "H2C0_CTRL  : $(busybox devmem $((BAR1+0x0004)))"
echo "H2C0_STATUS: $(busybox devmem $((BAR1+0x0040)))"
echo "C2H0_CTRL  : $(busybox devmem $((BAR1+0x1004)))"
echo "C2H0_STATUS: $(busybox devmem $((BAR1+0x1040)))"
echo ""
echo "=== dmesg (last 20) ==="
dmesg | tail -20
