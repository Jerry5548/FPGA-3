#!/usr/bin/env python3
"""Audit this project's generated PLL and sensor table; no device access.

The register-to-INCK mapping is from Sony IMX415 E19504 p80 and Linux
drivers/media/i2c/imx415.c (891 Mbps, 27 MHz). Frame-rate scaling below is
an inference for the current custom RAW10/binning table, not a validated
Sony 60 FPS mode or a measurement at the sensor pins.
"""
import argparse
import hashlib
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path


def audit(project):
    top_path = project / 'uisrc/01_rtl/imx415_pcie_top.v'
    rom_path = project / 'uisrc/03_ip/ui_imx415_cfg/ui_imx415_reg.v'
    pll_path = project / 'al_ip/ui_pll.v'
    ipc_path = project / 'al_ip/ui_pll.ipc'
    # Legacy RTL has mixed-encoded comments; all audited syntax is ASCII.
    top = top_path.read_bytes().decode('latin-1')
    rom = rom_path.read_bytes().decode('latin-1')
    pll = pll_path.read_bytes().decode('latin-1')
    # Refuse to silently apply the old clock model after functional changes.
    top_code = re.sub(r'//[^\n]*|/\*.*?\*/', '', top, flags=re.S)
    patterns = [r'\.clk2_out\s*\(\s*cam_24m\s*\)',
                r'always\s*@\(posedge cam_24m\)\s*cam_mclk_r\s*<=\s*~cam_mclk_r;',
                r'assign\s+cam_mclk\s*=\s*cam_mclk_r;']
    if not all(re.search(pattern, top_code) for pattern in patterns):
        raise ValueError('MCLK implementation changed; review clock model before using this audit')

    def param(name):
        found = re.search(r'\.' + name + r'\(\s*"?([0-9.]+)"?\s*\)', pll)
        if found is None:
            raise ValueError('Missing PLL parameter: ' + name)
        return float(found[1])

    if '.FBKCLK("CLKC0_EXT")' not in pll or '.FEEDBK_MODE("NORMAL")' not in pll:
        raise ValueError('PLL feedback mode changed; review equations')
    # CLKC0 is the feedback output, so its post-scale factor participates in
    # the VCO equation. Other outputs use their own post-scale counters.
    vco_mhz = (param('FIN') * param('FBCLK_DIV') /
               param('REFCLK_DIV') * param('CLKC0_DIV'))
    c0_mhz = vco_mhz / param('CLKC0_DIV')
    c2_mhz = vco_mhz / param('CLKC2_DIV')
    mclk_mhz = c2_mhz / 2
    root = ET.parse(ipc_path).getroot()
    ipc_c2 = next(c for c in root.findall('.//clock') if c.findtext('id') == '2')
    declared_c2 = float(re.match(r'[0-9.]+', ipc_c2.findtext('clock_frequency'))[0])
    if abs(c2_mhz - declared_c2) > 0.001:
        raise ValueError('IPC and generated Verilog C2 disagree')

    modes = {}
    for mode in (0, 1, 2):
        regs = {}
        for line in rom.splitlines():
            if 'REG_DATA =' not in line or 'default:' in line:
                continue
            pairs = re.findall(r"\{16'h([0-9a-fA-F]+),\s*8'h([0-9a-fA-F]+)\}", line)
            if len(pairs) == 2 and "MODE==2'd1" in line:
                pair = pairs[0 if mode == 1 else 1]
            elif len(pairs) == 1:
                pair = pairs[0]
            else:
                raise ValueError('Unsupported register-table expression: ' + line.strip())
            regs[int(pair[0], 16)] = int(pair[1], 16)
        modes[str(mode)] = regs
    r = modes['0']
    profile = {0x3008: 0x5d, 0x300a: 0x42, 0x3033: 5,
               0x3115: 0, 0x3116: 0x23, 0x3118: 0xc6, 0x3119: 0,
               0x311a: 0xe7, 0x311b: 0, 0x311e: 0x23,
               0x4004: 0xc0, 0x4005: 6, 0x400c: 0, 0x4074: 1}
    profile_match = all(r.get(addr) == value for addr, value in profile.items())
    vmax = r[0x3024] | r[0x3025] << 8 | (r[0x3026] & 15) << 16
    hmax = r[0x3028] | r[0x3029] << 8
    manifest_path = project / 'imx415_pcie_4k_Runs/debug_release_ddr_v26_20261009/release_manifest.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf-8-sig'))
    hashes = {}
    for path in (top_path, rom_path, pll_path, ipc_path):
        name = path.relative_to(project).as_posix()
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        expected = manifest['sources'].get(name)
        hashes[name] = {'sha256': digest, 'matches_v26': digest == expected if expected else None}
    result = {'kind': 'source audit; not board clock measurement',
              'pll_c0_mhz': c0_mhz, 'pll_vco_mhz': vco_mhz, 'pll_c2_mhz': c2_mhz,
              'mclk_after_toggle_mhz': mclk_mhz, 'mode0_matches_27mhz_891mbps_profile': profile_match,
              'hmax': hmax, 'vmax': vmax,
              'mode0_selected_registers': {f'0x{addr:04x}': f'0x{r[addr]:02x}'
                                           for addr in sorted(set(profile) | {0x3031, 0x3032, 0x300b})},
              'sources': hashes}
    if profile_match:
        nominal = 74250000 / (hmax * vmax)
        result.update(profile_inck_mhz=27, clock_mismatch=mclk_mhz != 27,
                      nominal_frame_timing_fps=nominal,
                      inferred_scaled_fps=nominal * mclk_mhz / 27,
                      inferred_lane_mbps=891 * mclk_mhz / 27,
                      inferred_mipi_clock_mhz=891 / 2 * mclk_mhz / 27)
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--project', type=Path, default=Path(__file__).resolve().parents[2])
    ap.add_argument('--output', type=Path)
    args = ap.parse_args()
    result = audit(args.project.resolve())
    text = json.dumps(result, indent=2, ensure_ascii=False) + '\n'
    if args.output:
        args.output.write_text(text, encoding='utf-8')
    print(text, end='')


if __name__ == '__main__':
    main()
