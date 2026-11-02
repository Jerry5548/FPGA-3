#!/bin/bash
# build_drivers.sh — 编译 anlogic_pci.ko 和 milianke_v4l2.ko
# 在 RK3576/RK3588 板上运行，自动检测并安装缺失依赖
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SGDMA_DIR="$SCRIPT_DIR/sgdma_drv"
V4L2_DIR="$SCRIPT_DIR/v4l2_drv"
KVER=$(uname -r)
KHEADERS="/lib/modules/$KVER/build"

ensure_kernel_headers_link() {
    if [ -f "$KHEADERS/Makefile" ]; then
        return 0
    fi

    KMAJOR_MINOR=$(echo "$KVER" | awk -F. '{print $1"."$2}')
    for cand in \
        "/usr/src/linux-headers-$KVER" \
        "/usr/src/linux-headers-$KMAJOR_MINOR-rockchip" \
        "/usr/src/linux-headers-rockchip"; do
        if [ -f "$cand/Makefile" ]; then
            mkdir -p "/lib/modules/$KVER"
            ln -sfn "$cand" "$KHEADERS"
            echo "    FIX: linked $KHEADERS -> $cand"
            return 0
        fi
    done

    return 1
}

install_kernel_headers_if_needed() {
    if ensure_kernel_headers_link; then
        return 0
    fi

    KMAJOR_MINOR=$(echo "$KVER" | awk -F. '{print $1"."$2}')

    if command -v apt-get &>/dev/null; then
        for pkg in \
            "linux-headers-$KVER" \
            "linux-headers-$KMAJOR_MINOR-rockchip" \
            "linux-headers-rockchip" \
            "linux-headers-arm64"; do
            if apt-cache show "$pkg" >/dev/null 2>&1; then
                echo "    TRY: install $pkg"
                apt-get update -qq
                apt-get install -y -qq "$pkg"
                break
            fi
        done
    elif command -v dnf &>/dev/null; then
        dnf install -y kernel-headers
    else
        echo "    ERROR: Unknown package manager"
        return 1
    fi

    ensure_kernel_headers_link
}

echo "========================================"
echo " Milianke Driver Build"
echo " Kernel: $KVER"
echo "========================================"

# 确保有 kernel headers
echo ""
echo ">>> Checking kernel headers..."
if ! ensure_kernel_headers_link; then
    echo "    Kernel headers not found, installing..."
    install_kernel_headers_if_needed
fi
echo "    OK: $KHEADERS"

# 编译 SGDMA 驱动 (anlogic_pci.ko)
echo ""
echo ">>> Building SGDMA driver (anlogic_pci.ko)..."
make -C "$SGDMA_DIR" clean 2>/dev/null || true
make -C "$SGDMA_DIR"
echo "    OK: $(ls -lh "$SGDMA_DIR/anlogic_pci.ko" | awk '{print $5, $NF}')"

# 编译 V4L2 驱动 (milianke_v4l2.ko)
echo ""
echo ">>> Building V4L2 driver (milianke_v4l2.ko)..."
make -C "$V4L2_DIR" clean 2>/dev/null || true
make -C "$V4L2_DIR"
echo "    OK: $(ls -lh "$V4L2_DIR/milianke_v4l2.ko" | awk '{print $5, $NF}')"

# 记录编译的内核版本
echo "$KVER" > "$SCRIPT_DIR/.built_kver"

echo ""
echo ">>> Build complete!"
