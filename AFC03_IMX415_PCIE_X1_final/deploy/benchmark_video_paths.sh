#!/bin/bash
# Sequential 1080p measurements; no automatic driver/clock/bitstream changes.
# Usage: bash benchmark_video_paths.sh [mode=1] [connector=188] [seconds=30]
set -euo pipefail
trap 'exit 130' INT
trap 'exit 143' TERM
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MODE=${1:-1}
CONNECTOR=${2:-188}
DURATION=${3:-30}
MODEL=${YOLO_MODEL:-/home/linaro/rock/yolo/yolov5s_relu.rknn}
PYTHON=${YOLO_PYTHON:-python3}
case "$DURATION" in ''|*[!0-9]*) echo 'seconds must be an integer'; exit 2;; esac
(( DURATION >= 10 && DURATION <= 300 )) || { echo 'seconds must be 10..300'; exit 2; }
command -v timeout >/dev/null || { echo 'Missing timeout'; exit 1; }
[[ -f "$MODEL" ]] || { echo "Model missing: $MODEL"; exit 1; }
RESULTS=$(mktemp -d /tmp/video-benchmark.XXXXXX)
chmod 755 "$RESULTS"
echo "Benchmark logs: $RESULTS"
echo 'Keep scene/lighting fixed. Headless tests intentionally do not show a picture.'
echo 'Display/OUTPUT FPS, YOLO FPS and hardware camera FPS are different measurements.'
CASES=(raw_headless raw_display raw_yolo_headless raw_yolo_display lz77_headless lz77_display lz77_yolo_headless lz77_yolo_display)
for CASE in "${CASES[@]}"; do
    PLAY=play_raw_video.sh
    [[ "$CASE" != lz77* ]] || PLAY=play_lz77_video.sh
    HEADLESS=0; [[ "$CASE" != *headless ]] || HEADLESS=1
    YOLO=; [[ "$CASE" != *yolo* ]] || YOLO=$MODEL
    printf '\nCASE=%s mode=%s seconds=%s\n' "$CASE" "$MODE" "$DURATION"
    set +e
    YOLO_MODEL="$YOLO" YOLO_VIEW=stats VIDEO_HEADLESS="$HEADLESS" \
        timeout --signal=INT "$DURATION" bash "$SCRIPT_DIR/$PLAY" "$MODE" "$CONNECTOR" \
        > "$RESULTS/$CASE.log" 2>&1
    RESULT=$?
    set -e
    printf '%s exit=%s\n' "$CASE" "$RESULT" | tee -a "$RESULTS/results.txt"
    tail -8 "$RESULTS/$CASE.log"
    # 124 is the scheduled end of a timed live test, not an accuracy pass.
    if [[ "$RESULT" != 124 && "$RESULT" != 130 ]]; then
        echo "Stopped on unexpected exit; read $RESULTS/$CASE.log"
        break
    fi
    sleep 2
done
"$PYTHON" "$SCRIPT_DIR/collect_video_perf.py" --benchmark "$RESULTS"
chmod 644 "$RESULTS/"*.log "$RESULTS/results.txt"
echo "Case logs: $RESULTS"
