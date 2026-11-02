#!/bin/sh
# Build and run the offline protocol test on RK3576.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CC=${CC:-gcc}
"$ROOT/build.sh"
python3 "$ROOT/make_test_frame.py"
python3 "$ROOT/test_lz77_frame.py"
python3 "$ROOT/test_crc_error.py"
python3 "$ROOT/test_stream_parser.py"
mkdir -p "$ROOT/test_vectors/decoded"
"$ROOT/rk3576_lz77_rx" -d "$ROOT/test_vectors/sample_frame.lz77" -o "$ROOT/test_vectors/decoded/frame" -n 1 -v
python3 "$ROOT/test_rgb24_geometry.py" --receiver "$ROOT/rk3576_lz77_rx"
