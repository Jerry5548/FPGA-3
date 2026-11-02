#!/bin/sh
# Read the compression-path diagnostics added for the LZ77 C2H investigation.
set -eu
BAR0=${1:-0x21200000}
read_reg() { busybox devmem "$((BAR0 + $1))" 32; }
echo "VERSION       $(read_reg 0x5c)"
echo "CAM_FRAME     $(read_reg 0x88)"
echo "COMP_MODE     $(read_reg 0xa8)"
echo "COMP_RAW      $(read_reg 0xac)"
echo "COMP_BYTES    $(read_reg 0xb0)"
echo "COMP_TOKENS   $(read_reg 0xb4)"
echo "COMP_FRAMES   $(read_reg 0xb8)"
echo "COMP_ERRORS   $(read_reg 0xbc)"
echo "COMP_STATUS   $(read_reg 0xc0)"
echo "COMP_VALID    $(read_reg 0xc4)"
VERSION=$(read_reg 0x5c)
if [ "$((VERSION))" -ge "$((0x56440022))" ]; then
    echo "CAM_FIFO_DROPS $(read_reg 0xc8)"
fi
if [ "$((VERSION))" -eq "$((0x56440026))" ] || [ "$((VERSION))" -eq "$((0x56440027))" ] || [ "$((VERSION))" -eq "$((0x56440028))" ] || [ "$((VERSION))" -eq "$((0x56440029))" ] || [ "$((VERSION))" -eq "$((0x56440030))" ] || [ "$((VERSION))" -eq "$((0x56440031))" ] || [ "$((VERSION))" -eq "$((0x56440032))" ]; then
    for OFF in 0x100 0x104 0x108 0x10c 0x110 0x114 0x118 0x11c; do
        printf 'BAR0+%s=%s\n' "$OFF" "$(read_reg "$OFF")"
    done
fi
if [ "$((VERSION))" -ge "$((0x56440024))" ]; then
    echo "DDR_STARTUP_SKIPS $(read_reg 0xf0)"
fi
if [ "$((VERSION))" -ge "$((0x56440025))" ]; then
    echo "PRE_MEDIAN_ERRORS $(read_reg 0xf4)"
    echo "PRE_SOBEL_ERRORS  $(read_reg 0xf8)"
fi
if [ "$((VERSION))" -ge "$((0x56440023))" ]; then
    echo "DDR_STATUS    $(read_reg 0xcc)"
    echo "DDR_PUBLISHED $(read_reg 0xd0)"
    echo "DDR_NO_SLOT   $(read_reg 0xd4)"
    echo "DDR_INVALID   $(read_reg 0xd8)"
    echo "DDR_WRITE_ERR $(read_reg 0xdc)"
    echo "DDR_READ_ERR  $(read_reg 0xe0)"
    echo "DDR_CAP_DROPS $(read_reg 0xe4)"
    echo "DDR_REPLAYED  $(read_reg 0xe8)"
    echo "DDR_STATE     $(read_reg 0xec)"
fi

if [ "$((VERSION))" -eq "$((0x56440030))" ] || [ "$((VERSION))" -eq "$((0x56440031))" ] || [ "$((VERSION))" -eq "$((0x56440032))" ]; then
    echo "PRE_DEHAZE_ERRORS $(read_reg 0x120)"
fi
