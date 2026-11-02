#!/bin/bash
# KMS plane test. DISPLAY_SECONDS=0 is test-only; a positive value briefly
# displays a small moving box and disables the plane on exit.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICE=${1:-/dev/dri/card0}
CONNECTOR=${2:-188}
PLANE=${3:-108}
DISPLAY_SECONDS=${4:-0}
BIN=${TMPDIR:-/tmp}/test_kms_overlay_atomic.$$
trap 'rm -f "$BIN"' EXIT

if ! command -v cc >/dev/null 2>&1 || ! pkg-config --exists libdrm; then
    echo 'Missing C compiler or libdrm development files (cc, pkg-config, libdrm headers).' >&2
    echo 'Install the board build prerequisites, then rerun this script.' >&2
    exit 2
fi

cc -O2 -Wall -Wextra -Werror \
    $(pkg-config --cflags libdrm) \
    "$SCRIPT_DIR/test_kms_overlay_atomic.c" \
    -o "$BIN" $(pkg-config --libs libdrm)
"$BIN" "$DEVICE" "$CONNECTOR" "$PLANE" "$DISPLAY_SECONDS"
