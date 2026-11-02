#!/bin/sh
# Runtime control for the PCIe camera pipeline.
# Usage: ./mode_control.sh [BAR0] [preprocess_mode] [compress_mode]
# Current lab BAR0 is commonly 0xf0200000; verify with lspci/resource first.
set -eu
BAR0=${1:-${BAR0:-}}
PRE=${2:-0}
COMP=${3:-0}
# Modes 5=gray+median and 6=gray+Sobel require v25 or newer; 7 remains reserved.
case "$PRE" in
    0|1|2|3|4|5|6|8|9) ;;
    7) echo "preprocess mode 7 is reserved (not implemented)" >&2; exit 2;;
    *) echo "preprocess mode must be 0..6, 8, 9; mode 7 reserved" >&2; exit 2;;
esac
case "$COMP" in 0|1) ;; *) echo "compress mode must be 0 or 1" >&2; exit 2;; esac
if [ -z "$BAR0" ]; then
    BDF=$(lspci -d 1edb:abcd 2>/dev/null | awk 'NR==1 {print $1}')
    [ -z "$BDF" ] && { echo "FPGA PCIe endpoint 1edb:abcd not found" >&2; exit 1; }
    BAR0=$(awk 'NR==1 {print $1}' "/sys/bus/pci/devices/0000:${BDF}/resource")
fi
case "$BAR0" in 0x*) ;; *) BAR0=$(printf '0x%x' "$BAR0");; esac
hexoff() { printf '0x%x' $(( $1 + $2 )); }
PRE_ADDR=$(hexoff "$BAR0" 0xa4)
COMP_ADDR=$(hexoff "$BAR0" 0xa8)
VERSION=$(busybox devmem "$(hexoff "$BAR0" 0x5c)" 32)
if [ "$PRE" -ge 5 ]; then
    if [ "$((VERSION))" -lt "$((0x56440025))" ] || [ "$((VERSION >> 16))" -ne "$((0x5644))" ]; then
        echo "Modes 5/6 require FPGA v25 or newer, got $VERSION" >&2; exit 1
    fi
fi
if [ "$PRE" -eq 8 ] || [ "$PRE" -eq 9 ]; then
    [ "$((VERSION))" -eq "$((0x56440030))" ] || [ "$((VERSION))" -eq "$((0x56440031))" ] || [ "$((VERSION))" -eq "$((0x56440032))" ] || {
        echo "Modes 8/9 require FPGA v30/v31/v32, got $VERSION" >&2; exit 1;
    }
fi
# Camera helpers explicitly select camera on v31. Never switch a running host.
if [ "$((VERSION))" -eq "$((0x56440031))" ] || [ "$((VERSION))" -eq "$((0x56440032))" ]; then
    SOURCE=$(busybox devmem "$(hexoff "$BAR0" 0x80)" 32)
    if [ "$((SOURCE))" -ne 1 ]; then
        CTRL=$(busybox devmem "$(hexoff "$BAR0" 0x60)" 32)
        [ "$((CTRL & 1))" -eq 0 ] || { echo 'Stop host playback before selecting camera' >&2; exit 1; }
        busybox devmem "$(hexoff "$BAR0" 0x80)" 32 1
        busybox devmem "$(hexoff "$BAR0" 0x60)" 32 2
        SOURCE=$(busybox devmem "$(hexoff "$BAR0" 0x80)" 32)
        [ "$((SOURCE))" -eq 1 ] || { echo 'Camera source readback failed' >&2; exit 1; }
    fi
fi
busybox devmem "$PRE_ADDR" 32 "$PRE"
busybox devmem "$COMP_ADDR" 32 "$COMP"
PRE_READ=$(busybox devmem "$PRE_ADDR" 32)
COMP_READ=$(busybox devmem "$COMP_ADDR" 32)
case "$PRE_READ $COMP_READ" in
    *0xFFFFFFFF*) echo "ERROR: FPGA user registers are unreadable (BAR0=$BAR0). Check SGDMA probe/bitstream." >&2; exit 1;;
esac
[ "$((PRE_READ))" -eq "$PRE" ] && [ "$((COMP_READ))" -eq "$COMP" ] || {
    echo "Mode readback mismatch: preprocess=$PRE_READ compress=$COMP_READ" >&2; exit 1;
}
echo "BAR0=$BAR0 preprocess=$PRE_READ compress=$COMP_READ"
