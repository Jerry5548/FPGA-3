# Camera clock fix candidate (original project)

The source candidate changes the default camera mode to 1080p. The independent
v26 fallback remains unchanged. As of 2026-10-11 the source has completed
synthesis/place/route and a routed timing recheck; see
`timing_improvement_20261011.md` for results and remaining clock/coverage warnings.
No new bitstream or board validation accompanies that checkpoint.

## Clock candidate

Input 100 MHz, integer PLL configuration:

```text
VCO = 100 MHz * 3 / 2 * 9 = 1350 MHz
C0  = 1350 / 9  = 150 MHz
C1  = 1350 / 15 = 90 MHz
C2  = 1350 / 25 = 54 MHz
cam_mclk = C2 / 2 = 27 MHz
```

No fractional-N is required; the VCO is within the PH1A 800?2000 MHz range.
`ui_pll.v` and `ui_pll.ipc` contain the regenerated candidate values. They are
included in the current synthesis/implementation; board MCLK still needs measurement.

## Sensor table audit

Mode 0/2 remains RAW10 with 2x2 binning; the top-level reset default is now mode 0 (1080p):

- HADD/VADD/ADDMODE = 1/1/1; ADBIT=0; MDBIT=0.
- HMAX=542; VMAX=2283.
- The 27 MHz / 891 Mbps/lane table uses BCWAIT=0x05D, CPWAIT=0x042,
  SYS_MODE=0x5, INCKSEL3=0x0C6, INCKSEL4=0x0E7, TXCLKESC_FREQ=0x06C0.
- Estimated 1080p frame timing: `74.25e6/(542*2283)=60.0055 FPS`.

Mode 1 (4K) is intentionally not changed in this candidate. Its RAW10/all-pixel
configuration requires a separate check against the 27 MHz/891 Mbps or official
4-lane 30 FPS table, including HMAX/VMAX and MIPI timing.

## Required validation

1. Regenerate `ui_pll.v` in TD and confirm C0/C1/C2 and `FRAC_ENABLE=DISABLE`.
2. Run RTL regression, synthesis, place/route, and timing. Check MIPI HS,
   automatic delay, `cam_mclk`, and CDC FIFOs.
3. Before downloading, measure `cam_mclk` at the connector; it must be 27 MHz.
4. Run 1080p with compression, YOLO, and display disabled. Compare MIPI,
   crop, ISP, and pack4 SOF/EOF counters; require stable approximately 60 FPS.
5. Do not silently fall back to the 24 MHz/1.44 Gbps mode and claim 1080p60.

Audit command:

```powershell
python uisrc/06_doc/audit_camera_clock.py --output uisrc/06_doc/camera_clock_audit_after_candidate_20261011.json
```
