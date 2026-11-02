#!/bin/bash
# Run after building/loading the profiling driver. Does not reload drivers.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
FRAMES=${1:-300}
MODE=${2:-0}
BAR0=${BAR0:-0x21200000}
PARAM=/sys/module/anlogic_pci/parameters
case "$FRAMES" in ''|*[!0-9]*|0) echo 'Frames must be a positive decimal integer'; exit 2;; esac
case "$MODE" in 0|1|2|3|4|5|6|8|9) ;; *) echo 'Mode must be 0..6, 8, 9'; exit 2;; esac
[[ "$EUID" == 0 ]] || { echo 'Run as root'; exit 1; }
[[ -w "$PARAM/st_c2h_profile" && -r "$PARAM/st_c2h_profile_stats" ]] || {
    echo 'Build and load the diagnostic anlogic_pci.ko first; see DMA_PROFILE_20261016.md'; exit 1;
}
grep -q '^version=dma-profile-20261016$' "$PARAM/st_c2h_profile_stats" || {
    echo 'Unexpected driver profile version'; exit 1;
}
for command in python3 fuser tee dmesg tar; do
    command -v "$command" >/dev/null || { echo "Missing command: $command"; exit 1; }
done
if fuser /dev/ANLOGIC-PCI0_c2h_0 /dev/video73 2>/dev/null; then
    echo 'Stop existing camera/DMA users first'; exit 1
fi
OUT=$(mktemp -d /home/linaro/dma-profile.XXXXXX)
chmod 755 "$OUT"
echo "DMA profile directory: $OUT"
finish() {
    local result=$?
    trap - EXIT INT TERM
    set +e
    echo 0 > "$PARAM/st_c2h_profile"
    cat "$PARAM/st_c2h_profile_stats" > "$OUT/profile.stats"
    python3 "$SCRIPT_DIR/summarize_dma_profile.py" "$OUT/profile.stats" > "$OUT/profile.summary" 2>&1
    local summary_result=$?
    [[ "$result" != 0 || "$summary_result" == 0 ]] || result=$summary_result
    dmesg > "$OUT/dmesg.after.log"
    local diag
    diag=$(sed -n 's/^Logs: //p' "$OUT/console.log" 2>/dev/null | head -1)
    if [[ "$diag" == /tmp/lz77-diag.* && -d "$diag" ]]; then
        cp -a -- "$diag" "$OUT/diagnostic"
    fi
    cat "$OUT/profile.summary"
    chmod -R a+rX "$OUT"
    tar -czf "$OUT.tar.gz" -C "$(dirname -- "$OUT")" "$(basename -- "$OUT")"
    echo "DMA profile logs: $OUT"
    echo "Archive: $OUT.tar.gz"
    exit "$result"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
{
    uname -a
    for p in "$PARAM/"*; do
        [[ -f "$p" && "$(basename -- "$p")" != st_c2h_profile_stats ]] || continue
        printf '%s=' "$(basename -- "$p")"; cat "$p"
    done
} > "$OUT/config.log"
dmesg > "$OUT/dmesg.before.log"
echo 1 > "$PARAM/st_c2h_profile"
set +e
BAR0="$BAR0" bash "$SCRIPT_DIR/test_lz77_frames.sh" "$BAR0" "$FRAMES" "$MODE" 2>&1 | tee "$OUT/console.log"
RESULTS=("${PIPESTATUS[@]}")
set -e
[[ "${RESULTS[0]}" == 0 ]] || exit "${RESULTS[0]}"
[[ "${RESULTS[1]}" == 0 ]] || exit "${RESULTS[1]}"
