#!/bin/bash
# Uncompressed FPGA RGB24 through V4L2, compact measured FPS and optional YOLO.
# Usage: bash play_raw_video.sh [mode=1] [connector=188]
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PYTHON=${YOLO_PYTHON:-python3}
MODE=${1:-1}
CONNECTOR=${2:-188}
BAR0=${BAR0:-0x21200000}
DEVICE=${VIDEO_DEVICE:-/dev/video73}
IO_MODE=${V4L2_IO_MODE:-mmap}
FONT=${OSD_FONT_SIZE:-16}
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
case "$MODE" in 0|1|2|3|4|5|6|8|9) ;; *) echo 'Mode must be 0..6, 8, 9; 7 reserved'; exit 2;; esac
case "$CONNECTOR" in ''|*[!0-9]*) echo 'Invalid connector'; exit 2;; esac
case "$IO_MODE" in mmap|dmabuf) ;; *) echo 'V4L2_IO_MODE must be mmap or dmabuf'; exit 2;; esac
case "$FONT" in ''|*[!0-9]*) echo 'Invalid font size'; exit 2;; esac
(( FONT >= 8 && FONT <= 32 )) || { echo 'Font size must be 8..32'; exit 2; }
for cmd in busybox "$PYTHON" gst-inspect-1.0 fuser pgrep; do
    command -v "$cmd" >/dev/null || { echo "Missing command: $cmd"; exit 1; }
done
[[ -c "$DEVICE" ]] || { echo "V4L2 device missing: $DEVICE"; exit 1; }
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
"$PYTHON" "$SCRIPT_DIR/display_lz77_video.py" --check \
    --video-device "$DEVICE" --io-mode "$IO_MODE" --connector "$CONNECTOR" \
    --mode "$MODE" --font-size "$FONT" "${YOLO_ARGS[@]}" \
    "${CAPTURE_PREFLIGHT_ARGS[@]}" "${DISPLAY_ARGS[@]}"
ELEMENTS=(v4l2src queue fpsdisplaysink)
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
if fuser "$DEVICE" /dev/ANLOGIC-PCI0_c2h_0 2>/dev/null || pgrep -x gst-launch-1.0 >/dev/null; then
    echo 'Stop the existing V4L2/C2H/GStreamer reader first'; exit 1
fi
reg() { busybox devmem "$((BAR0 + $1))" 32 "${@:2}"; }
VERSION=$(reg 0x5c)
case "$((VERSION))" in "$((0x56440025))"|"$((0x56440026))"|"$((0x56440027))"|"$((0x56440028))"|"$((0x56440029))"|"$((0x56440030))"|"$((0x56440031))"|"$((0x56440032))") ;;
    *) echo "Expected FPGA v25/v26/v27/v28/v29/v30/v31/v32, got $VERSION"; exit 1;; esac
if [[ "$MODE" == 8 || "$MODE" == 9 ]]; then
    [[ ( "$((VERSION))" == "$((0x56440030))" || "$((VERSION))" == "$((0x56440031))" || "$((VERSION))" == "$((0x56440032))" ) ]] || { echo 'Modes 8/9 require FPGA v30/v31/v32'; exit 1; }
fi
LOG_DIR=$(mktemp -d /tmp/raw-video.XXXXXX)
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
DISPLAY_PID= MONITOR_PID=
snapshot() {
    for off in 0x5c 0x60 0x84 0x90 0xa4 0xa8 0xc0 0xc8 0xf4 0xf8; do
        printf 'BAR0+%s=' "$off"; reg "$off"
    done
    if [[ ( "$((VERSION))" == "$((0x56440030))" || "$((VERSION))" == "$((0x56440031))" || "$((VERSION))" == "$((0x56440032))" ) ]]; then
        printf 'BAR0+0x120='; reg 0x120
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
    if [[ -n "$DISPLAY_PID" ]]; then
        kill -TERM "$DISPLAY_PID" 2>/dev/null
        # Allow V4L2 STREAMOFF and the DMA driver's timeout to retire cleanly.
        for ((i=0;i<120;i++)); do
            kill -0 "$DISPLAY_PID" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$DISPLAY_PID" 2>/dev/null; then kill -KILL "$DISPLAY_PID" 2>/dev/null; fi
        wait "$DISPLAY_PID" 2>/dev/null
    fi
    snapshot > "$LOG_DIR/after.log"
    if [[ "$MODE" == 9 && ( "$((VERSION))" == "$((0x56440030))" || "$((VERSION))" == "$((0x56440031))" || "$((VERSION))" == "$((0x56440032))" ) ]]; then
        DEHAZE_ERRORS=$(reg 0x120)
        if (( DEHAZE_ERRORS != 0 )); then echo "Dehaze protocol errors: $DEHAZE_ERRORS"; result=1; fi
    fi
    dmesg | tail -100 > "$LOG_DIR/dmesg.log"
    chmod 644 "$LOG_DIR/"*.log
    tail -10 "$LOG_DIR/gst.log" 2>/dev/null
    echo "Stopped. Logs: $LOG_DIR"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
reg 0x60 0
# Keep resolution changes under V4L2 S_FMT, which updates its buffer geometry.
# Its STREAMON performs FPGA reset/enable; do not start a separate C2H reader.
bash "$SCRIPT_DIR/mode_control.sh" "$BAR0" "$MODE" 0
snapshot > "$LOG_DIR/before.log"
echo "Uncompressed 1080p + measured FPS; mode=$MODE. Ctrl+C to switch. Logs: $LOG_DIR"
"$PYTHON" "$SCRIPT_DIR/display_lz77_video.py" --video-device "$DEVICE" --io-mode "$IO_MODE" \
    --connector "$CONNECTOR" --mode "$MODE" --font-size "$FONT" "${YOLO_ARGS[@]}" "${DISPLAY_ARGS[@]}" \
    "${CAPTURE_ARGS[@]}" \
    > "$LOG_DIR/gst.log" 2>&1 &
DISPLAY_PID=$!
"$PYTHON" "$SCRIPT_DIR/monitor_video_perf.py" --bar0 "$BAR0" > "$LOG_DIR/hardware.log" 2>&1 &
MONITOR_PID=$!
set +e
if [[ "$VIDEO_CAPTURE" == 1 ]]; then
    while kill -0 "$DISPLAY_PID" 2>/dev/null; do
        if [[ "$VIDEO_CAPTURE_NO_KEYS" == 1 ]]; then
            sleep 1
        else
            key=''
            if IFS= read -r -s -n 1 -t 0.2 key; then
                case "$key" in
                    p|P) "$PYTHON" "$SCRIPT_DIR/video_capture_ctl.py" "$LOG_DIR/capture.sock" snapshot || true;;
                    r|R) "$PYTHON" "$SCRIPT_DIR/video_capture_ctl.py" "$LOG_DIR/capture.sock" record-start || true;;
                    s|S) "$PYTHON" "$SCRIPT_DIR/video_capture_ctl.py" "$LOG_DIR/capture.sock" record-stop || true;;
                    i|I) "$PYTHON" "$SCRIPT_DIR/video_capture_ctl.py" "$LOG_DIR/capture.sock" status || true;;
                esac
            fi
        fi
    done
    wait "$DISPLAY_PID"
    RESULT=$?
else
    wait "$DISPLAY_PID"
    RESULT=$?
fi
set -e
DISPLAY_PID=
exit "$RESULT"
