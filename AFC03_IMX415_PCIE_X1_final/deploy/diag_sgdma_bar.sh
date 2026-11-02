#!/bin/sh
# Inspect the register identifiers used by the Anlogic SGDMA driver.
set -eu
BDF=${1:-$(lspci -d 1edb:abcd 2>/dev/null | awk 'NR==1 {print $1}')}
[ -n "$BDF" ] || { echo "FPGA endpoint not found" >&2; exit 1; }
RES=/sys/bus/pci/devices/0000:${BDF}/resource
BAR0=$(awk 'NR==1 {print $1}' "$RES")
BAR1=$(awk 'NR==2 {print $1}' "$RES")
echo "BDF=$BDF BAR0=$BAR0 BAR1=$BAR1"
for b in "$BAR0" "$BAR1"; do
    [ "$b" != "0x0000000000000000" ] || continue
    echo "BAR $b:"
    echo "  IRQ identifier    +0x2000: $(busybox devmem $((b+0x2000)) 32 2>/dev/null || true)"
    echo "  CONFIG identifier +0x3000: $(busybox devmem $((b+0x3000)) 32 2>/dev/null || true)"
done
echo "Expected upper IDs: IRQ=0x1fc2xxxx, CONFIG=0x1fc3xxxx"
