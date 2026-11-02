# F0/F1 v22 board comparison and next architecture work

The board reported v22 and the geometry-20261006b receiver. Neither three-
frame run passed. Both received a framed packet and rejected its first
short image; no DMA polling timeout appears in the submitted output.

| Mode | First footer raw length | Expected RGB24 length | BC | C8 |
| --- | ---: | ---: | ---: | ---: |
| F0 | 566,608 | 6,220,800 | 1 | 0 |
| F1 | 1,024,688 | 6,220,800 | 1 | 14,468 |

BC is an aggregate event counter; value 1 does not mean a specific named
fault. Serializer early SOF or early LAST can produce a short footer. The
first packet framing/transport is now bounded; full image capture still fails.

## Counter blind spot and source findings

F0 uses the preprocessing bypass output `i_valid`. The camera connects that
input as `sat_tvalid && sat_tready`, with `sat_tready = !fifo_full`. Its C8
increment condition `preprocess_stream_valid && fifo_full` is therefore
logically unreachable in F0. F0 C8=0 does not establish that the camera
pipeline experienced no backpressure or lost pixels.

For F1 and F4, algorithm latency means processed outputs can arrive after
FIFO fills. C8 then counts dropped output beats. It still does not count
earlier losses in the ISP or MIPI receive FIFO.

Vendor ISP blocks such as `ui_Saturation_adj.v` shift valid/user/last every
clock and assign input ready equal to downstream ready, without freezing
those pipelines while ready is low. `ui_gamma.v` has the same pattern.
The MIPI receive FIFO independently writes the sensor clock-domain data
while its user-clock read is stopped by downstream ready. It is only 8192
42-bit entries. These paths cannot preserve arbitrary long compression
backpressure. Severe unclosed setup/hold timing remains an additional
uncertainty; this comparison does not rule out physical timing problems.

The camera output FIFO also has no enable qualification on write. Startup
stale/mid-frame buffering needs to be addressed, not worked around only by
sleeping/restarting the receiver. No RTL fix for that issue was shipped
in this comparison turn.

## DDR candidate already present locally

The MIPI-only project `AFC03_IMX415_MIPI_RK(0531) - test1` targets the same
PH1A90SEG324 and includes `uisrc/03_ip/al_ip/ui_ddr/ui_ddr.ipc`, DDR RTL and
DDR pin constraints, instantiated in `uisrc/01_rtl/system_top.v`. This is a
candidate to reuse in PCIe; it is not connected in the PCIe top today.

`ddr_pcie_pad_audit_20261006.json` is only a named-pad collision check. It
does not check PHY/PLL/clock routes, resource headroom, timing, DDR bandwidth,
calibration or board operation. The DDR reference clock is T13, already
used by PCIe's `mipi_ref_clk_p`; reuse that input internally rather than
creating another top-level input on the same pin.

## Correct direction

Capture/preprocess the live camera at a rate its non-stallable path can
handle, then write a complete frame to DDR. Publish a frame descriptor only
after expected rows/pixels and DDR writes complete. Compression reads only
published frames under its own ready signal. Never overwrite a frame being
compressed; skip complete incoming camera frames if no slot is free. This
can preserve accepted frame identity while allowing a lower accepted frame
rate. Finite DDR cannot support indefinitely retaining every input frame
when sustained compression throughput is lower than input throughput.

Then integrate the existing C2H byte packetizer/RK decoder and resolve
histogram/clock/reset timing. Do not remove geometry checks or pad missing
image bytes with zeros to meet acceptance. The next task is architecture
and RTL integration, not another preprocessing-mode shell test.

No new bitstream was generated for this diagnostic conclusion.
