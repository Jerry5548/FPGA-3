#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CC=${CC:-gcc}
CFLAGS=${CFLAGS:--O2 -Wall -Wextra}
$CC -std=c11 $CFLAGS "$ROOT/rk3576_lz77_rx.c" -pthread -o "$ROOT/rk3576_lz77_rx"
echo "built $ROOT/rk3576_lz77_rx"
