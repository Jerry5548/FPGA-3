"""Snapshot or compare PCIe IP regeneration in the original TD project."""
import argparse
import datetime
import difflib
import hashlib
import json
from pathlib import Path
import shutil
import xml.etree.ElementTree as ET

PROJECT = Path(__file__).resolve().parents[2]
FILES = [
    'PH1_LOGIC_PCIE_ph1_pcie_core_pll.v',
    'PH1_LOGIC_PCIE_ph1_pcie_clock_ctrl.v',
    'PH1_LOGIC_PCIE.sdc',
    'PH1_LOGIC_PCIE.ipc',
]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['backup', 'compare'])
    parser.add_argument('--backup', type=Path)
    args = parser.parse_args()
    if args.action == 'backup':
        stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')
        dest = PROJECT / 'imx415_pcie_4k_Runs/ip_regeneration_snapshots' / stamp
        dest.mkdir(parents=True)
        for rel in ['al_ip', 'uisrc/03_ip/sgdma']:
            shutil.copytree(PROJECT / rel, dest / rel)
        shutil.copy2(PROJECT / 'imx415_pcie_4k.al', dest / 'imx415_pcie_4k.al')
        manifest = {str(p.relative_to(dest)): digest(p) for p in dest.rglob('*') if p.is_file()}
        (dest / 'SHA256.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
        print(f'BACKUP: {dest}')
        print(f'FILES: {len(manifest)}')
        return
    if args.backup is None:
        parser.error('compare requires --backup <directory printed by backup>')
    backup = args.backup.resolve()
    manifest = json.loads((backup / 'SHA256.json').read_text(encoding='utf-8'))
    for rel, expected in manifest.items():
        if digest(backup / rel) != expected:
            raise RuntimeError(f'Backup hash mismatch: {rel}')
    parts = []
    for name in FILES:
        old = backup / 'al_ip' / name
        new = PROJECT / 'al_ip' / name
        print(f'{name}: {"IDENTICAL" if digest(old) == digest(new) else "CHANGED"}')
        parts.extend(difflib.unified_diff(
            old.read_text(encoding='utf-8-sig').splitlines(keepends=True),
            new.read_text(encoding='utf-8-sig').splitlines(keepends=True),
            fromfile=f'before/{name}', tofile=f'after/{name}'))
    before = ET.parse(backup / 'al_ip/PH1_LOGIC_PCIE.ipc').find('GeneralConfig')
    after = ET.parse(PROJECT / 'al_ip/PH1_LOGIC_PCIE.ipc').find('GeneralConfig')
    a = {e.tag: e.text for e in before}
    b = {e.tag: e.text for e in after}
    changes = {key: {'before': a.get(key), 'after': b.get(key)}
               for key in sorted(a.keys() | b.keys()) if a.get(key) != b.get(key)}
    out = backup / 'comparison'
    out.mkdir(exist_ok=True)
    (out / 'four_files.diff').write_text(''.join(parts), encoding='utf-8')
    (out / 'ipc_parameters.json').write_text(json.dumps(changes, indent=2, ensure_ascii=False), encoding='utf-8')
    print(f'IPC PARAMETER CHANGES: {len(changes)}')
    print(f'REPORT: {out}')
    print('Comparison only; unchanged FIN=62.500 is not a hardware clock measurement or signoff.')

if __name__ == '__main__':
    main()
