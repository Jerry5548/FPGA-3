#!/bin/bash
# Candidate already loaded: actual video A/B, profiling OFF, no module reload.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MODE=${1:-8}
CONNECTOR=${2:-188}
DURATION=${3:-35}
PARAM=/sys/module/anlogic_pci/parameters
[[ "$EUID" == 0 ]] || { echo 'Run in the board root PuTTY session'; exit 1; }
case "$MODE" in 0|1|2|3|4|5|6|8|9) ;; *) echo 'Mode must be 0..6, 8, 9'; exit 2;; esac
case "$CONNECTOR" in ''|*[!0-9]*) echo 'Invalid connector'; exit 2;; esac
case "$DURATION" in ''|*[!0-9]*) echo 'Seconds must be 10..300'; exit 2;; esac
(( ${#DURATION} <= 3 )) && (( 10#$DURATION >= 10 && 10#$DURATION <= 300 )) || exit 2
[[ -w "$PARAM/st_c2h_wait_spin_us" && -w "$PARAM/st_c2h_profile" ]] || {
    echo 'Candidate driver missing; see DMA_WAIT_20261025.md'; exit 1;
}
for cmd in fuser python3 timeout tee; do
    command -v "$cmd" >/dev/null || { echo "Missing $cmd"; exit 1; }
done
if fuser /dev/ANLOGIC-PCI0_c2h_0 /dev/video73 2>/dev/null; then
    echo 'Stop all existing video/camera users first'; exit 1;
fi
MODEL=${YOLO_MODEL:-}
[[ -z "$MODEL" || -f "$MODEL" ]] || { echo "Model missing: $MODEL"; exit 1; }
ORIGINAL=$(cat "$PARAM/st_c2h_wait_spin_us")
OUT=$(mktemp -d /tmp/dma-wait-video.XXXXXX)
chmod 755 "$OUT"
echo "Video comparison logs: $OUT"
echo "MODE=$MODE connector=$CONNECTOR duration=$DURATION YOLO_MODEL=$MODEL"
echo 'Keep scene/lighting fixed. No recording. DISPLAY and YOLO FPS are separate measurements.'
finish() {
    local rc=$?
    trap - EXIT INT TERM
    set +e
    echo 0 > "$PARAM/st_c2h_profile"
    echo "$ORIGINAL" > "$PARAM/st_c2h_wait_spin_us"
    python3 "$SCRIPT_DIR/collect_video_perf.py" --benchmark "$OUT"
    local collect_rc=$?
    [[ "$rc" != 0 || "$collect_rc" == 0 ]] || rc=$collect_rc
    chmod 644 "$OUT/"*.log "$OUT/results.txt" 2>/dev/null
    echo "Restored st_c2h_wait_spin_us=$ORIGINAL. Profiling disabled."
    exit "$rc"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo 0 > "$PARAM/st_c2h_profile"
case "$(cat "$PARAM/st_c2h_profile")" in 0|N|n) ;; *) echo 'Could not disable profiling'; exit 1;; esac
CASES=(off_before spin10 spin20 off_after)
BUDGETS=(0 10 20 0)
for i in "${!CASES[@]}"; do
    CASE=${CASES[$i]}; BUDGET=${BUDGETS[$i]}
    echo "$BUDGET" > "$PARAM/st_c2h_wait_spin_us"
    [[ $(cat "$PARAM/st_c2h_wait_spin_us") == "$BUDGET" ]] || { echo 'Budget readback failed'; exit 1; }
    echo "CASE=$CASE budget_us=$BUDGET profile=off mode=$MODE seconds=$DURATION" | tee -a "$OUT/results.txt"
    cat /proc/stat > "$OUT/$CASE.cpu.before.log"
    KMS=0; [[ -z "$MODEL" ]] || KMS=${YOLO_KMS_OVERLAY:-1}
    set +e
    env RX_PIPELINE=1 RX_CRC=auto RX_MATCH_COPY=fast RX_PIPE_BYTES=1048576 \
        VIDEO_HEADLESS=0 VIDEO_CAPTURE=0 YOLO_MODEL="$MODEL" \
        YOLO_VIEW=stats YOLO_KMS_OVERLAY="$KMS" \
        timeout --signal=INT --kill-after=20s "$DURATION" \
        bash "$SCRIPT_DIR/play_lz77_video.sh" "$MODE" "$CONNECTOR" \
        > "$OUT/$CASE.log" 2>&1
    RC=$?
    set -e
    cat /proc/stat > "$OUT/$CASE.cpu.after.log"
    echo "$CASE exit=$RC" | tee -a "$OUT/results.txt"
    tail -10 "$OUT/$CASE.log"
    [[ "$RC" == 124 || "$RC" == 130 ]] || { echo 'Unexpected playback exit'; exit 1; }
    # Check the exact run's receiver summary and hardware error registers.
    python3 - "$OUT/$CASE.log" <<'PY'
import re
import sys
from pathlib import Path
console=Path(sys.argv[1]).read_text(encoding='utf-8',errors='replace')
names=re.findall(r'Logs: (/tmp/lz77-video\.[A-Za-z0-9]+)',console)
if not names:
    raise SystemExit('Missing exact playback log directory')
root=Path(names[-1])
rx=(root/'rx.log').read_text(encoding='utf-8',errors='replace')
summaries=[line for line in rx.splitlines() if line.startswith('frames=')]
if not summaries:
    raise SystemExit('Missing receiver final summary')
values=dict(re.findall(r'(\w+)=([^\s]+)',summaries[-1]))
if int(values['frames'])<1 or any(int(values[k]) for k in ('crc_errors','decode_errors','format_errors')):
    raise SystemExit('Receiver integrity check failed')
registers=dict(re.findall(r'BAR0\+(0x[\da-f]+)=(0x[\da-fA-F]+)',(root/'after.log').read_text()))
required=['0xbc','0xc8','0xd8','0xdc','0xe0','0xe4']
mode=int(registers['0xa4'],16)
if mode in (5,6,9):
    required.append({5:'0xf4',6:'0xf8',9:'0x120'}[mode])
if any(int(registers[k],16) for k in required):
    raise SystemExit('Hardware integrity check failed')
print('PASS recorded receiver and hardware integrity:',root)
PY
    sleep 2
done
echo 'Video comparison complete. Use same-run DISPLAY/YOLO metrics; do not infer FPS from HDMI refresh.'
