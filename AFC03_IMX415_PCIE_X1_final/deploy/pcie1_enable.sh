#!/bin/bash
# pcie1_enable.sh — RK3576 PCIe1 使能脚本
# 功能：修补DTB使能pcie1，配置PERST# GPIO，每次开机自动执行
# 适用：RK3576 EVB1 + Anlogic FPGA (PCIe1 端口)
#
# 用法：
#   ./pcie1_enable.sh              # 检查并修补DTB + 安装开机服务
#   ./pcie1_enable.sh --patch-only # 仅修补DTB（需手动重启）
#   ./pcie1_enable.sh --runtime    # 仅运行时GPIO初始化（由systemd调用）
#   ./pcie1_enable.sh --status     # 查看当前状态

set -e

# ═══════════════════════════════════════════════
# 配置区
# ═══════════════════════════════════════════════
PCIE1_DEV="2a210000.pcie"
PCIE_DRV="/sys/bus/platform/drivers/rk-pcie"
DTB_PART="/dev/mmcblk0p3"
DTB_BACKUP="/tmp/dtb_backup_orig.bin"

# PERST# GPIO 配置 — GPIO1_C0 = gpio-48
# GPIO1 base=32, C0 = group_C(2)*8 + pin_0 = 16, total = 32+16 = 48
PERST_GPIO=48
PERST_GPIO_NAME="GPIO1_C0"

# vcc3v3_pcie 电源 GPIO — GPIO3_D4 = gpio-124（与pcie0共用）
POWER_GPIO=124
POWER_GPIO_NAME="GPIO3_D4"

SERVICE_NAME="pcie1-fpga"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SCRIPT_INSTALL_PATH="/usr/local/bin/pcie1_enable.sh"

# ═══════════════════════════════════════════════
# 函数
# ═══════════════════════════════════════════════

check_pcie1_dt_status() {
    local status
    status=$(cat /sys/firmware/devicetree/base/pcie@2a210000/status 2>/dev/null || echo "not_found")
    echo "$status"
}

gpio_export_and_set() {
    local gpio=$1 direction=$2 value=$3 label=$4
    if [ ! -d "/sys/class/gpio/gpio${gpio}" ]; then
        echo "$gpio" > /sys/class/gpio/export 2>/dev/null || true
        sleep 0.1
    fi
    echo "$direction" > "/sys/class/gpio/gpio${gpio}/direction"
    echo "$value" > "/sys/class/gpio/gpio${gpio}/value"
    echo "    ${label}: gpio-${gpio} = ${direction} ${value}"
}

do_runtime_init() {
    echo ""
    echo ">>> PCIe1 运行时 GPIO 初始化..."

    # 1. 使能 3.3V 电源（可能与 pcie0 共用）
    gpio_export_and_set $POWER_GPIO "out" "1" "vcc3v3_pcie ($POWER_GPIO_NAME)"
    sleep 0.1

    # 2. PERST# 信号 — 先拉低（assert reset），等待100ms，再拉高（deassert）
    gpio_export_and_set $PERST_GPIO "out" "0" "PERST# ($PERST_GPIO_NAME) ASSERT"
    sleep 0.1
    echo "1" > "/sys/class/gpio/gpio${PERST_GPIO}/value"
    echo "    PERST# ($PERST_GPIO_NAME): deasserted (HIGH)"
    sleep 0.1

    # 3. 尝试绑定 PCIe1 驱动
    echo ""
    echo ">>> 绑定 PCIe1 驱动..."
    if [ -d "${PCIE_DRV}/${PCIE1_DEV}" ]; then
        echo "    已绑定，先解绑..."
        echo "$PCIE1_DEV" > "${PCIE_DRV}/unbind" 2>/dev/null || true
        sleep 1
    fi

    echo "$PCIE1_DEV" > "${PCIE_DRV}/bind" 2>/dev/null
    sleep 2

    # 4. 检查结果
    echo ""
    echo ">>> PCIe 链路状态..."
    if lspci 2>/dev/null | grep -q .; then
        echo "    ? PCIe 设备已枚举:"
        lspci
    else
        echo "    ? 未检测到 PCIe 设备"
        echo "    检查 dmesg:"
        dmesg | grep -i pci | tail -10
    fi
}

do_dtb_patch() {
    local status
    status=$(check_pcie1_dt_status)

    echo ""
    echo ">>> 检查 pcie1 设备树状态..."
    echo "    当前状态: $status"

    if [ "$status" = "okay" ]; then
        echo "    ? pcie1 已启用，无需修补"
        return 0
    fi

    if [ "$status" = "disabled" ]; then
        echo "    需要修补 DTB: disabled → okay"
        echo ""
        echo ">>> 修补 DTB..."

        # 备份
        local dtb_size
        dtb_size=$(python3 -c "
import struct
f=open('${DTB_PART}','rb')
h=f.read(8)
m,s=struct.unpack('>II',h)
print(s) if m==0xd00dfeed else print(0)
f.close()
")
        if [ "$dtb_size" -eq 0 ]; then
            echo "    ERROR: 无法读取 DTB（FDT magic 不匹配）"
            return 1
        fi

        dd if="$DTB_PART" of="$DTB_BACKUP" bs=1 count="$dtb_size" 2>/dev/null
        echo "    备份: $DTB_BACKUP ($dtb_size bytes)"

        # 使用 Python 原地修补
        python3 -c "
import struct
data = bytearray(open('${DTB_PART}','rb').read(${dtb_size}))
pos = data.find(b'pcie@2a210000')
if pos < 0:
    raise SystemExit('pcie@2a210000 not found')
chunk = data[pos:pos+1500]
idx = chunk.find(b'disabled')
if idx < 0:
    raise SystemExit('disabled not found near pcie@2a210000')
abs_pos = pos + idx
tag = struct.unpack('>I', data[abs_pos-12:abs_pos-8])[0]
if tag != 3:
    raise SystemExit(f'FDT_PROP tag mismatch: 0x{tag:08x}')
# Patch: 'disabled\0' (9B padded to 12) → 'okay\0\0\0\0\0\0\0\0' (12B)
new_val = b'okay\x00' + b'\x00' * 7
data[abs_pos:abs_pos+12] = new_val
# Update value length: 9 → 5
struct.pack_into('>I', data, abs_pos-8, 5)
# Write back
open('${DTB_PART}','r+b').write(data)
print(f'Patched at offset 0x{abs_pos:x}: disabled → okay')
"
        local ret=$?
        if [ $ret -ne 0 ]; then
            echo "    ERROR: DTB 修补失败"
            return 1
        fi

        echo "    ? DTB 修补成功！"
        echo ""
        echo "    ╔══════════════════════════════════════╗"
        echo "    ║  需要重启才能生效！                  ║"
        echo "    ║  重启后 pcie1 将自动启用             ║"
        echo "    ╚══════════════════════════════════════╝"
        echo ""
        echo "    恢复命令（如需回滚）："
        echo "    dd if=$DTB_BACKUP of=$DTB_PART bs=1"
        return 0
    fi

    echo "    ERROR: 未知状态 '$status'"
    return 1
}

do_install_service() {
    echo ""
    echo ">>> 安装开机自启服务..."

    # 复制脚本到系统路径
    cp "$0" "$SCRIPT_INSTALL_PATH"
    chmod +x "$SCRIPT_INSTALL_PATH"
    echo "    脚本: $SCRIPT_INSTALL_PATH"

    # 创建 systemd service
    cat > "$SERVICE_FILE" << SVCEOF
[Unit]
Description=PCIe1 FPGA GPIO Init (PERST# + Power)
After=local-fs.target
Before=network.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_INSTALL_PATH} --runtime
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    echo "    服务: $SERVICE_FILE (已启用开机自启)"
    echo ""
    echo "    管理命令："
    echo "    systemctl status $SERVICE_NAME    # 查看状态"
    echo "    systemctl restart $SERVICE_NAME   # 重新初始化"
    echo "    systemctl disable $SERVICE_NAME   # 禁用开机自启"
}

show_status() {
    echo "============================================"
    echo " PCIe1 FPGA 状态检查 (RK3576)"
    echo "============================================"

    # DT status
    local dt_status
    dt_status=$(check_pcie1_dt_status)
    echo ""
    echo "  设备树 pcie1 status: $dt_status"

    # GPIO status
    echo ""
    echo "  GPIO 状态:"
    if [ -d "/sys/class/gpio/gpio${PERST_GPIO}" ]; then
        local dir val
        dir=$(cat "/sys/class/gpio/gpio${PERST_GPIO}/direction" 2>/dev/null)
        val=$(cat "/sys/class/gpio/gpio${PERST_GPIO}/value" 2>/dev/null)
        echo "    PERST# ($PERST_GPIO_NAME, gpio-${PERST_GPIO}): $dir $val"
    else
        echo "    PERST# ($PERST_GPIO_NAME, gpio-${PERST_GPIO}): 未导出"
    fi

    if [ -d "/sys/class/gpio/gpio${POWER_GPIO}" ]; then
        local dir val
        dir=$(cat "/sys/class/gpio/gpio${POWER_GPIO}/direction" 2>/dev/null)
        val=$(cat "/sys/class/gpio/gpio${POWER_GPIO}/value" 2>/dev/null)
        echo "    Power ($POWER_GPIO_NAME, gpio-${POWER_GPIO}): $dir $val"
    else
        echo "    Power ($POWER_GPIO_NAME, gpio-${POWER_GPIO}): 未导出"
    fi

    # PCIe link
    echo ""
    echo "  PCIe 驱动:"
    if [ -d "${PCIE_DRV}/${PCIE1_DEV}" ]; then
        echo "    ${PCIE1_DEV}: 已绑定"
    else
        echo "    ${PCIE1_DEV}: 未绑定"
    fi

    echo ""
    echo "  lspci:"
    lspci 2>/dev/null || echo "    (empty)"

    # Service
    echo ""
    if systemctl is-enabled "$SERVICE_NAME" &>/dev/null; then
        echo "  开机服务: 已启用"
        systemctl status "$SERVICE_NAME" --no-pager 2>/dev/null | head -5
    else
        echo "  开机服务: 未安装"
    fi
}

# ═══════════════════════════════════════════════
# 主逻辑
# ═══════════════════════════════════════════════

case "${1:-}" in
    --runtime)
        do_runtime_init
        ;;
    --patch-only)
        do_dtb_patch
        ;;
    --status)
        show_status
        ;;
    --help|-h)
        echo "用法: $0 [选项]"
        echo ""
        echo "选项:"
        echo "  (无参数)      完整流程：修补DTB + 安装开机服务 + GPIO初始化"
        echo "  --patch-only  仅修补DTB（需手动重启）"
        echo "  --runtime     仅运行时GPIO初始化（由systemd调用）"
        echo "  --status      查看当前状态"
        echo "  --help        显示此帮助"
        ;;
    *)
        echo "============================================"
        echo " RK3576 PCIe1 FPGA 使能工具"
        echo " PERST#: $PERST_GPIO_NAME (gpio-$PERST_GPIO)"
        echo " Power:  $POWER_GPIO_NAME (gpio-$POWER_GPIO)"
        echo "============================================"

        # Step 1: 修补 DTB
        do_dtb_patch

        # Step 2: 安装开机服务
        do_install_service

        # Step 3: 如果 DT 已经是 okay，直接做运行时初始化
        local_status=$(check_pcie1_dt_status)
        if [ "$local_status" = "okay" ]; then
            do_runtime_init
        else
            echo ""
            echo "请重启后再次运行 pcie_setup.sh 完成驱动加载"
        fi
        ;;
esac
