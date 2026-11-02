#!/bin/bash
# pcie1_rebind.sh — RK3576 pcie1 late rebind for FPGA EP boot timing
# Problem: FPGA EP not ready when rk-pcie driver probes at boot
# Solution: Wait for FPGA, then rebind pcie1 controller
set -e

PCIE1_DEV="2a210000.pcie"
DRIVER_PATH="/sys/bus/platform/drivers/rk-pcie"
MAX_WAIT=10    # seconds to wait for FPGA readiness

log() { echo "[pcie1-rebind] $*"; }

# Check if pcie1 device already enumerated
if lspci 2>/dev/null | grep -q "21:00.0"; then
    log "pcie1 device already enumerated, nothing to do"
    exit 0
fi

log "Waiting ${MAX_WAIT}s for FPGA EP to stabilize..."
sleep "$MAX_WAIT"

# Unbind if currently bound (failed state)
if [ -e "${DRIVER_PATH}/${PCIE1_DEV}" ]; then
    log "Unbinding ${PCIE1_DEV}..."
    echo "$PCIE1_DEV" > "${DRIVER_PATH}/unbind" 2>/dev/null || true
    sleep 1
fi

# Rebind
log "Binding ${PCIE1_DEV}..."
echo "$PCIE1_DEV" > "${DRIVER_PATH}/bind"
sleep 2

# Verify
if lspci 2>/dev/null | grep -q "21:00.0"; then
    log "SUCCESS — FPGA EP detected:"
    lspci -s 21:00.0
    # Enable Memory + BusMaster
    setpci -s 21:00.0 COMMAND=0x06 2>/dev/null || true
    log "Memory + BusMaster enabled"
else
    log "FAILED — FPGA EP not detected after rebind"
    dmesg | grep -i "2a210000.*pcie" | tail -5
    exit 1
fi
