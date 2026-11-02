#!/bin/bash
# Read-only kmssink/DRM inventory. Does not set modes or alter plane properties.
set -u

OUT=${1:-/tmp/kms-overlay-diag.log}
exec > >(tee "$OUT") 2>&1
echo "KMS/DRM overlay inventory: $(date)"
echo "Kernel: $(uname -a)"

if command -v gst-inspect-1.0 >/dev/null 2>&1; then
    echo '=== kmssink pad formats and properties ==='
    gst-inspect-1.0 kmssink
else
    echo 'MISSING: gst-inspect-1.0'
fi

if command -v modetest >/dev/null 2>&1; then
    echo '=== DRM connectors, CRTCs, planes, formats and plane properties ==='
    # -p/-c enumerate resources only; no modesetting or property writes.
    modetest -M rockchip -p -c
else
    echo 'MISSING: modetest; install libdrm-tests to enumerate DRM planes.'
fi

echo '=== DRM debugfs state, when mounted/readable ==='
found=0
for state in /sys/kernel/debug/dri/*/state; do
    [ -r "$state" ] || continue
    found=1
    echo "--- $state ---"
    cat "$state"
done
[ "$found" -eq 1 ] || echo 'No readable DRM debugfs state; optional.'
echo "Saved report: $OUT"
