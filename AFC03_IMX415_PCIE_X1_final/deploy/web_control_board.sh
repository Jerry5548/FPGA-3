#!/usr/bin/env bash
# Small SSH command bridge for the local FPGA web console. It accepts only
# fixed playback/capture operations; it is not a general remote shell.
set -euo pipefail

# The browser authenticates as linaro, whose board policy grants NOPASSWD
# sudo. Playback and capture controls need root for /dev/mem and device nodes.
if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || { echo 'sudo is required for FPGA playback controls' >&2; exit 1; }
    sudo -n true 2>/dev/null || {
        echo 'Passwordless sudo is required for the linaro web-control account' >&2
        exit 1
    }
    exec sudo -n -- /bin/bash "$0" "$@"
fi

ACTION=${1:-}
DEPLOY=${2:-/home/linaro/deploy}
STATE_DIR=/tmp/fpga-video-web-control
PID_FILE=$STATE_DIR/player.pid
LOG_FILE=$STATE_DIR/player.log
SOCKET_FILE=$STATE_DIR/capture.sock
META_FILE=$STATE_DIR/player.meta
DMA_WAIT_PARAM=/sys/module/anlogic_pci/parameters/st_c2h_wait_spin_us
DMA_PROFILE_PARAM=/sys/module/anlogic_pci/parameters/st_c2h_profile
mkdir -p "$STATE_DIR"

dma_wait_status() {
    if [[ -r "$DMA_WAIT_PARAM" ]]; then
        echo 'DMA_WAIT_SUPPORTED=1'
        printf 'DMA_WAIT_US='; cat "$DMA_WAIT_PARAM"
    else
        echo 'DMA_WAIT_SUPPORTED=0'
        echo 'DMA_WAIT_US=unavailable'
    fi
    if [[ -r "$DMA_PROFILE_PARAM" ]]; then
        printf 'DMA_PROFILE='; cat "$DMA_PROFILE_PARAM"
    fi
}

apply_dma_wait() {
    local value=$1 actual
    case "$value" in 0|10|20) ;; *) echo 'DMA 等待预算只能为 0、10 或 20 微秒' >&2; return 2;; esac
    if [[ ! -w "$DMA_WAIT_PARAM" ]]; then
        if [[ "$value" == 0 && ! -e "$DMA_WAIT_PARAM" ]]; then
            echo '当前驱动没有 DMA 等待优化接口，使用原等待路径。'
            dma_wait_status
            return 0
        fi
        echo '当前驱动不支持或不能写入 DMA 等待预算。请加载已验证的候选驱动，或选择 0（关闭）。' >&2
        dma_wait_status
        return 2
    fi
    # Normal playback uses the timing-disabled configuration tested on board.
    if [[ -e "$DMA_PROFILE_PARAM" ]]; then
        if ! printf '0\n' > "$DMA_PROFILE_PARAM"; then
            echo '关闭 DMA 阶段计时失败，未修改等待预算。' >&2; return 2
        fi
        case "$(cat "$DMA_PROFILE_PARAM")" in 0|N|n) ;; *)
            echo 'DMA 计时关闭状态未通过读回核验。' >&2; return 2;;
        esac
    fi
    if ! printf '%s\n' "$value" > "$DMA_WAIT_PARAM"; then
        echo 'DMA 等待预算写入失败。' >&2; return 2
    fi
    actual=$(cat "$DMA_WAIT_PARAM")
    [[ "$actual" == "$value" ]] || { echo 'DMA 等待预算读回不一致。' >&2; return 2; }
    dma_wait_status
}

alive() {
    [[ -s "$PID_FILE" ]] || return 1
    local pid
    read -r pid < "$PID_FILE"
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

capture_socket() {
    if [[ -s "$SOCKET_FILE" && -S "$(cat "$SOCKET_FILE")" ]]; then
        cat "$SOCKET_FILE"
        return 0
    fi
    if [[ -f "$LOG_FILE" ]]; then
        local path
        path=$(sed -n 's/^Capture socket: //p' "$LOG_FILE" | tail -n 1)
        if [[ -n "$path" && -S "$path" ]]; then
            printf '%s\n' "$path" > "$SOCKET_FILE"
            printf '%s\n' "$path"
            return 0
        fi
    fi
    return 1
}

case "$ACTION" in
    ping)
        [[ -x "$DEPLOY/play_raw_video.sh" && -x "$DEPLOY/video_capture_ctl.py" || -f "$DEPLOY/play_raw_video.sh" && -f "$DEPLOY/video_capture_ctl.py" ]] || {
            echo "Deploy scripts not found under $DEPLOY" >&2; exit 2;
        }
        echo 'READY: board control scripts found'
        dma_wait_status
        ;;
    dma-wait-set)
        apply_dma_wait "${3-20}"
        echo 'DMA 等待预算已应用；仅影响符合条件的 LZ77 接收请求，停止播放后保留。'
        ;;
    start)
        SOURCE=${3:-raw}; MODE=${4:-0}; CONNECTOR=${5:-188}
        YOLO=${6:-0}; MODEL=${7:-/home/linaro/deploy/yolo/yolov5s_relu.rknn}
        KMS=${8:-1}
        DMA_WAIT=${9-0}
        [[ "$SOURCE" == raw || "$SOURCE" == lz77 ]] || { echo 'Invalid source' >&2; exit 2; }
        [[ "$MODE" =~ ^(0|1|2|3|4|5|6|8|9)$ ]] || { echo 'Invalid mode' >&2; exit 2; }
        [[ "$CONNECTOR" =~ ^[0-9]{1,6}$ ]] || { echo 'Invalid connector' >&2; exit 2; }
        [[ "$YOLO" == 0 || "$YOLO" == 1 ]] || { echo 'Invalid YOLO flag' >&2; exit 2; }
        [[ "$KMS" == 0 || "$KMS" == 1 ]] || { echo 'Invalid KMS flag' >&2; exit 2; }
        case "$DMA_WAIT" in 0|10|20) ;; *) echo 'Invalid DMA wait budget' >&2; exit 2;; esac
        [[ "$MODEL" =~ ^/[A-Za-z0-9_./-]+$ && "$MODEL" != *..* ]] || { echo 'Invalid model path' >&2; exit 2; }
        alive && { echo 'A playback session is already running' >&2; exit 3; }
        rm -f "$PID_FILE" "$SOCKET_FILE" "$META_FILE"
        : > "$LOG_FILE"
        PLAYER=$DEPLOY/play_raw_video.sh
        [[ "$SOURCE" != lz77 ]] || PLAYER=$DEPLOY/play_lz77_video.sh
        [[ -f "$PLAYER" ]] || { echo "Player missing: $PLAYER" >&2; exit 2; }
        if [[ "$SOURCE" == lz77 ]]; then
            apply_dma_wait "$DMA_WAIT"
        else
            echo 'RAW 链路不使用此 DMA 等待优化，保留板端现有参数。'
        fi
        if [[ "$YOLO" == 1 ]]; then
            nohup env VIDEO_CAPTURE=1 VIDEO_CAPTURE_NO_KEYS=1 VIDEO_CAPTURE_DIR=/mnt/tf/FPGA_Captures \
                YOLO_MODEL="$MODEL" YOLO_VIEW=stats YOLO_MAX_FPS=30 YOLO_BOX_TTL_MS=250 \
                YOLO_KMS_OVERLAY="$KMS" bash "$PLAYER" "$MODE" "$CONNECTOR" \
                </dev/null >> "$LOG_FILE" 2>&1 &
        else
            nohup env VIDEO_CAPTURE=1 VIDEO_CAPTURE_NO_KEYS=1 VIDEO_CAPTURE_DIR=/mnt/tf/FPGA_Captures \
                YOLO_MODEL= bash "$PLAYER" "$MODE" "$CONNECTOR" \
                </dev/null >> "$LOG_FILE" 2>&1 &
        fi
        pid=$!
        printf '%s\n' "$pid" > "$PID_FILE"
        printf '%s %s %s %s\n' "$SOURCE" "$MODE" "$CONNECTOR" "$YOLO" > "$META_FILE"
        sleep 1
        if ! kill -0 "$pid" 2>/dev/null; then
            rm -f "$PID_FILE"
            tail -n 30 "$LOG_FILE" >&2 || true
            exit 4
        fi
        echo "STARTED pid=$pid source=$SOURCE mode=$MODE connector=$CONNECTOR yolo=$YOLO"
        dma_wait_status
        ;;
    stop)
        if ! alive; then
            rm -f "$PID_FILE" "$SOCKET_FILE"
            echo 'STOPPED: no active playback session'
            dma_wait_status
            exit 0
        fi
        read -r pid < "$PID_FILE"
        # SIGINT may be inherited as ignored by a detached background job.
        # The player scripts trap SIGTERM and run their normal cleanup path.
        kill -TERM "$pid" 2>/dev/null || true
        for ((i=0; i<230; i++)); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null; then kill -KILL "$pid" 2>/dev/null || true; fi
        rm -f "$PID_FILE" "$SOCKET_FILE"
        echo 'STOPPED: playback shutdown requested; capture finalization may take a moment'
        dma_wait_status
        ;;
    status)
        dma_wait_status
        if alive; then
            read -r pid < "$PID_FILE"
            echo "PLAYBACK=running pid=$pid"
            [[ ! -f "$META_FILE" ]] || { printf 'SESSION='; cat "$META_FILE"; }
            capture_socket >/dev/null 2>&1 && echo 'CAPTURE=ready' || echo 'CAPTURE=starting'
        else
            echo 'PLAYBACK=stopped'
        fi
        if [[ -d /mnt/tf/FPGA_Captures ]]; then
            echo 'CAPTURE_DIR=/mnt/tf/FPGA_Captures'
            find /mnt/tf/FPGA_Captures -maxdepth 1 -type f 2>/dev/null | tail -n 8 | sed 's#^#FILE=#' || true
        else
            echo 'CAPTURE_DIR=unavailable (TF card may not be mounted)'
        fi
        [[ ! -f "$LOG_FILE" ]] || { echo '--- recent playback log ---'; tail -n 12 "$LOG_FILE"; }
        ;;
    snapshot|record-start|record-stop|capture-status)
        alive || { echo 'Playback is not running' >&2; exit 5; }
        sock=$(capture_socket) || { echo 'Capture control socket is not ready yet' >&2; exit 6; }
        case "$ACTION" in
            snapshot) ctl_action=snapshot;;
            record-start) ctl_action=record-start;;
            record-stop) ctl_action=record-stop;;
            capture-status) ctl_action=status;;
        esac
        python3 "$DEPLOY/video_capture_ctl.py" "$sock" "$ctl_action"
        ;;
    *)
        echo 'Usage: web_control_board.sh {ping|start|stop|status|dma-wait-set|snapshot|record-start|record-stop|capture-status} [args...]' >&2
        exit 2
        ;;
esac
