#!/bin/bash
# pcie_setup.sh — RK3576/RK3588 PCIe + FPGA 一键初始化脚本
# V4L2 模块: milianke_v4l2, SGDMA: anlogic_pci
# 智能模式：优先用预编译 .ko，内核版本不匹配时自动重编译
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SGDMA_KO="$SCRIPT_DIR/sgdma_drv/anlogic_pci.ko"
V4L2_KO="$SCRIPT_DIR/v4l2_drv/milianke_v4l2.ko"
KVER=$(uname -r)
BUILT_KVER_FILE="$SCRIPT_DIR/.built_kver"

# ── SoC 自动检测 ──
SOC_MODEL=$(cat /proc/device-tree/compatible 2>/dev/null | tr '\0' '\n' | head -1)
if echo "$SOC_MODEL" | grep -qi "rk3576"; then
    SOC="RK3576"
    PCIE_DEV="2a210000.pcie"
    BAR0=""
    PERST_GPIO=48
    POWER_GPIO=124
else
    SOC="RK3588"
    PCIE_DEV="fe150000.pcie"
    BAR0=0xf0200000
    PERST_GPIO=""
    POWER_GPIO=""
fi

PCIE_DRV="/sys/bus/platform/drivers/rk-pcie"

# FPGA 寄存器偏移
OFF_VERSION=0x5C
OFF_CTRL=0x60
OFF_SOURCE_SEL=0x80
OFF_CAM_STATUS=0x84
OFF_CAM_MODE=0x90
OFF_AE_GAIN=0x98

echo "============================================"
echo " Milianke PCIe FPGA Setup ($SOC)"
echo " Kernel: $KVER"
echo " PCIe:   $PCIE_DEV"
echo "============================================"

# ── RK3576: PCIe1 预初始化 ──
if [ "$SOC" = "RK3576" ]; then
    echo ""
    echo ">>> [0/5] RK3576 PCIe1 GPIO 初始化..."

    PCIE1_DT_STATUS=$(cat /sys/firmware/devicetree/base/pcie@2a210000/status 2>/dev/null | tr -d '\0' || echo "not_found")
    if [ "$PCIE1_DT_STATUS" != "okay" ]; then
        echo "    ? pcie1 设备树 status=$PCIE1_DT_STATUS"
        echo "    需要先运行: $SCRIPT_DIR/pcie1_enable.sh"
        echo "    然后重启系统"
        if [ -f "$SCRIPT_DIR/pcie1_enable.sh" ]; then
            bash "$SCRIPT_DIR/pcie1_enable.sh" --patch-only
            echo ""
            echo "    DTB 已修补，请重启后再运行此脚本"
        fi
        exit 1
    fi

    if [ -n "$POWER_GPIO" ]; then
        if [ ! -d "/sys/class/gpio/gpio${POWER_GPIO}" ]; then
            echo "$POWER_GPIO" > /sys/class/gpio/export 2>/dev/null || true
            sleep 0.1
        fi
        if [ -d "/sys/class/gpio/gpio${POWER_GPIO}" ]; then
            echo "out" > "/sys/class/gpio/gpio${POWER_GPIO}/direction" 2>/dev/null || true
            echo "1" > "/sys/class/gpio/gpio${POWER_GPIO}/value" 2>/dev/null || true
            echo "    vcc3v3_pcie: gpio-${POWER_GPIO} = HIGH"
        fi
    fi

    if [ -n "$PERST_GPIO" ]; then
        # 检查 DTS 中是否已定义 reset-gpios（若有则内核驱动自行管理，此处仅做电平初始化后释放）
        DTS_HAS_RESET_GPIO=$(cat /sys/firmware/devicetree/base/pcie@2a210000/reset-gpios 2>/dev/null | wc -c)

        if [ ! -d "/sys/class/gpio/gpio${PERST_GPIO}" ]; then
            echo "$PERST_GPIO" > /sys/class/gpio/export 2>/dev/null || true
            sleep 0.1
        fi
        if [ -d "/sys/class/gpio/gpio${PERST_GPIO}" ]; then
            echo "out" > "/sys/class/gpio/gpio${PERST_GPIO}/direction" 2>/dev/null || true
            echo "0" > "/sys/class/gpio/gpio${PERST_GPIO}/value" 2>/dev/null || true
            sleep 0.1
            echo "1" > "/sys/class/gpio/gpio${PERST_GPIO}/value" 2>/dev/null || true
            echo "    PERST#: gpio-${PERST_GPIO} toggled (reset pulse)"
        fi

        # 关键：释放 GPIO 给内核 PCIe 驱动使用（否则 bind 时 devm_gpiod_get → EBUSY）
        if [ -d "/sys/class/gpio/gpio${PERST_GPIO}" ]; then
            echo "$PERST_GPIO" > /sys/class/gpio/unexport 2>/dev/null || true
            echo "    PERST#: gpio-${PERST_GPIO} unexported (释放给内核驱动)"
        fi
        sleep 0.2
    fi
fi

# ── Step 0: 智能 .ko 检测（含完整性验证） ──
# 验证单个 .ko 文件：存在 + ELF 格式 + modinfo 可读 + 内核版本匹配
verify_ko() {
    local ko_path="$1"
    local ko_name=$(basename "$ko_path")

    if [ ! -f "$ko_path" ]; then
        echo "    ? $ko_name: 不存在"
        return 1
    fi

    # 文件大小检查（< 4KB 几乎肯定是截断的）
    local fsize=$(stat -c%s "$ko_path" 2>/dev/null || echo 0)
    if [ "$fsize" -lt 4096 ]; then
        echo "    ? $ko_name: 文件过小 (${fsize}B)，可能已损坏"
        return 1
    fi

    # ELF 魔数检查
    local magic=$(hexdump -n4 -e '4/1 "%02x"' "$ko_path" 2>/dev/null)
    if [ "$magic" != "7f454c46" ]; then
        echo "    ? $ko_name: 非 ELF 格式（文件损坏）"
        return 1
    fi

    # modinfo 验证（能解析模块元数据）
    local ko_kver=$(modinfo -F vermagic "$ko_path" 2>/dev/null | awk '{print $1}')
    if [ -z "$ko_kver" ]; then
        echo "    ? $ko_name: modinfo 读取失败（文件损坏）"
        return 1
    fi

    # 内核版本匹配
    if [ "$ko_kver" != "$KVER" ]; then
        echo "    ? $ko_name: 内核版本不匹配 (模块=$ko_kver, 当前=$KVER)"
        return 1
    fi

    echo "    ? $ko_name: OK (${fsize}B, kernel $ko_kver)"
    return 0
}

echo ""
echo ">>> [0/5] 驱动模块完整性检查..."
NEED_BUILD=0
verify_ko "$SGDMA_KO" || NEED_BUILD=1
verify_ko "$V4L2_KO"  || NEED_BUILD=1

if [ "$NEED_BUILD" -eq 1 ]; then
    echo ""
    echo ">>> 需要重新编译驱动..."
    if [ ! -f "$SCRIPT_DIR/build_drivers.sh" ]; then
        echo "    ERROR: build_drivers.sh 不存在！无法自动编译"
        echo "    请手动运行: cd $SCRIPT_DIR && bash build_drivers.sh"
        exit 1
    fi

    # 清理可能损坏的旧 .ko
    rm -f "$SGDMA_KO" "$V4L2_KO" "$BUILT_KVER_FILE" 2>/dev/null || true

    echo "    >>> 执行 build_drivers.sh ..."
    if ! bash "$SCRIPT_DIR/build_drivers.sh"; then
        echo "    ERROR: 驱动编译失败！"
        echo "    请检查内核头文件是否安装: ls /lib/modules/$KVER/build/"
        exit 1
    fi

    # 编译后再次验证
    echo ""
    echo ">>> 编译完成，重新验证..."
    VERIFY_OK=1
    verify_ko "$SGDMA_KO" || VERIFY_OK=0
    verify_ko "$V4L2_KO"  || VERIFY_OK=0
    if [ "$VERIFY_OK" -eq 0 ]; then
        echo "    ERROR: 编译后 .ko 仍然无效，请手动排查"
        exit 1
    fi
else
    echo "    所有模块验证通过"
fi

# ── Step 1: 卸载已有驱动 ──
echo ""
echo ">>> [1/5] Unloading existing drivers..."
rmmod milianke_v4l2 2>/dev/null && echo "    Removed milianke_v4l2" || true
rmmod anlogic_v4l2  2>/dev/null && echo "    Removed anlogic_v4l2"  || true
rmmod anlogic_pci   2>/dev/null && echo "    Removed anlogic_pci"   || true

# ── Step 2: PCIe 链路检查（避免不必要的 unbind/rebind）──
echo ""
echo ">>> [2/5] PCIe 链路检查..."

# 先看 FPGA 设备是否已经在 PCIe 总线上可见
FPGA_VISIBLE=0
if lspci -d 1edb:abcd 2>/dev/null | grep -q "1edb"; then
    FPGA_VISIBLE=1
elif lspci 2>/dev/null | grep -q .; then
    FPGA_VISIBLE=1
fi

if [ "$FPGA_VISIBLE" -eq 1 ]; then
    echo "    FPGA 设备已在 PCIe 总线上，跳过 rebind"
    echo "    $(lspci -d 1edb:abcd 2>/dev/null || lspci 2>/dev/null | head -1)"
else
    echo "    FPGA 设备不可见，执行 unbind/rebind..."
    if [ -d "${PCIE_DRV}/${PCIE_DEV}" ]; then
        echo "$PCIE_DEV" > "$PCIE_DRV/unbind" 2>/dev/null || true
        sleep 2
    fi

    # 关键：bind 前确保 PERST GPIO 未被 sysfs 占用（否则内核驱动 devm_gpiod_get → EBUSY → 内核崩溃）
    if [ "$SOC" = "RK3576" ] && [ -n "$PERST_GPIO" ]; then
        if [ -d "/sys/class/gpio/gpio${PERST_GPIO}" ]; then
            echo "$PERST_GPIO" > /sys/class/gpio/unexport 2>/dev/null || true
            echo "    释放 GPIO-${PERST_GPIO} (PERST#) 避免与内核驱动冲突"
            sleep 0.1
        fi
    fi

    if ! echo "$PCIE_DEV" > "$PCIE_DRV/bind" 2>/dev/null; then
        echo "    WARNING: bind 失败 (可能 -EBUSY)，等待 3s 后重试..."
        sleep 3
        # 确保完全释放
        echo "$PCIE_DEV" > "$PCIE_DRV/unbind" 2>/dev/null || true
        sleep 2
        if ! echo "$PCIE_DEV" > "$PCIE_DRV/bind" 2>/dev/null; then
            echo "    ERROR: PCIe bind 二次失败！"
            echo "    dmesg | tail -10:"
            dmesg | tail -10
            exit 1
        fi
    fi
    sleep 2

    if lspci -d 1edb:abcd 2>/dev/null | grep -q "1edb"; then
        echo "    OK: $(lspci -d 1edb:abcd)"
    elif lspci 2>/dev/null | grep -q .; then
        echo "    Found PCIe device: $(lspci | head -1)"
    else
        echo "    ERROR: FPGA device not found on PCIe bus!"
        exit 1
    fi
fi

# ── 动态发现 BAR0 地址 ──
if [ -z "$BAR0" ]; then
    PCIE_BDF=$(lspci -d 1edb:abcd 2>/dev/null | awk '{print $1}')
    [ -z "$PCIE_BDF" ] && PCIE_BDF=$(lspci 2>/dev/null | head -1 | awk '{print $1}')
    if [ -n "$PCIE_BDF" ]; then
        BAR0_HEX=$(cat "/sys/bus/pci/devices/0000:${PCIE_BDF}/resource" 2>/dev/null | head -1 | awk '{print $1}')
        if [ -n "$BAR0_HEX" ]; then
            BAR0=$BAR0_HEX
            echo "    BAR0 detected: $BAR0"
        fi
    fi
fi

if [ -n "$BAR0" ]; then
    REG_VERSION=$((BAR0 + OFF_VERSION))
    REG_CTRL=$((BAR0 + OFF_CTRL))
    REG_SOURCE_SEL=$((BAR0 + OFF_SOURCE_SEL))
    REG_CAM_STATUS=$((BAR0 + OFF_CAM_STATUS))
    REG_CAM_MODE=$((BAR0 + OFF_CAM_MODE))
    REG_AE_GAIN=$((BAR0 + OFF_AE_GAIN))
fi

# ── Step 3: 加载 SGDMA 驱动 ──
echo ""
echo ">>> [3/5] Loading anlogic_pci.ko..."
if ! insmod "$SGDMA_KO" poll_mode=1 enable_st_c2h_credit=1 desc_blen_max=1048576; then
    echo "    ERROR: insmod anlogic_pci.ko 失败！"
    echo "    尝试 dmesg 查看详情: dmesg | tail -20"
    echo "    可能需要: rm -f $SGDMA_KO && bash $SCRIPT_DIR/build_drivers.sh"
    exit 1
fi
# device_create() completes just after insmod returns on this kernel.  Wait
# for the actual Anlogic node names; this driver does not use /dev/sgdma*.
SGDMA_C2H_DEV=""
for _i in $(seq 1 30); do
    if [ -c /dev/ANLOGIC-PCI0_c2h_0 ]; then
        SGDMA_C2H_DEV=/dev/ANLOGIC-PCI0_c2h_0
        break
    fi
    sleep 0.1
done
if [ -z "$SGDMA_C2H_DEV" ]; then
    echo "    ERROR: anlogic_pci probe did not create /dev/ANLOGIC-PCI0_c2h_0."
    echo "    Check: dmesg | tail -80"
    echo "    Do not continue with V4L2 or mode_control until this is fixed."
    exit 1
fi
echo "    C2H device: $SGDMA_C2H_DEV"
echo "    OK: $(lsmod | grep anlogic_pci | head -1)"

# ── Step 4: 加载 V4L2 驱动 ──
echo ""
echo ">>> [4/5] Loading milianke_v4l2.ko..."
if ! insmod "$V4L2_KO"; then
    echo "    WARNING: insmod milianke_v4l2.ko 失败（SGDMA 仍可用于 DMA 测速）"
    echo "    V4L2 设备将不可用"
else
    echo "    OK"
fi
sleep 1

# ── Step 5: 配置 FPGA (1080p, 不再默认 4K) ──
echo ""
echo ">>> [5/5] Configuring FPGA..."
if [ -n "$BAR0" ]; then
    busybox devmem $REG_CAM_MODE 32 0      # cam_mode=0 (1080p@60)
    # Start with a conservative analog gain. 100 (about 30 dB) clips bright
    # scenes on the current IMX415 setup; raise it only for dark scenes.
    busybox devmem $REG_AE_GAIN 32 30
    sleep 0.2
    busybox devmem $REG_CTRL 32 1          # enable pipeline

    VERSION=$(busybox devmem $REG_VERSION)
    STATUS=$(busybox devmem $REG_CAM_STATUS)
    GAIN=$(busybox devmem $REG_AE_GAIN)
else
    echo "    SKIP: BAR0 未知"
    VERSION="N/A"
    STATUS="N/A"
    GAIN="N/A"
fi

echo ""
echo "============================================"
echo " Milianke PCIe Setup Complete!"
echo "  VERSION:    $VERSION"
echo "  CAM_STATUS: $STATUS"
echo "  AE_GAIN:    $GAIN"
echo "============================================"

# 查找 V4L2 设备
if command -v v4l2-ctl &>/dev/null; then
    V4L2_DEV=$(v4l2-ctl --list-devices 2>&1 | grep -A1 -i "milianke\|anlogic" | grep "/dev/video" | head -1 | sed 's/^[[:space:]]*//' | tr -d '[:space:]')
fi
[ -z "$V4L2_DEV" ] && V4L2_DEV="/dev/video1"

CONNECTOR=""
if command -v modetest &>/dev/null; then
    CONNECTOR=$(modetest -M rockchip -c 2>/dev/null | grep "connected" | grep -v "disconnected" | head -1 | awk '{print $1}')
fi
[ -z "$CONNECTOR" ] && CONNECTOR="188"

echo ""
echo "  V4L2 device: $V4L2_DEV"
echo "  HDMI connector: $CONNECTOR"
echo ""
echo "To display camera (1080p):"
echo "  gst-launch-1.0 v4l2src device=$V4L2_DEV ! 'video/x-raw,width=1920,height=1080,format=RGB' ! videoconvert ! kmssink connector-id=$CONNECTOR"
echo ""
echo "To switch resolution:"
echo "  v4l2-ctl -d $V4L2_DEV --set-fmt-video=width=1920,height=1080,pixelformat=RGB3  # 1080p"
echo "  v4l2-ctl -d $V4L2_DEV --set-fmt-video=width=1280,height=720,pixelformat=RGB3   # 720p"
echo ""
echo "To change brightness:"
echo "  v4l2-ctl -d $V4L2_DEV --set-ctrl=gain=<0-240>"
