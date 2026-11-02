#!/bin/bash
# Board-only, sequential validation of the October 14 candidate.
# No bit programming, PCI configuration writes, driver reloads or clock edits.
# Usage: bash validate_board_clock.sh preflight|source|raw|display|lz77|repeat|benchmark
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STAGE=${1:-preflight}
CONNECTOR=${CONNECTOR:-188}
export VIDEO_DEVICE=${VIDEO_DEVICE:-/dev/video73}
case "$STAGE" in preflight|source|raw|display|lz77|repeat|benchmark) ;; *) echo 'Unknown stage'; exit 2;; esac
[[ $EUID == 0 ]] || { echo 'Run as root on RK3576'; exit 1; }
for cmd in lspci busybox fuser pgrep python3 timeout; do
    command -v "$cmd" >/dev/null || { echo "Missing: $cmd"; exit 1; }
done
LOG_ROOT=${LOG_ROOT:-/home/linaro/pcie-board-tests}
mkdir -p "$LOG_ROOT"
OUT=$(mktemp -d "$LOG_ROOT/$STAGE.XXXXXX")
chmod 755 "$OUT"
echo "Validation logs: $OUT"
LINK_PID=
SOURCE_ENABLED=0
finish() {
    local result=$?
    trap - EXIT
    set +e
    if [[ "$SOURCE_ENABLED" == 1 ]]; then busybox devmem "$((BAR0 + 0x60))" 32 0; fi
    if [[ -n "$LINK_PID" ]]; then kill -TERM "$LINK_PID" 2>/dev/null; wait "$LINK_PID" 2>/dev/null; fi
    dmesg > "$OUT/dmesg.after.log"
    if [[ -n "${BDF:-}" ]]; then lspci -D -s "$BDF" -vv > "$OUT/pcie.after.log"; fi
    chmod -R a+rX "$OUT"
    echo "Validation finished: exit=$result logs=$OUT"
    exit "$result"
}
trap finish EXIT
dmesg > "$OUT/dmesg.before.log"
mapfile -t ENDPOINTS < <(lspci -D -d 1edb:abcd -n | awk '{print $1}')
[[ ${#ENDPOINTS[@]} == 1 ]] || { echo 'Expected exactly one endpoint 1edb:abcd'; exit 1; }
BDF=${ENDPOINTS[0]}
SYS="/sys/bus/pci/devices/$BDF"
read -r BASE LIMIT FLAGS < "$SYS/resource"
[[ "$BASE" =~ ^0x[0-9a-fA-F]+$ && "$LIMIT" =~ ^0x[0-9a-fA-F]+$ && "$FLAGS" =~ ^0x[0-9a-fA-F]+$ ]] || exit 1
(( BASE != 0 && LIMIT - BASE >= 0x11f && (FLAGS & 0x200) != 0 )) || { echo 'Invalid memory BAR0'; exit 1; }
export BAR0=$BASE
lspci -D -s "$BDF" -nn -vv > "$OUT/pcie.before.log"
cat "$OUT/pcie.before.log"
VERSION=$(busybox devmem "$((BAR0 + 0x5c))" 32)
printf 'BDF=%s BAR0=%s VERSION=%s\n' "$BDF" "$BAR0" "$VERSION" | tee "$OUT/identity.log"
case "$((VERSION))" in
    "$((0x56440026))") echo 'Version 0x56440026 cannot distinguish the October 14 PCIe candidate from the v26 rollback.' ;;
    "$((0x56440027))") echo 'v27 MIPI scan range/count candidate; hardware validation pending.' ;;
    "$((0x56440028))") echo 'v28 four-byte LZ77 / four queued DDR slots; hardware validation pending.' ;;
    "$((0x56440029))") echo 'v29 BLK1 raw/compressed block selection; hardware validation pending.' ;;
    "$((0x56440032))") echo 'v32 MP4 overlap + brighter dehaze candidate; board validation pending.' ;;
    "$((0x56440031))") echo 'v31 H2V1 host video + camera mode8/9; board validation pending.' ;;
    "$((0x56440030))") echo 'v30 color lowlight/dehaze + BLK1; hardware validation pending.' ;;
    *) echo 'Unexpected register map; stopping'; exit 1;;
esac
for dev in "$VIDEO_DEVICE" /dev/ANLOGIC-PCI0_c2h_0; do
    [[ -c "$dev" ]] || { echo "Missing device: $dev"; exit 1; }
done
[[ -L "$SYS/driver" ]] || { echo 'PCI driver is not bound'; exit 1; }
readlink -f "$SYS/driver" > "$OUT/driver.log"
if fuser "$VIDEO_DEVICE" /dev/ANLOGIC-PCI0_c2h_0 2>/dev/null || pgrep -x gst-launch-1.0 >/dev/null; then
    echo 'Stop existing video/YOLO/C2H readers before this test; no process was killed.'
    exit 1
fi
if [[ "$STAGE" == preflight ]]; then exit 0; fi
monitor_link() {
    while :; do
        printf 'time=%s ' "$(date -Iseconds)"
        for field in current_link_speed current_link_width; do
            printf '%s=' "$field"
            if [[ -r "$SYS/$field" ]]; then tr '\n' ' ' < "$SYS/$field"; else printf 'unavailable '; fi
        done
        printf '\n'
        sleep 2
    done
}
monitor_link > "$OUT/link.timeline.log" &
LINK_PID=$!

# Keep the exact subordinate logs even if the capture fails.
run_logged() {
    local name=$1 result folder
    shift
    echo "Running: $name"
    set +e
    "$@" > "$OUT/$name.log" 2>&1
    result=$?
    set -e
    printf '%s exit=%s\n' "$name" "$result" | tee -a "$OUT/exits.txt"
    tail -20 "$OUT/$name.log"
    while IFS= read -r folder; do
        case "$folder" in
            /tmp/raw-video.*|/tmp/lz77-video.*|/tmp/lz77-diag.*|/tmp/video-benchmark.*)
                [[ ! -d "$folder" ]] || cp -a -- "$folder" "$OUT/" ;;
        esac
    done < <(grep -oE '/tmp/(raw-video|lz77-video|lz77-diag|video-benchmark)\.[[:alnum:]]+' "$OUT/$name.log" | sort -u || true)
    # collect_video_perf produces a zip with all exact benchmark child logs.
    while IFS= read -r folder; do
        [[ ! -f "$folder" ]] || cp -- "$folder" "$OUT/"
    done < <(grep -oE '/tmp/pcie-video-report\.[[:alnum:]_-]+\.zip' "$OUT/$name.log" | sort -u || true)
    return "$result"
}

case "$STAGE" in
    source)
        # With no DMA reader, pack4 still drains (cam_tready is tied to 1).
        # Raw output FIFO fills and gate/drop counts may grow; this is NOT
        # a DMA/integrity test. It isolates continuous camera/ISP frame output.
        [[ "$(( $(busybox devmem "$((BAR0 + 0x90))" 32) ))" == 0 ]] || {
            echo 'Source isolation requires camera mode 0 (1080p)'; exit 1;
        }
        busybox devmem "$((BAR0 + 0x60))" 32 0
        bash "$SCRIPT_DIR/mode_control.sh" "$BAR0" 0 0
        busybox devmem "$((BAR0 + 0x60))" 32 2
        sleep 2
        SOURCE_ENABLED=1
        busybox devmem "$((BAR0 + 0x60))" 32 1
        result=0
        run_logged source env PYTHONUNBUFFERED=1 timeout --signal=TERM 12 \
            python3 "$SCRIPT_DIR/monitor_video_perf.py" --bar0 "$BAR0" || result=$?
        [[ "$result" == 124 || "$result" == 0 ]] || exit 1
        busybox devmem "$((BAR0 + 0x60))" 32 0
        SOURCE_ENABLED=0
        echo 'Source-only observation complete; no DMA reader was started.'
        echo 'Inspect camera_per_s and camera_stage_flags; output FIFO/drop counts are not acceptance criteria here.'
        ;;
    raw|display)
        headless=1
        [[ "$STAGE" != display ]] || headless=0
        # timeout is a scheduled end, not a declaration that FPS/integrity pass.
        result=0
        run_logged "$STAGE" env YOLO_MODEL= VIDEO_HEADLESS="$headless" \
            timeout --signal=INT 60 bash "$SCRIPT_DIR/play_raw_video.sh" 0 "$CONNECTOR" || result=$?
        [[ "$result" == 124 || "$result" == 130 ]] || { echo 'Playback ended unexpectedly'; exit 1; }
        # A scheduled timeout can also end a capture that never produced frames.
        shopt -s nullglob
        gst_logs=("$OUT"/raw-video.*/gst.log)
        if [[ ${#gst_logs[@]} == 0 ]]; then
            echo 'CAPTURE FAILED: no saved GStreamer log'; exit 1
        fi
        if ! awk '
            ($1 == "OUTPUT" || $1 == "DISPLAY") && $2 == "source=V4L2" {
                for (i=3; i<=NF; i++) {
                    if ($i ~ /^fps=/) {
                        split($i, value, "=")
                        if (value[2]+0 > 0) observed=1
                    }
                }
            }
            END { exit(observed ? 0 : 1) }
        ' "${gst_logs[@]}"; then
            echo 'CAPTURE FAILED: no positive V4L2 OUTPUT/DISPLAY FPS sample; timeout is not a capture pass.'
            exit 1
        fi
        echo 'Frame output observed. Review sustained FPS and hardware errors; this is not full validation.'
        if command -v v4l2-ctl >/dev/null; then v4l2-ctl -d "$VIDEO_DEVICE" --get-fmt-video > "$OUT/format.log"; fi
        ;;
    lz77)
        modes=(0 1 5 6)
        [[ "$((VERSION))" != "$((0x56440030))" && "$((VERSION))" != "$((0x56440031))" && "$((VERSION))" != "$((0x56440032))" ]] || modes+=(8 9)
        for mode in "${modes[@]}"; do
            run_logged "lz77_mode$mode" bash "$SCRIPT_DIR/test_lz77_frames.sh" "$BAR0" 3 "$mode"
            sleep 2
        done
        ;;
    repeat)
        for iteration in $(seq 1 10); do
            run_logged "restart$iteration" bash "$SCRIPT_DIR/test_lz77_frames.sh" "$BAR0" 3 1
            sleep 2
        done
        ;;
    benchmark)
        export YOLO_MODEL=${YOLO_MODEL:-/home/linaro/rock/yolo/yolov5s_relu.rknn}
        run_logged benchmark bash "$SCRIPT_DIR/benchmark_video_paths.sh" 1 "$CONNECTOR" 60
        echo 'Check all eight case exits/results; benchmark script completion alone is not a pass.'
        ;;
esac
