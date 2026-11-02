#!/bin/bash
# Back up the current modules and compile; never unload or load a driver.
set -euo pipefail
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR"
for cmd in sha256sum make modinfo uname tee; do
    command -v "$cmd" >/dev/null || { echo "Missing $cmd"; exit 1; }
done
sha256sum -c SHA256SUMS
[[ -f sgdma_drv/anlogic_pci.ko && -f v4l2_drv/milianke_v4l2.ko ]] || {
    echo 'Existing working modules missing; preserve the board modules before building.'; exit 1;
}
[[ -d /lib/modules/$(uname -r)/build ]] || { echo 'Matching kernel headers missing'; exit 1; }
if [[ -r /sys/module/anlogic_pci/srcversion ]]; then
    LOADED=$(cat /sys/module/anlogic_pci/srcversion)
    ON_DISK=$(modinfo -F srcversion sgdma_drv/anlogic_pci.ko)
    [[ "$LOADED" == "$ON_DISK" ]] || {
        echo 'Loaded driver differs from on-disk .ko; locate its working .ko before building.'; exit 1;
    }
fi
BACKUP=$(mktemp -d /home/linaro/dma-wait-backup.XXXXXX)
cp -p sgdma_drv/anlogic_pci.ko "$BACKUP/"
cp -p v4l2_drv/milianke_v4l2.ko "$BACKUP/"
sha256sum "$BACKUP/"*.ko > "$BACKUP/SHA256SUMS"
uname -a > "$BACKUP/kernel.log"
echo "Driver backup: $BACKUP"
make -C sgdma_drv 2>&1 | tee "$BACKUP/build.log"
[[ $(modinfo -F vermagic sgdma_drv/anlogic_pci.ko | awk '{print $1}') == "$(uname -r)" ]] || {
    echo 'New module kernel mismatch'; exit 1;
}
modinfo -p sgdma_drv/anlogic_pci.ko | grep '^st_c2h_wait_spin_us:'
echo "BUILD PASSED. The currently loaded driver is unchanged. Backup: $BACKUP"
echo 'Next: stop all video/camera users and follow DMA_WAIT_20261025.md to reload and compare.'
