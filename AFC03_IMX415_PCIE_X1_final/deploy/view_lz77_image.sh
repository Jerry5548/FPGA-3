#!/bin/bash
# Capture one CRC-checked LZ77-decoded RGB24 image, save BMP, optionally display.
# Usage: bash view_lz77_image.sh [mode=6] [connector=188] [--save-only]
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MODE=${1:-6}
CONNECTOR=${2:-188}
ACTION=${3:-display}
BAR0=${BAR0:-0x21200000}
case "$MODE" in 0|1|2|3|4|5|6|8|9) ;; *) echo 'Mode must be 0..6, 8, 9' >&2; exit 2;; esac
case "$CONNECTOR" in ''|*[!0-9]*) echo 'Connector must be a decimal integer' >&2; exit 2;; esac
case "$ACTION" in display|--save-only) ;; *) echo 'Third argument must be --save-only or omitted' >&2; exit 2;; esac
command -v python3 >/dev/null || { echo 'python3 is required'; exit 1; }
if ! grep -q 'OUTPUT_PREFIX=' "$SCRIPT_DIR/test_lz77_frames.sh"; then
    echo 'Copy the updated test_lz77_frames.sh with optional fourth output-prefix argument first.' >&2
    exit 1
fi
BASE=/home/linaro/lz77-images
mkdir -p -- "$BASE"
OUT=$(mktemp -d "$BASE/mode${MODE}.XXXXXX")
# Only this newly created directory is made readable for linaro/Xftp.
chmod 755 "$OUT"
echo "Decoded image directory: $OUT"
# Same validated reset/calibration/receiver-first sequence as the frame test.
# The test stops the producer and exits the C2H receiver before playback.
if bash "$SCRIPT_DIR/test_lz77_frames.sh" "$BAR0" 1 "$MODE" "$OUT/frame" > "$OUT/test.log" 2>&1; then
    cat "$OUT/test.log"
else
    RESULT=$?
    cat "$OUT/test.log"
    echo "Integrity test failed; do not treat images as accepted. See $OUT/test.log" >&2
    exit "$RESULT"
fi
shopt -s nullglob
FILES=("$OUT"/frame_*.bin)
if [ "${#FILES[@]}" -ne 1 ]; then
    echo "Expected exactly one decoded .bin file in $OUT" >&2; exit 1
fi
RAW=${FILES[0]}
python3 - "$RAW" <<'PY'
import struct
import sys
from pathlib import Path

path = Path(sys.argv[1])
raw = path.read_bytes()
w, h = 1920, 1080
if len(raw) != w * h * 3:
    raise SystemExit(f'RGB24 length mismatch: {len(raw)} != {w*h*3}')
# BMP stores BGR pixels. Negative height preserves the original top-down rows.
# At width 1920 the 5760-byte row already meets BMP four-byte alignment.
bgr = bytearray(len(raw))
bgr[0::3], bgr[1::3], bgr[2::3] = raw[2::3], raw[1::3], raw[0::3]
header = struct.pack('<2sIHHI', b'BM', 54 + len(bgr), 0, 0, 54)
header += struct.pack('<IiiHHIIiiII', 40, w, -h, 1, 24, 0, len(bgr), 2835, 2835, 0, 0)
bmp = path.with_suffix('.bmp')
bmp.write_bytes(header + bgr)
print(f'Decoded RGB24: {path}')
print(f'View/download BMP: {bmp}')
PY
chmod 644 "$RAW" "${RAW%.bin}.bmp" "$OUT/test.log"
echo "Images saved: $OUT"
if [ "$ACTION" = --save-only ]; then exit 0; fi
if ! command -v gst-launch-1.0 >/dev/null || ! command -v gst-inspect-1.0 >/dev/null; then
    echo 'GStreamer unavailable. Download the saved BMP with Xftp.' >&2; exit 1
fi
for ELEMENT in filesrc rawvideoparse imagefreeze videoconvert kmssink; do
    if ! gst-inspect-1.0 "$ELEMENT" >/dev/null 2>&1; then
        echo "Missing GStreamer element: $ELEMENT. The BMP is saved for Xftp viewing." >&2
        exit 1
    fi
done
echo 'Displaying the saved decoded still image (not live video). Press Ctrl+C to exit.'
gst-launch-1.0 filesrc location="$RAW" ! \
    rawvideoparse format=rgb width=1920 height=1080 framerate=1/1 ! \
    imagefreeze ! 'video/x-raw,framerate=10/1' ! \
    videoconvert ! kmssink connector-id="$CONNECTOR" sync=true
