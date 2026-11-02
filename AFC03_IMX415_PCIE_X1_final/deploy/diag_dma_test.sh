#!/bin/bash
# diag_dma_test.sh — Direct C2H DMA test (bypass V4L2)
BAR0=0xf0200000
REG_CTRL=$((BAR0+0x60))
REG_CAM_MODE=$((BAR0+0x90))

echo "=== Direct DMA C2H Test ==="

# 1. Unload V4L2 to free C2H device
rmmod anlogic_v4l2 2>/dev/null && echo "V4L2 unloaded" || echo "V4L2 not loaded"

# 2. Configure FPGA for 4K
busybox devmem $REG_CAM_MODE 32 1   # 4K mode
busybox devmem $REG_CTRL 32 1       # enable pipeline
sleep 1

# 3. Check DBG_STATE during active pipeline
echo "DBG_STATE: $(busybox devmem $((BAR0+0x74)))"
echo "CTRL:      $(busybox devmem $((BAR0+0x60)))"

# 4. Try direct DMA read
echo ""
echo "--- Attempting 64KB C2H DMA read ---"
if [ -c /dev/sgdma0_c2h_0 ]; then
    dd if=/dev/sgdma0_c2h_0 of=/tmp/dma_test.bin bs=4096 count=16 2>&1
    if [ -f /tmp/dma_test.bin ]; then
        SIZE=$(stat -c%s /tmp/dma_test.bin 2>/dev/null || echo 0)
        echo "Read: $SIZE bytes"
        hexdump -C /tmp/dma_test.bin | head -4
        echo "..."
        hexdump -C /tmp/dma_test.bin | tail -4
    else
        echo "No output file"
    fi
else
    echo "/dev/sgdma0_c2h_0 not found!"
    ls /dev/sgdma* 2>/dev/null || echo "No sgdma devices"
fi

# 5. Read debug registers after DMA test
echo ""
echo "--- After DMA test ---"
echo "FRAME_COUNT : $(busybox devmem $((BAR0+0x50)))"
echo "DROP_COUNT  : $(busybox devmem $((BAR0+0x68)))"
echo "DMA_BEAT    : $(busybox devmem $((BAR0+0x7C)))"
echo "DBG_STATE   : $(busybox devmem $((BAR0+0x74)))"

# 6. Disable
busybox devmem $REG_CTRL 32 0
echo "Pipeline disabled"
