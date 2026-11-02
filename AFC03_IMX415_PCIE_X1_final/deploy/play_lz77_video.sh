#!/bin/bash
# Live decoded 1080p RGB24. Usage: bash play_lz77_video.sh MODE CONNECTOR
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON=${YOLO_PYTHON:-python3}
MODE=${1:-1}
CONNECTOR=${2:-188}
BAR0=${BAR0:-0x21200000}
DEVICE=/dev/ANLOGIC-PCI0_c2h_0
RX="$SCRIPT_DIR/rk3576/rk3576_lz77_rx"
RX_PIPELINE=${RX_PIPELINE:-1}
RX_CRC=${RX_CRC:-auto}
RX_MATCH_COPY=${RX_MATCH_COPY:-fast}
RX_PIPE_BYTES=${RX_PIPE_BYTES:-1048576}
case "$RX_MATCH_COPY" in fast|scalar) ;; *) echo 'RX_MATCH_COPY must be fast or scalar'; exit 2;; esac
case "$RX_PIPE_BYTES" in ''|*[!0-9]*) echo 'RX_PIPE_BYTES must be 0..16777216'; exit 2;; esac
(( ${#RX_PIPE_BYTES} <= 8 )) && (( 10#$RX_PIPE_BYTES <= 16777216 )) || {
    echo 'RX_PIPE_BYTES must be 0..16777216'; exit 2;
}
case "$RX_PIPELINE" in
    1) RX_ARGS=(--pipeline);;
    0) RX_ARGS=(--serial);;
    *) echo 'RX_PIPELINE must be 0 or 1'; exit 2;;
esac
case "$RX_CRC" in auto|table|slice8|arm) ;; *) echo 'Invalid RX_CRC'; exit 2;; esac
RX_ARGS+=(--crc "$RX_CRC")
RX_ARGS+=(--match-copy "$RX_MATCH_COPY" --pipe-bytes "$RX_PIPE_BYTES")
HEADLESS=${VIDEO_HEADLESS:-0}
case "$HEADLESS" in 0|1) ;; *) echo 'VIDEO_HEADLESS must be 0 or 1'; exit 2;; esac
DISPLAY_ARGS=()
[[ "$HEADLESS" == 0 ]] || DISPLAY_ARGS=(--headless)
VIDEO_CAPTURE=${VIDEO_CAPTURE:-0}
case "$VIDEO_CAPTURE" in 0|1) ;; *) echo 'VIDEO_CAPTURE must be 0 or 1'; exit 2;; esac
VIDEO_CAPTURE_NO_KEYS=${VIDEO_CAPTURE_NO_KEYS:-0}
case "$VIDEO_CAPTURE_NO_KEYS" in 0|1) ;; *) echo 'VIDEO_CAPTURE_NO_KEYS must be 0 or 1'; exit 2;; esac
CAPTURE_DIR=${VIDEO_CAPTURE_DIR:-/mnt/tf/FPGA_Captures}
if [[ "$VIDEO_CAPTURE" == 1 ]]; then
    case "$CAPTURE_DIR" in /mnt/tf/*) ;; *) echo 'VIDEO_CAPTURE_DIR must be inside /mnt/tf'; exit 2;; esac
    case "/$CAPTURE_DIR/" in */../*) echo 'VIDEO_CAPTURE_DIR cannot contain ..'; exit 2;; esac
    awk '$2 == "/mnt/tf" { found=1 } END { exit !found }' /proc/mounts || {
        echo 'TF card is not mounted at /mnt/tf; refusing to save captures to system storage'; exit 1;
    }
fi
CAPTURE_PREFLIGHT_ARGS=()
[[ "$VIDEO_CAPTURE" == 0 ]] || CAPTURE_PREFLIGHT_ARGS=(--capture-control /tmp/capture-preflight.sock --capture-dir /tmp)
YOLO_ARGS=()
YOLO_KMS_OVERLAY=${YOLO_KMS_OVERLAY:-0}
case "$YOLO_KMS_OVERLAY" in 0|1) ;; *) echo 'YOLO_KMS_OVERLAY must be 0 or 1'; exit 2;; esac
if [[ -n "${YOLO_MODEL:-}" ]]; then
    case "${YOLO_VIEW:-stats}" in stats|boxes|boxes-sync) ;; *) echo 'YOLO_VIEW must be stats, boxes, or boxes-sync'; exit 2;; esac
    YOLO_ARGS=(--yolo-model "$YOLO_MODEL" --yolo-input-order "${YOLO_INPUT_ORDER:-BGR}" --yolo-view "${YOLO_VIEW:-stats}"
               --yolo-max-fps "${YOLO_MAX_FPS:-30}" --yolo-box-ttl-ms "${YOLO_BOX_TTL_MS:-250}")
    [[ "$YOLO_KMS_OVERLAY" == 0 ]] || YOLO_ARGS+=(--yolo-kms-overlay)
elif [[ "$YOLO_KMS_OVERLAY" == 1 ]]; then
    echo 'YOLO_KMS_OVERLAY=1 requires YOLO_MODEL'; exit 2
fi
case "$MODE" in 0|1|2|3|4|5|6|8|9) ;; *) echo 'Mode must be 0..6, 8, 9'; exit 2;; esac
case "$CONNECTOR" in ''|*[!0-9]*) echo 'Invalid connector'; exit 2;; esac
for cmd in busybox "$PYTHON" gst-inspect-1.0 fuser pgrep mkfifo; do
    command -v "$cmd" >/dev/null || { echo "Missing command: $cmd"; exit 1; }
done
# Parse the real FIFO source graph before enabling the FPGA. filesrc does not
# open the placeholder during parse; the actual FIFO is created below.
"$PYTHON" "$SCRIPT_DIR/display_lz77_video.py" --check \
    --fifo "$SCRIPT_DIR/.preflight-rgb24.pipe" --rx-log "$SCRIPT_DIR/.preflight-rx.log" \
    --connector "$CONNECTOR" --mode "$MODE" --font-size "${OSD_FONT_SIZE:-16}" \
    "${YOLO_ARGS[@]}" "${CAPTURE_PREFLIGHT_ARGS[@]}" "${DISPLAY_ARGS[@]}"
ELEMENTS=(filesrc rawvideoparse queue fpsdisplaysink)
if [[ "$HEADLESS" == 1 ]]; then ELEMENTS+=(fakesink); else ELEMENTS+=(videoconvert textoverlay kmssink); fi
for element in "${ELEMENTS[@]}"; do
    gst-inspect-1.0 "$element" >/dev/null 2>&1 || { echo "Missing element: $element"; exit 1; }
done
if [[ -n "${YOLO_MODEL:-}" ]]; then
    for element in tee appsink; do
        gst-inspect-1.0 "$element" >/dev/null 2>&1 || { echo "Missing element: $element"; exit 1; }
    done
    case "${YOLO_VIEW:-stats}" in
        stats) gst-inspect-1.0 overlaycomposition >/dev/null 2>&1 || { echo 'Missing element: overlaycomposition'; exit 1; };;
        boxes|boxes-sync) gst-inspect-1.0 appsrc >/dev/null 2>&1 || { echo 'Missing element: appsrc'; exit 1; };;
    esac
fi
if [[ "$VIDEO_CAPTURE" == 1 ]]; then
    gst-inspect-1.0 jpegenc >/dev/null 2>&1 || { echo 'VIDEO_CAPTURE requires jpegenc'; exit 1; }
fi
[[ -c "$DEVICE" && -x "$RX" ]] || { echo 'C2H device or receiver missing'; exit 1; }
[[ $("$RX" --version) == lz77-rx-video-perf-20261009 ]] || {
    echo 'Copy new receiver source to deploy/rk3576 and run bash build.sh first'; exit 1;
}
[[ $("$RX" --build-info) == rx-pipeline-20261016 ]] || {
    echo 'Copy receiver C source and rx_*.h headers, then run rk3576/build.sh'; exit 1;
}
[[ $("$RX" --optimization-info) == rx-blk1-match-pipe-20261025 ]] || {
    echo 'Receiver needs rebuild: cd /home/linaro/deploy/rk3576 && bash build.sh'; exit 1;
}
# Check requested CRC support before touching FPGA registers or starting DMA.
"$RX" --crc "$RX_CRC" --self-test-crc
if fuser "$DEVICE" /dev/video73 2>/dev/null || pgrep -x gst-launch-1.0 >/dev/null; then
    echo 'Stop existing C2H/V4L2/GStreamer reader first'; exit 1
fi
reg() { busybox devmem "$((BAR0 + $1))" 32 "${@:2}"; }
VERSION=$(reg 0x5c)
case "$((VERSION))" in "$((0x56440025))"|"$((0x56440026))"|"$((0x56440027))"|"$((0x56440028))"|"$((0x56440029))"|"$((0x56440030))"|"$((0x56440031))"|"$((0x56440032))") ;;
    *) echo "Expected FPGA v25/v26/v27/v28/v29/v30/v31/v32, got $VERSION"; exit 1;; esac
if [[ "$MODE" == 8 || "$MODE" == 9 ]]; then
    [[ ( "$((VERSION))" == "$((0x56440030))" || "$((VERSION))" == "$((0x56440031))" || "$((VERSION))" == "$((0x56440032))" ) ]] || { echo 'Modes 8/9 require FPGA v30/v31/v32'; exit 1; }
fi
LOG_DIR=$(mktemp -d /tmp/lz77-video.XXXXXX)
chmod 755 "$LOG_DIR"
CAPTURE_ARGS=()
if [[ "$VIDEO_CAPTURE" == 1 ]]; then
    mkdir -p "$CAPTURE_DIR"
    CAPTURE_PROBE=$(mktemp "$CAPTURE_DIR/.capture-write-test.XXXXXX") || {
        echo "Capture directory is not writable: $CAPTURE_DIR"; exit 1;
    }
    rm -f -- "$CAPTURE_PROBE"
    CAPTURE_ARGS=(--capture-control "$LOG_DIR/capture.sock" --capture-dir "$CAPTURE_DIR")
    echo 'Capture keys: P = JPEG snapshot, R = start MKV recording, S = stop/finalize recording; Ctrl+C stops playback.'
    echo "Capture socket: $LOG_DIR/capture.sock"
    echo "Capture files: $CAPTURE_DIR"
fi
PIPE="$LOG_DIR/rgb24.pipe"
mkfifo "$PIPE"
RX_PID= GST_PID= MONITOR_PID=
snapshot() {
    for off in 0x5c 0x60 0xa4 0xa8 0xbc 0xc8 0xd8 0xdc 0xe0 0xe4 0xf0 0xf4 0xf8; do
        printf 'BAR0+%s=' "$off"; reg "$off"
    done
    if [[ ( "$((VERSION))" == "$((0x56440030))" || "$((VERSION))" == "$((0x56440031))" || "$((VERSION))" == "$((0x56440032))" ) ]]; then
        printf 'BAR0+0x120='; reg 0x120
    fi
    if [[ "$((VERSION))" == "$((0x56440026))" || "$((VERSION))" == "$((0x56440027))" || "$((VERSION))" == "$((0x56440028))" || "$((VERSION))" == "$((0x56440029))" || ( "$((VERSION))" == "$((0x56440030))" || "$((VERSION))" == "$((0x56440031))" || "$((VERSION))" == "$((0x56440032))" ) ]]; then
        for off in 0x100 0x104 0x108 0x10c 0x110 0x114 0x118 0x11c; do
            printf 'BAR0+%s=' "$off"; reg "$off"
        done
    fi
}
cleanup() {
    local result=$?
    trap - EXIT INT TERM
    set +e
    reg 0x60 0
    if [[ -n "$MONITOR_PID" ]]; then
        kill -TERM "$MONITOR_PID" 2>/dev/null
        wait "$MONITOR_PID" 2>/dev/null
    fi
    for pid in $RX_PID $GST_PID; do kill -TERM "$pid" 2>/dev/null; done
    # Allow the kernel's outstanding synchronous read to retire before KILL.
    for ((i=0;i<120;i++)); do
        local alive=0
        for pid in $RX_PID $GST_PID; do
            if kill -0 "$pid" 2>/dev/null; then alive=1; fi
        done
        [[ "$alive" != 0 ]] || break
        sleep 0.1
    done
    for pid in $RX_PID $GST_PID; do
        if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null; fi
        wait "$pid" 2>/dev/null
    done
    snapshot > "$LOG_DIR/after.log"
    if [[ ( "$((VERSION))" == "$((0x56440026))" || "$((VERSION))" == "$((0x56440027))" || "$((VERSION))" == "$((0x56440028))" || "$((VERSION))" == "$((0x56440029))" || ( "$((VERSION))" == "$((0x56440030))" || "$((VERSION))" == "$((0x56440031))" || "$((VERSION))" == "$((0x56440032))" ) ) && -f "$SCRIPT_DIR/decode_ddr_fault.py" ]]; then
        python3 "$SCRIPT_DIR/decode_ddr_fault.py" "$LOG_DIR/after.log" > "$LOG_DIR/first_fault.log" 2>&1
    fi
    dmesg | tail -100 > "$LOG_DIR/dmesg.log"
    rm -f -- "$PIPE"
    chmod 644 "$LOG_DIR/"*.log
    echo "Stopped. Logs: $LOG_DIR"
    tail -5 "$LOG_DIR/rx.log" "$LOG_DIR/gst.log" 2>/dev/null
    echo 'Receiver performance (overlapping stages; read_wait is consumer queue wait in pipeline mode):'
    grep '^PERF ' "$LOG_DIR/rx.log" | tail -5
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "Live decoded RGB24 + measured display FPS: mode=$MODE; Ctrl+C to stop. Logs: $LOG_DIR"
echo "LZ77 settings: pipeline=$RX_PIPELINE crc=$RX_CRC match_copy=$RX_MATCH_COPY pipe_bytes=$RX_PIPE_BYTES headless=$HEADLESS yolo_view=${YOLO_VIEW:-stats} kms=${YOLO_KMS_OVERLAY:-0}"
reg 0x60 0
if (( VERSION == 0x56440031 || VERSION == 0x56440032 )); then
    reg 0x80 1
    [[ "$(( $(reg 0x80) ))" == 1 ]] || { echo 'Camera source readback failed'; exit 1; }
fi
reg 0x90 0
reg 0xa4 "$MODE"
reg 0xa8 1
reg 0x60 2
READY=0
for ((i=0;i<100;i++)); do
    STATUS=$(reg 0xcc)
    if (( (STATUS & 7) == 7 && ((STATUS >> 24) & 255) == 0 )); then READY=1; break; fi
    sleep 0.1
done
[[ "$READY" == 1 ]] || { echo 'DDR calibration not ready'; exit 1; }
snapshot > "$LOG_DIR/before.log"
# Queue drops whole parsed frames only. Display at arrival rate, no 30fps claim.
"$PYTHON" "$SCRIPT_DIR/display_lz77_video.py" --fifo "$PIPE" --rx-log "$LOG_DIR/rx.log" \
    --connector "$CONNECTOR" --mode "$MODE" --font-size "${OSD_FONT_SIZE:-16}" --ready-file "$LOG_DIR/display.ready" "${YOLO_ARGS[@]}" "${CAPTURE_ARGS[@]}" "${DISPLAY_ARGS[@]}" \
    > "$LOG_DIR/gst.log" 2>&1 &
GST_PID=$!
"$RX" -d "$DEVICE" -n 0 --stdout-rgb24 --profile "${RX_ARGS[@]}" > "$PIPE" 2> "$LOG_DIR/rx.log" &
RX_PID=$!
STARTED=0
for ((i=0;i<450;i++)); do
    kill -0 "$GST_PID" "$RX_PID" 2>/dev/null || { echo 'Display or receiver failed to start'; exit 1; }
    if [[ -f "$LOG_DIR/display.ready" ]] && grep -q '^INPUT expect_rgb24=1' "$LOG_DIR/rx.log"; then
        STARTED=1; break
    fi
    sleep 0.1
done
[[ "$STARTED" == 1 ]] || { echo 'Display/receiver startup timed out'; exit 1; }
reg 0x60 1
"$PYTHON" "$SCRIPT_DIR/monitor_video_perf.py" --bar0 "$BAR0" --compressed > "$LOG_DIR/hardware.log" 2>&1 &
MONITOR_PID=$!
while kill -0 "$RX_PID" 2>/dev/null && kill -0 "$GST_PID" 2>/dev/null; do
    if [[ "$VIDEO_CAPTURE" == 1 ]]; then
        if [[ "$VIDEO_CAPTURE_NO_KEYS" == 1 ]]; then
            sleep 1
        else
            key=''
            if IFS= read -r -s -n 1 -t 1 key; then
                case "$key" in
                    p|P) "$PYTHON" "$SCRIPT_DIR/video_capture_ctl.py" "$LOG_DIR/capture.sock" snapshot || true;;
                    r|R) "$PYTHON" "$SCRIPT_DIR/video_capture_ctl.py" "$LOG_DIR/capture.sock" record-start || true;;
                    s|S) "$PYTHON" "$SCRIPT_DIR/video_capture_ctl.py" "$LOG_DIR/capture.sock" record-stop || true;;
                    i|I) "$PYTHON" "$SCRIPT_DIR/video_capture_ctl.py" "$LOG_DIR/capture.sock" status || true;;
                esac
            fi
        fi
    else
        sleep 1
    fi
    for off in 0xbc 0xc8 0xd8 0xdc 0xe0 0xe4; do
        VALUE=$(reg "$off")
        if (( VALUE != 0 )); then echo "Integrity error at BAR0+$off: $VALUE"; exit 1; fi
    done
    if [[ "$MODE" == 5 || "$MODE" == 6 || "$MODE" == 9 ]]; then
        OFF=0xf4; [[ "$MODE" != 6 ]] || OFF=0xf8; [[ "$MODE" != 9 ]] || OFF=0x120
        VALUE=$(reg "$OFF")
        if (( VALUE != 0 )); then echo "Preprocessing error: $VALUE"; exit 1; fi
    fi
done
echo 'Receiver or display exited; see logs.'
exit 1
