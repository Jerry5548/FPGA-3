#!/bin/bash
# Already-loaded candidate only; no module reload or FPGA bit changes.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FRAMES=${1:-300}
MODE=${2:-8}
PARAM=/sys/module/anlogic_pci/parameters
[[ "$EUID" == 0 ]] || { echo 'Run in the board root PuTTY session'; exit 1; }
case "$FRAMES" in ''|*[!0-9]*|0) echo 'Frames must be a positive decimal integer'; exit 2;; esac
case "$MODE" in 0|1|2|3|4|5|6|8|9) ;; *) echo 'Mode must be 0..6, 8, 9'; exit 2;; esac
[[ -w "$PARAM/st_c2h_wait_spin_us" && -w "$PARAM/st_c2h_profile" ]] || {
    echo 'Candidate driver is not loaded; see DMA_WAIT_20261025.md'; exit 1;
}
for cmd in fuser python3 tee tar; do
    command -v "$cmd" >/dev/null || { echo "Missing $cmd"; exit 1; }
done
if fuser /dev/ANLOGIC-PCI0_c2h_0 /dev/video73 2>/dev/null; then
    echo 'Stop current camera/DMA users before testing'; exit 1;
fi
ORIGINAL=$(cat "$PARAM/st_c2h_wait_spin_us")
OUT=$(mktemp -d /home/linaro/dma-wait-ab.XXXXXX)
chmod 755 "$OUT"
echo "DMA wait comparison: $OUT"
finish() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    echo 0 > "$PARAM/st_c2h_profile"
    echo "$ORIGINAL" > "$PARAM/st_c2h_wait_spin_us"
    tar -czf "$OUT.tar.gz" -C "$(dirname -- "$OUT")" "$(basename -- "$OUT")"
    chmod a+r "$OUT.tar.gz"
    echo "Archive: $OUT.tar.gz"
    echo "Restored st_c2h_wait_spin_us=$ORIGINAL. Profiling disabled."
    exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Repeated zero-budget baseline helps expose scene/thermal/run-order drift.
CASES=(off_before spin10 spin20 off_after)
BUDGETS=(0 10 20 0)
for i in "${!CASES[@]}"; do
    CASE=${CASES[$i]}; BUDGET=${BUDGETS[$i]}
    echo "$BUDGET" > "$PARAM/st_c2h_wait_spin_us"
    [[ $(cat "$PARAM/st_c2h_wait_spin_us") == "$BUDGET" ]] || { echo 'Readback mismatch'; exit 1; }
    echo "CASE=$CASE budget_us=$BUDGET mode=$MODE frames=$FRAMES" | tee -a "$OUT/results.txt"
    cat /proc/stat > "$OUT/$CASE.cpu.before"
    set +e
    bash "$SCRIPT_DIR/collect_dma_profile.sh" "$FRAMES" "$MODE" 2>&1 | tee "$OUT/$CASE.log"
    STATUS=("${PIPESTATUS[@]}")
    set -e
    cat /proc/stat > "$OUT/$CASE.cpu.after"
    # Copy the exact profiler directory. Never pick the most recent unrelated run.
    PROFILE=$(sed -n 's/^DMA profile directory: //p' "$OUT/$CASE.log" | head -1)
    if [[ "$PROFILE" == /home/linaro/dma-profile.* && -d "$PROFILE" ]]; then
        cp -a -- "$PROFILE" "$OUT/$CASE"
    fi
    if [[ "${STATUS[0]}" != 0 || "${STATUS[1]}" != 0 ]]; then
        echo "Stopped on failed test: $CASE"; exit 1;
    fi
done
echo 'Comparison complete. Do not select a budget using profiled FPS alone; retest with profiling off.'
