#!/bin/bash
# test_1080p.sh — Test 1080p mode with milianke_v4l2 driver
# 自动检测 BAR0 地址

# 动态发现 BAR0
PCIE_BDF=$(lspci -d 1edb:abcd 2>/dev/null | awk '{print $1}')
if [ -n "$PCIE_BDF" ]; then
    BAR0=$(cat "/sys/bus/pci/devices/0000:${PCIE_BDF}/resource" 2>/dev/null | head -1 | awk '{print $1}')
fi
[ -z "$BAR0" ] && BAR0=0xf0200000

REG_CTRL=$((BAR0+0x60))
REG_CAM_MODE=$((BAR0+0x90))

# Disable pipeline
busybox devmem $REG_CTRL 32 0

# Unload V4L2 if loaded
rmmod milianke_v4l2 2>/dev/null

# Set 1080p mode BEFORE loading V4L2
busybox devmem $REG_CAM_MODE 32 0    # mode 0 = 1080p
busybox devmem $REG_CTRL 32 1        # enable
sleep 1

# Check resolution
W=$(busybox devmem $((BAR0+0x44)))
H=$(busybox devmem $((BAR0+0x48)))
echo "FPGA resolution: $W x $H"

# Load V4L2 driver
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
insmod "$SCRIPT_DIR/v4l2_drv/milianke_v4l2.ko"
sleep 1

# Find V4L2 device
V4L2_DEV=$(v4l2-ctl --list-devices 2>&1 | grep -A1 -i "milianke" | grep "/dev/video" | head -1 | sed 's/^[[:space:]]*//' | tr -d '[:space:]')
[ -z "$V4L2_DEV" ] && V4L2_DEV="/dev/video1"

# Check V4L2 format
v4l2-ctl -d $V4L2_DEV --get-fmt-video 2>&1

# Try capturing 10 frames
echo ""
echo "--- Capturing 10 frames at 1080p ---"
gst-launch-1.0 v4l2src device=$V4L2_DEV num-buffers=10 \
  ! 'video/x-raw,width=1920,height=1080,format=RGB' \
  ! fakesink 2>&1
echo ""
echo "--- Done ---"
dmesg | grep milianke-v4l2 | tail -5
