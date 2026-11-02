#!/bin/bash
# Single-terminal diagnostic. Stop camera data before unloading/resetting DMA.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BAR0=${1:-0x21200000}
FRAMES=${2:-3}
PREPROCESS=${3:-4}
# Optional fourth argument: prefix for CRC-checked, decoded RGB24 .bin files.
# This is NOT --capture (which records compressed transport bytes).
OUTPUT_PREFIX=${4:-}
OUTPUT_ARGS=()
if [ -n "$OUTPUT_PREFIX" ]; then
    if [ "${#OUTPUT_PREFIX}" -gt 450 ]; then
        echo 'Output prefix too long for receiver filename buffer' >&2; exit 2
    fi
    mkdir -p -- "$(dirname -- "$OUTPUT_PREFIX")"
    OUTPUT_ARGS=(-o "$OUTPUT_PREFIX")
fi
case "$PREPROCESS" in
    0|1|2|3|4|5|6|8|9) ;;
    7) echo 'preprocess mode 7 is reserved (not implemented)' >&2; exit 2 ;;
    *) echo 'preprocess mode must be 0..6, 8, 9; mode 7 reserved' >&2; exit 2 ;;
esac
case "$FRAMES" in
    ''|*[!0-9]*|0) echo 'frame count must be a positive decimal integer' >&2; exit 2 ;;
esac
DEVICE=/dev/ANLOGIC-PCI0_c2h_0
RX="$SCRIPT_DIR/rk3576/rk3576_lz77_rx"
LOG_DIR=$(mktemp -d /tmp/lz77-diag.XXXXXX)
reg() { busybox devmem "$((BAR0 + $1))" 32 "${@:2}"; }
snapshot() {
    local off
    for off in 0x5c 0x60 0x84 0x88 0xa4 0xa8 0xac 0xb0 0xb4 0xb8 0xbc 0xc0 0xc4 0xc8 0xcc 0xd0 0xd4 0xd8 0xdc 0xe0 0xe4 0xe8 0xec 0xf0 0xf4 0xf8 0x100 0x104 0x108 0x10c 0x110 0x114 0x118 0x11c; do
        printf 'BAR0+%s=' "$off"
        reg "$off"
    done
    if [[ ( "$((VERSION))" == "$((0x56440030))" || "$((VERSION))" == "$((0x56440031))" || "$((VERSION))" == "$((0x56440032))" ) ]]; then
        printf 'BAR0+0x120='; reg 0x120
    fi
}
# Diagnostic register reads only: this monitor never opens the C2H device.
# Values within a sample are read sequentially, not an atomic snapshot.
monitor_ddr() {
    local sample=0
    while kill -0 "$RX_PID" 2>/dev/null; do
        printf 'sample=%s published=%s invalid=%s no_slot=%s cap_drops=%s startup_skips=%s\n' \
            "$sample" "$(reg 0xd0)" "$(reg 0xd8)" "$(reg 0xd4)" "$(reg 0xe4)" "$(reg 0xf0)"
        sample=$((sample + 1))
        sleep 0.1
    done
}
echo "Logs: $LOG_DIR"
echo "preprocess=$PREPROCESS frames=$FRAMES compress=1"
echo 'diagnostic=ddr-v26-first-rejection-20261009'
[ -c "$DEVICE" ] && [ -x "$RX" ] || { echo 'C2H device or receiver missing'; exit 1; }
# C2H userspace and V4L2 must be idle before resetting their producer.
if command -v fuser >/dev/null && fuser "$DEVICE" 2>/dev/null; then
    echo 'C2H device is in use; stop that receiver first'; exit 1
fi
if pgrep -x gst-launch-1.0 >/dev/null; then
    echo 'Stop the GStreamer display before this compression test'; exit 1
fi
VERSION=$(reg 0x5c)
[ "$((VERSION))" -eq "$((0x56440026))" ] || [ "$((VERSION))" -eq "$((0x56440027))" ] || [ "$((VERSION))" -eq "$((0x56440028))" ] || [ "$((VERSION))" -eq "$((0x56440029))" ] || [ "$((VERSION))" -eq "$((0x56440030))" ] || [ "$((VERSION))" -eq "$((0x56440031))" ] || [ "$((VERSION))" -eq "$((0x56440032))" ] || {
    echo "Expected DDR-frame FPGA v26/v27/v28/v29/v30/v31/v32, got $VERSION"; exit 1;
}
if [[ "$PREPROCESS" == 8 || "$PREPROCESS" == 9 ]]; then
    [[ ( "$((VERSION))" == "$((0x56440030))" || "$((VERSION))" == "$((0x56440031))" || "$((VERSION))" == "$((0x56440032))" ) ]] || { echo 'Modes 8/9 require FPGA v30/v31/v32'; exit 1; }
fi
"$RX" --version
reg 0x60 0
if (( VERSION == 0x56440031 || VERSION == 0x56440032 )); then
    reg 0x80 1
    [[ "$(( $(reg 0x80) ))" == 1 ]] || { echo 'Camera source readback failed'; exit 1; }
fi
reg 0x90 0
reg 0xa4 "$PREPROCESS"
reg 0xa8 1
reg 0x60 2
# Soft reset reinitializes DDR PHY and requester together. Wait for real
# calibration completion, not a fixed delay or a camera-only ready flag.
DDR_READY=0
for _ in $(seq 1 100); do
    DDR_STATUS=$(reg 0xcc)
    if [ "$((DDR_STATUS & 7))" -eq 7 ]; then
        DDR_READY=1
        break
    fi
    sleep 0.1
done
if [ "$DDR_READY" -ne 1 ] || [ "$(((DDR_STATUS >> 24) & 255))" -ne 0 ]; then
    echo "DDR calibration failed/not ready: $DDR_STATUS"
    snapshot > "$LOG_DIR/after.log"
    cat "$LOG_DIR/after.log"
    exit 1
fi
snapshot > "$LOG_DIR/before.log"
timeout 60 "$RX" -d "$DEVICE" -n "$FRAMES" "${OUTPUT_ARGS[@]}" -v > "$LOG_DIR/rx.log" 2>&1 &
RX_PID=$!
MON_PID=
trap 'reg 0x60 0; kill -TERM "$RX_PID" ${MON_PID:+"$MON_PID"} 2>/dev/null || true; exit 130' INT TERM
sleep 1
monitor_ddr > "$LOG_DIR/ddr_timeline.log" 2>&1 &
MON_PID=$!
reg 0x60 1
set +e
wait "$RX_PID"
RESULT=$?
RX_RESULT=$RESULT
set -e
# Record invalid count before disabling the producer. This separates errors
# already seen during capture from changes first observed after stopping.
DDR_INVALID_PRE_STOP=$(reg 0xd8)
printf 'DDR_INVALID_BEFORE_STOP=%s\n' "$DDR_INVALID_PRE_STOP" > "$LOG_DIR/before_stop.log"
reg 0x60 0
kill -TERM "$MON_PID" 2>/dev/null || true
wait "$MON_PID" 2>/dev/null || true
snapshot > "$LOG_DIR/after.log"
ERRORS=$(reg 0xbc)
DROPS=$(reg 0xc8)
DDR_INVALID=$(reg 0xd8)
DDR_WR_ERR=$(reg 0xdc)
DDR_RD_ERR=$(reg 0xe0)
DDR_CAP_DROPS=$(reg 0xe4)
echo "DDR_INVALID before_stop=$DDR_INVALID_PRE_STOP after_stop=$DDR_INVALID"
MEDIAN_ERRORS=$(reg 0xf4)
SOBEL_ERRORS=$(reg 0xf8)
echo "PRE_MEDIAN_ERRORS=$MEDIAN_ERRORS PRE_SOBEL_ERRORS=$SOBEL_ERRORS"
if [[ "$PREPROCESS" == 9 ]]; then
    DEHAZE_ERRORS=$(reg 0x120)
    echo "PRE_DEHAZE_ERRORS=$DEHAZE_ERRORS"
    if (( DEHAZE_ERRORS != 0 )); then echo 'Dehaze protocol errors'; RESULT=1; fi
fi
if { [ "$PREPROCESS" -eq 5 ] && [ "$((MEDIAN_ERRORS))" -ne 0 ]; } ||
   { [ "$PREPROCESS" -eq 6 ] && [ "$((SOBEL_ERRORS))" -ne 0 ]; }; then
    echo 'Selected preprocessing branch reported protocol errors'
    RESULT=1
fi
if [ "$((ERRORS))" -ne 0 ] || [ "$((DROPS))" -ne 0 ] ||
   [ "$((DDR_INVALID | DDR_WR_ERR | DDR_RD_ERR | DDR_CAP_DROPS))" -ne 0 ]; then
    echo "FPGA integrity failed: COMP_ERRORS=$ERRORS CAM_FIFO_DROPS=$DROPS DDR_INVALID=$DDR_INVALID DDR_WRITE_ERR=$DDR_WR_ERR DDR_READ_ERR=$DDR_RD_ERR DDR_CAP_DROPS=$DDR_CAP_DROPS"
    RESULT=1
fi
echo "DDR_NO_SLOT=$(reg 0xd4) (whole incoming frames skipped while slots busy)"
DDR_STARTUP_SKIPS=$(reg 0xf0)
echo "DDR_STARTUP_SKIPS=$DDR_STARTUP_SKIPS (one startup exposure skipped after soft reset)"
if [ "$((DDR_STARTUP_SKIPS))" -ne 1 ]; then
    echo 'Unexpected startup skip count (expected 1)'
    RESULT=1
fi
trap - INT TERM
dmesg | tail -100 > "$LOG_DIR/dmesg.log"
cat "$LOG_DIR/rx.log"
cat "$LOG_DIR/after.log"
if command -v python3 >/dev/null && [ -f "$SCRIPT_DIR/decode_ddr_fault.py" ]; then
    if python3 "$SCRIPT_DIR/decode_ddr_fault.py" "$LOG_DIR/after.log" > "$LOG_DIR/first_fault.log" 2>&1; then
        cat "$LOG_DIR/first_fault.log"
    else
        cat "$LOG_DIR/first_fault.log" >&2
        RESULT=1
    fi
else
    echo 'Fault decoder unavailable; raw 0x100..0x11c registers are saved in after.log.'
fi
echo "receiver_exit=$RX_RESULT test_exit=$RESULT"
echo "Logs: $LOG_DIR"
exit "$RESULT"
