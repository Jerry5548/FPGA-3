#!/bin/bash
# pack.sh — 打包预编译 .ko + 脚本为自包含 tar 包
# 在 RK3588 上编译完成后运行，生成可直接部署的 tar 包
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KVER=$(uname -r)
SGDMA_KO="$SCRIPT_DIR/sgdma_drv/anlogic_pci.ko"
V4L2_KO="$SCRIPT_DIR/v4l2_drv/anlogic_v4l2.ko"
TARNAME="anlogic_deploy_${KVER}.tar.gz"

echo "============================================"
echo " Anlogic Deploy Packager"
echo " Kernel: $KVER"
echo "============================================"

# 检查 .ko 文件存在
if [ ! -f "$SGDMA_KO" ]; then
    echo "ERROR: $SGDMA_KO not found!"
    echo "Run build_drivers.sh first."
    exit 1
fi
if [ ! -f "$V4L2_KO" ]; then
    echo "ERROR: $V4L2_KO not found!"
    echo "Run build_drivers.sh first."
    exit 1
fi

# 检查 .ko 与当前内核匹配
if [ -f "$SCRIPT_DIR/.built_kver" ]; then
    BUILT_KVER=$(cat "$SCRIPT_DIR/.built_kver")
    if [ "$BUILT_KVER" != "$KVER" ]; then
        echo "WARNING: .ko built for $BUILT_KVER, running $KVER"
        echo "Rebuild with ./build_drivers.sh first!"
        exit 1
    fi
else
    # 无版本文件，用 modinfo 验证后创建
    KO_KVER=$(modinfo -F vermagic "$SGDMA_KO" 2>/dev/null | awk '{print $1}')
    if [ "$KO_KVER" != "$KVER" ]; then
        echo "WARNING: .ko vermagic=$KO_KVER, running $KVER"
        echo "Rebuild with ./build_drivers.sh first!"
        exit 1
    fi
    echo "$KVER" > "$SCRIPT_DIR/.built_kver"
fi

# 打包：脚本 + 预编译 .ko + 内核版本标记
echo ""
echo "Packing..."
cd "$SCRIPT_DIR"
tar czf "/tmp/$TARNAME" \
    --transform='s|^|anlogic_deploy/|' \
    pcie_setup.sh \
    build_drivers.sh \
    pack.sh \
    .built_kver \
    sgdma_drv/anlogic_pci.ko \
    v4l2_drv/anlogic_v4l2.ko

# 同时生成全源码包（可在不同内核版本下重编译）
TARNAME_FULL="anlogic_deploy_full_${KVER}.tar.gz"
tar czf "/tmp/$TARNAME_FULL" \
    --transform='s|^|anlogic_deploy/|' \
    --exclude='*.o' \
    --exclude='*.cmd' \
    --exclude='.tmp_versions' \
    --exclude='modules.order' \
    --exclude='Module.symvers' \
    pcie_setup.sh \
    build_drivers.sh \
    pack.sh \
    .built_kver \
    sgdma_drv/ \
    v4l2_drv/

echo ""
echo "============================================"
echo " Package created!"
echo ""
echo " Prebuilt (fast, kernel $KVER only):"
echo "   /tmp/$TARNAME ($(du -h /tmp/$TARNAME | cut -f1))"
echo ""
echo " Full source (any kernel, needs gcc):"
echo "   /tmp/$TARNAME_FULL ($(du -h /tmp/$TARNAME_FULL | cut -f1))"
echo "============================================"
echo ""
echo "Deploy on new machine:"
echo "  scp /tmp/$TARNAME root@<target>:/root/"
echo "  ssh root@<target> 'cd /root && tar xzf $TARNAME && cd anlogic_deploy && ./pcie_setup.sh'"
