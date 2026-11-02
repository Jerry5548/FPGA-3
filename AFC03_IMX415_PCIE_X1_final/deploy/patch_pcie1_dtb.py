#!/usr/bin/env python3
"""
patch_pcie1_dtb.py — RK3576 PCIe1 设备树修补工具
功能：从eMMC读取DTB，使能pcie1（2a210000），添加reset-gpios，回写eMMC

用法：
  python3 patch_pcie1_dtb.py [--check]    # --check 仅检查不修改
  python3 patch_pcie1_dtb.py              # 实际修补并回写

修改内容：
  1. pcie@2a210000 的 status 从 "disabled" 改为 "okay"
  （注：添加 reset-gpios 属性需要改变FDT结构大小，此脚本仅做status patch。
   reset-gpios 通过 GPIO sysfs 在脚本中手动控制。）
"""
import struct
import sys
import os
import shutil

DTB_PART = '/dev/mmcblk0p3'
BACKUP_PATH = '/tmp/dtb_backup_orig.bin'
PATCHED_PATH = '/tmp/dtb_patched.bin'

CHECK_ONLY = '--check' in sys.argv

def read_dtb():
    """Read DTB from eMMC partition"""
    with open(DTB_PART, 'rb') as f:
        # Read FDT header to get total size
        header = f.read(8)
        magic, totalsize = struct.unpack('>II', header)
        if magic != 0xd00dfeed:
            print(f'ERROR: Bad FDT magic: 0x{magic:08x}')
            sys.exit(1)
        f.seek(0)
        data = f.read(totalsize)
        print(f'Read DTB: {len(data)} bytes from {DTB_PART}')
        return bytearray(data)

def find_node_status(data, node_name):
    """Find the status property value offset for a given node"""
    node_pos = data.find(node_name.encode())
    if node_pos < 0:
        return None, None
    
    # Search for "disabled" or "okay" within 1500 bytes after node name
    chunk = data[node_pos:node_pos+1500]
    
    for status_val in [b'disabled', b'okay']:
        idx = chunk.find(status_val)
        if idx >= 0:
            abs_pos = node_pos + idx
            # Verify this is a FDT property (tag 0x00000003 at abs_pos-12)
            tag = struct.unpack('>I', data[abs_pos-12:abs_pos-8])[0]
            val_len = struct.unpack('>I', data[abs_pos-8:abs_pos-4])[0]
            if tag == 3:  # FDT_PROP
                return abs_pos, status_val.decode()
    
    return None, None

def patch_status(data, offset, old_status, new_status):
    """Patch status property from old to new, keeping same padded size"""
    old_bytes = old_status.encode() + b'\x00'
    new_bytes = new_status.encode() + b'\x00'
    
    # FDT values are padded to 4-byte alignment
    old_padded = len(old_bytes)
    old_padded = (old_padded + 3) & ~3  # round up to 4
    
    new_padded = len(new_bytes)
    new_padded_aligned = (new_padded + 3) & ~3
    
    if old_padded != new_padded_aligned:
        # Different padded sizes — can't do simple in-place patch if they differ
        # But "disabled\0" = 9 bytes → padded to 12
        # "okay\0" = 5 bytes → padded to 8
        # We need to keep the same total size, so we pad "okay" to 12 bytes
        # and update the value length field
        pass
    
    # Write new value (padded to old size)
    new_val = new_bytes + b'\x00' * (old_padded - len(new_bytes))
    data[offset:offset+old_padded] = new_val
    
    # Update value length field (at offset-8)
    struct.pack_into('>I', data, offset-8, len(new_bytes))
    
    return data

def main():
    data = read_dtb()
    
    # Check pcie0 (2a200000) status
    pos0, status0 = find_node_status(data, 'pcie@2a200000')
    print(f'pcie0 (2a200000): status="{status0}" at offset 0x{pos0:x}' if pos0 else 'pcie0: not found')
    
    # Check pcie1 (2a210000) status  
    pos1, status1 = find_node_status(data, 'pcie@2a210000')
    print(f'pcie1 (2a210000): status="{status1}" at offset 0x{pos1:x}' if pos1 else 'pcie1: not found')
    
    if status1 == 'okay':
        print('\npcie1 already enabled! No patch needed.')
        return 0
    
    if status1 != 'disabled':
        print(f'\nERROR: Unexpected pcie1 status: {status1}')
        return 1
    
    if CHECK_ONLY:
        print('\n[CHECK MODE] pcie1 needs patching: disabled → okay')
        print('Run without --check to apply patch.')
        return 0
    
    # Backup original DTB
    print(f'\nBacking up original DTB to {BACKUP_PATH}...')
    with open(BACKUP_PATH, 'wb') as f:
        f.write(data)
    
    # Apply patch
    print('Patching pcie1 status: disabled → okay...')
    data = patch_status(data, pos1, 'disabled', 'okay')
    
    # Verify patch
    pos1_check, status1_check = find_node_status(data, 'pcie@2a210000')
    if status1_check != 'okay':
        print(f'ERROR: Verification failed! status={status1_check}')
        return 1
    print(f'Verification OK: pcie1 status="{status1_check}"')
    
    # Write patched DTB
    print(f'Writing patched DTB to {PATCHED_PATH}...')
    with open(PATCHED_PATH, 'wb') as f:
        f.write(data)
    
    # Write back to eMMC
    print(f'Writing patched DTB back to {DTB_PART}...')
    with open(DTB_PART, 'wb') as f:
        f.write(data)
    
    print('\n? DTB patched successfully!')
    print('  pcie1 (2a210000) status changed: disabled → okay')
    print('  Original backup: ' + BACKUP_PATH)
    print('  Reboot required for changes to take effect.')
    return 0

if __name__ == '__main__':
    sys.exit(main())
