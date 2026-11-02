#!/bin/bash
# One terminal, same scene, four consecutive cases. No bit/driver/clock changes.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MODE=${1:-8}
CONNECTOR=${2:-188}
DURATION=${3:-35}
case "$MODE" in 0|1|2|3|4|5|6|8|9) ;; *) echo 'Mode must be 0..6, 8, 9'; exit 2;; esac
case "$CONNECTOR" in ''|*[!0-9]*) echo 'Invalid connector'; exit 2;; esac
case "$DURATION" in ''|*[!0-9]*) echo 'Duration must be 10..300 seconds'; exit 2;; esac
(( ${#DURATION} <= 3 )) && (( 10#$DURATION >= 10 && 10#$DURATION <= 300 )) || {
    echo 'Duration must be 10..300 seconds'; exit 2;
}
for cmd in timeout python3; do command -v "$cmd" >/dev/null || { echo "Missing $cmd"; exit 1; }; done
RX="$SCRIPT_DIR/rk3576/rk3576_lz77_rx"
[[ -x "$RX" && $("$RX" --optimization-info) == rx-blk1-match-pipe-20261025 ]] || {
    echo 'First run: cd /home/linaro/deploy/rk3576 && bash build.sh'; exit 1;
}
RESULTS=$(mktemp -d /tmp/lz77-benchmark.XXXXXX)
chmod 755 "$RESULTS"
trap 'exit 130' INT
trap 'exit 143' TERM
MODEL=${YOLO_MODEL:-}
[[ -z "$MODEL" || -f "$MODEL" ]] || { echo "Model missing: $MODEL"; exit 1; }
CASES=(headless_scalar headless_fast display_scalar display_fast)
[[ -z "$MODEL" ]] || CASES+=(stats_fast)
echo "Benchmark logs: $RESULTS"
echo 'Keep camera, lighting and scene fixed. headless cases show no video.'
echo 'scalar is a diagnostic reference; only stats_fast enables YOLO.'
for CASE in "${CASES[@]}"; do
    HEADLESS=0; COPY=fast; PIPE_BYTES=1048576; YOLO=; KMS=0
    [[ "$CASE" != headless* ]] || HEADLESS=1
    if [[ "$CASE" == *scalar ]]; then COPY=scalar; PIPE_BYTES=0; fi
    if [[ "$CASE" == stats_fast ]]; then
        YOLO=$MODEL; KMS=${YOLO_KMS_OVERLAY:-1}
    fi
    echo "CASE=$CASE mode=$MODE seconds=$DURATION match_copy=$COPY pipe_bytes=$PIPE_BYTES"
    set +e
    env RX_PIPELINE=1 RX_CRC=auto RX_MATCH_COPY="$COPY" RX_PIPE_BYTES="$PIPE_BYTES" \
        VIDEO_HEADLESS="$HEADLESS" VIDEO_CAPTURE=0 YOLO_MODEL="$YOLO" \
        YOLO_VIEW=stats YOLO_KMS_OVERLAY="$KMS" \
        timeout --signal=INT --kill-after=20s "$DURATION" \
        bash "$SCRIPT_DIR/play_lz77_video.sh" "$MODE" "$CONNECTOR" \
        > "$RESULTS/$CASE.log" 2>&1
    RESULT=$?
    set -e
    printf '%s exit=%s\n' "$CASE" "$RESULT" | tee -a "$RESULTS/results.txt"
    tail -10 "$RESULTS/$CASE.log"
    if [[ "$RESULT" != 124 && "$RESULT" != 130 ]]; then
        echo "Unexpected exit; inspect $RESULTS/$CASE.log before further playback."
        python3 "$SCRIPT_DIR/collect_video_perf.py" --benchmark "$RESULTS"
        exit 1
    fi
    sleep 2
done
python3 "$SCRIPT_DIR/collect_video_perf.py" --benchmark "$RESULTS"
chmod 644 "$RESULTS/"*.log "$RESULTS/results.txt"
echo "Finished; case logs: $RESULTS"
echo 'Timed exit is not an integrity pass. Check CRC/decode/format and hardware errors, then compare steady interval FPS.'
