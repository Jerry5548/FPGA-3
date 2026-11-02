// ============================================================================
// param_imx415.v - Phase 9 IMX415 Camera 扩展参数
// ============================================================================
// 在 TD 项目中与 param_tpg.v 一同 GlobalInclude
// ============================================================================

// ─── Camera 寄存器地址 ───
`define REG_SOURCE_SEL      8'h80   // R/W: bit[0] = 0:TPG, 1:Camera
`define REG_CAM_STATUS      8'h84   // R: bit[0]=I2C done, [1]=MIPI div_clk, [2]=cam SOF seen
`define REG_CAM_FRAME_COUNT 8'h88   // R: camera frame count (32-bit)
`define REG_CAM_ERROR       8'h8C   // R: {3'd0, cam_width[12:0], 3'd0, cam_height[12:0]}
`define REG_CAM_MODE        8'h90   // R/W: bit[1:0] = 0:1080p, 1:4K, 2:720p
`define REG_DROP_DETECT_CNT 8'h94   // R: vid_drop_detect trigger count
`define REG_COMPRESS_MODE    8'hA8
`define REG_COMP_RAW_BYTES   8'hAC
`define REG_COMP_BYTES       8'hB0
`define REG_COMP_TOKENS      8'hB4
`define REG_COMP_FRAMES      8'hB8
`define REG_COMP_ERRORS      8'hBC
`define REG_COMP_STATUS      8'hC0
`define REG_CAM_FIFO_DROPS   8'hC8
`define REG_COMP_VALID_BEATS 8'hC4
`define REG_PREPROCESS_MODE  8'hA4
`define REG_AE_GAIN        8'h98   // R/W: bit[7:0] = AE gain (0-240, default 100 = 30dB)
`define REG_GATE_DROP_CNT  8'h9C   // R: vid_frame_gate dropped frame count
`define REG_GATE_PASS_CNT  8'hA0   // R: vid_frame_gate passed frame count

// ─── 版本标识 ───
`define PHASE9_VERSION      32'h5644_0032   // v32: overlapped H2V1; mode9 T0=40, omega=85%, saturating RGB bias=8

// ─── MCLK / I2C ───
`define CAM_I2C_CLK_DIV     16'd539         // 54MHz / (539+1) = 100kHz I2C

`define REG_DDR_STATUS      8'hCC
`define REG_DDR_PUBLISHED   8'hD0
`define REG_DDR_NO_SLOT     8'hD4
`define REG_DDR_INVALID     8'hD8
`define REG_DDR_WRITE_ERR   8'hDC
`define REG_DDR_READ_ERR    8'hE0
`define REG_DDR_CAP_DROPS   8'hE4
`define REG_DDR_REPLAYED    8'hE8
`define REG_DDR_STORE_STATE 8'hEC

`define REG_DDR_STARTUP_SKIPS 8'hF0 // v24: first observed frame skipped on each enable

`define REG_PRE_MEDIAN_ERRORS 8'hF4
`define REG_PRE_SOBEL_ERRORS 8'hF8

// v26: first rejected DDR frame, frozen until soft reset
`define REG_DDR_FAULT_REASON 16'h0100
`define REG_DDR_FAULT_FRAME_ID 16'h0104
`define REG_DDR_FAULT_WORDS 16'h0108
`define REG_DDR_FAULT_INDEX 16'h010C
`define REG_DDR_FAULT_POSITION 16'h0110
`define REG_DDR_FAULT_FLAGS 16'h0114
`define REG_DDR_FAULT_SEEN_ID 16'h0118
`define REG_DDR_FAULT_EXPECTED_WORDS 16'h011C

`define REG_PRE_DEHAZE_ERRORS 16'h0120

`define REG_HOST_STATUS 16'h0124
`define REG_HOST_FRAMES 16'h0128
`define REG_HOST_ERRORS 16'h012C
`define REG_HOST_FRAME_ID 16'h0130
