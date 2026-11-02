// =============================================================================
// cam_video_source.v — IMX415 Camera Video Source (drop-in replacement for tpg_gen)
// =============================================================================
// Pipeline:
//   mipi_csi_rx (40b @ user_clk via internal sfifo CDC)
//     → image_correction (crop to active region)
//       → ui_BLC (black level correction, offset=50)
//         → ui_top_demosaic (RAW10 Bayer → 128b RGB)
//           → data128_96 → ui_awb (Gray World AWB) → data96_128
//             → FIFO (rate decoupling)
//               → pack4_rgb24_to_512 (128b→512b, 4 pixels/clk, backpressure)
//
// Output interface: 128-bit AXI-Stream + sof/eof/frame_count.
// Matched to x1 Gen2 PCIe DATA_WIDTH=128.
// No DDR buffering — pure streaming with frame-drop on DMA backpressure.
// =============================================================================
`timescale 1ns / 1ps

module cam_video_source #(
    parameter MIPI_LAN     = 4,
    parameter DEVICE       = "PH2",
    parameter BAYER_MODE   = "RGGB",
    parameter PREPROCESS_MODE = 4,
    parameter RUNTIME_PREPROCESS = 1,
    parameter HOST_INPUT_ENABLE = 0
)(
    // System clock (PCIe user_clk, ~250-300MHz)
    input  wire          user_clk,
    input  wire          user_rst_n,
    input  wire          enable,
    // Host input shares the project preprocessing pipeline, bypassing sensor ISP.
    input wire host_select,host_valid,host_sof,host_eol,
    input wire [127:0] host_rgb,
    output wire host_ready,

    // Runtime resolution parameters (from BAR registers)
    input  wire [12:0]   cfg_img_width,      // Active image width  (e.g. 1920, 3840, 1280)
    input  wire [12:0]   cfg_img_height,     // Active image height (e.g. 1080, 2160, 720)
    input  wire [14:0]   cfg_crop_v_start,   // Crop: first valid line (exclusive >)
    input  wire [14:0]   cfg_crop_v_end,     // Crop: last  valid line (exclusive <)
    input  wire [14:0]   cfg_crop_h_end,     // Crop: h beats per line (exclusive <)

    // MIPI CSI-2 physical interface
    input  wire          mipi_ref_clock,     // PHY reference clock
    input  wire          mipi_clk_hs_rx_p,   // MIPI clock lane (P)
    input  wire [MIPI_LAN-1:0] mipi_data_hs_p, // MIPI data lanes (P)

    // Frame control
    input  wire          frame_request,      // Tie to 1 for camera mode

    // AXI-Stream 128-bit output (matched to x1 Gen2 DATA_WIDTH=128)
    output wire [127:0]  m_tdata,
    output wire          m_tvalid,
    input  wire          m_tready,
    output wire          m_tlast,
    output wire          m_frame_last,
    output wire          sof,
    output wire          eof,
    output wire [31:0]   frame_count_out,
    output wire [31:0]   fifo_overflow_count,
    input wire [3:0]     cfg_preprocess_mode,
    output wire [3:0]    preprocess_mode_active,
    output wire [31:0]   median_error_count,sobel_error_count,dehaze_error_count,

    // Status / debug
    input  wire          debug_button,       // Board debug button (MIPI delay)
    output wire          mipi_div_clk_out,   // Divided HS clock (debug)
    output wire          auto_delay_done,    // MIPI PHY auto delay calibration done
    output wire          mipi_tvalid_out,    // MIPI receiver raw tvalid (for debug)
    output wire [7:0]    dbg_mipi,           // MIPI 内部调试总线（hs_div_clk 域）
    output wire [7:0]    dbg_delay,          // delay 调试总线（hs_div_clk 域）
    output wire [5:0]    dbg_best_len        // eye-scan 最佳区间长度
);

    // ================================================================
    // Internal wires
    // ================================================================

    // mipi_csi_rx → image_correction
    wire [39:0]  mipi_tdata;
    wire         mipi_tvalid;
    assign       mipi_tvalid_out = mipi_tvalid;
    wire         mipi_tlast;
    wire         mipi_tuser;
    wire         mipi_tready;

    // image_correction → ui_BLC
    wire [39:0]  crop_tdata;
    wire [9:0]   crop_tdest;
    wire         crop_tvalid;
    wire         crop_tlast;
    wire         crop_tuser;
    wire         crop_tready;

    // ui_BLC → ui_top_demosaic
    wire [39:0]  blc_tdata;
    wire [9:0]   blc_tdest;
    wire         blc_tvalid;
    wire         blc_tlast;
    wire         blc_tuser;
    wire         blc_tready;

    // ui_top_demosaic → AWB chain → FIFO → pack4_rgb24_to_512
    wire [127:0] demo_tdata;
    wire         demo_tvalid;
    wire         demo_tlast;
    wire         demo_tuser;
    wire         demo_tready;

    // AWB internal signals
    wire [95:0]  demo_tdata_96;     // demosaic 128b → 96b (strip padding)
    wire [95:0]  awb_tdata;         // AWB 96b output
    wire         awb_tvalid;
    wire         awb_tlast;
    wire         awb_tuser;
    wire         awb_tready;

    // Image Cut output (edge pixel zeroing)
    wire [95:0]  cut_tdata;
    wire         cut_tvalid;
    wire         cut_tlast;
    wire         cut_tuser;
    wire         cut_tready;

    // Gamma correction output
    wire [95:0]  gamma_tdata;
    wire         gamma_tvalid;
    wire         gamma_tlast;
    wire         gamma_tuser;
    wire         gamma_tready;

    // Contrast adjustment output
    wire [95:0]  contrast_tdata;
    wire         contrast_tvalid;
    wire         contrast_tlast;
    wire         contrast_tuser;
    wire         contrast_tready;

    // Brightness adjustment output
    wire [95:0]  bright_tdata;
    wire         bright_tvalid;
    wire         bright_tlast;
    wire         bright_tuser;
    wire         bright_tready;

    // Saturation adjustment output
    wire [95:0]  sat_tdata;
    wire         sat_tvalid;
    wire         sat_tlast;
    wire         sat_tuser;
    wire         sat_tready;
    wire [127:0] sat_tdata_128;
    wire host_selected=HOST_INPUT_ENABLE ? host_select : 1'b0;

    // ---- Pipeline diagnostic sticky flags (injected into frame_count upper byte) ----
    reg mipi_tuser_ever, mipi_tlast_ever;
    reg crop_tuser_ever, crop_tlast_ever;
    reg demo_tuser_ever, demo_tlast_ever;
    reg awb_tuser_ever,  awb_tlast_ever;
    reg pack_sof_ever,   pack_eof_ever;
    always @(posedge user_clk or negedge user_rst_n) begin
        if (!user_rst_n) begin
            mipi_tuser_ever <= 1'b0; mipi_tlast_ever <= 1'b0;
            crop_tuser_ever <= 1'b0; crop_tlast_ever <= 1'b0;
            demo_tuser_ever <= 1'b0; demo_tlast_ever <= 1'b0;
            awb_tuser_ever  <= 1'b0; awb_tlast_ever  <= 1'b0;
            pack_sof_ever   <= 1'b0; pack_eof_ever   <= 1'b0;
        end else begin
            if (mipi_tuser)  mipi_tuser_ever <= 1'b1;
            if (mipi_tlast)  mipi_tlast_ever <= 1'b1;
            if (crop_tuser)  crop_tuser_ever <= 1'b1;
            if (crop_tlast)  crop_tlast_ever <= 1'b1;
            if (demo_tuser)  demo_tuser_ever <= 1'b1;
            if (demo_tlast)  demo_tlast_ever <= 1'b1;
            if (awb_tuser)   awb_tuser_ever  <= 1'b1;
            if (awb_tlast)   awb_tlast_ever  <= 1'b1;
            if (sof)         pack_sof_ever   <= 1'b1;
            if (eof)         pack_eof_ever   <= 1'b1;
        end
    end
    wire [31:0] raw_frame_count;

    // ================================================================
    // 1. MIPI CSI-2 Receiver
    //    CDC: internal sfifo bridges hs_rx_clk → m_axis_video_aclk (user_clk)
    // ================================================================
    mipi_csi_rx #(
        .MIPI_LAN   (MIPI_LAN),
        .DEVICE     (DEVICE)
    ) u_mipi_csi_rx (
        .I_debug_button         (debug_button),
        .I_ref_clock            (mipi_ref_clock),
        .I_clk_hs_rx_p          (mipi_clk_hs_rx_p),
        .I_reset_n              (user_rst_n),
        .I_hs_data_p            (mipi_data_hs_p),
        .I_enable               (enable && !host_selected),
        .O_hs_div_clk           (mipi_div_clk_out),
        // Output clock domain = user_clk (key CDC point!)
        .m_axis_video_aclk      (user_clk),
        .m_axis_video_aresetn   (user_rst_n),
        .m_axis_video_tready    (mipi_tready),
        .m_axis_video_tuser     (mipi_tuser),
        .m_axis_video_tlast     (mipi_tlast),
        .m_axis_video_tvalid    (mipi_tvalid),
        .m_axis_video_tdata     (mipi_tdata),
        .O_auto_delay_done      (auto_delay_done),
        .O_dbg_mipi             (dbg_mipi),
        .O_dbg_delay            (dbg_delay),
        .O_dbg_best_len         (dbg_best_len)
    );

    // ================================================================
    // 2. Image Correction (spatial crop to IMG_WIDTH × IMG_HEIGHT)
    // ================================================================
    image_correction #(
        .DATA_WIDTH     (40),
        .TDEST_WIDTH    (10)
    ) u_image_correction (
        .I_clk          (user_clk),
        .I_rst_n        (user_rst_n),
        // Runtime crop parameters
        .I_v_start      (cfg_crop_v_start),
        .I_v_end        (cfg_crop_v_end),
        .I_h_end        (cfg_crop_h_end),
        // Input from MIPI Rx
        .I_raw_tdata    (mipi_tdata),
        .I_raw_tdest    (10'd0),
        .I_raw_tlast    (mipi_tlast),
        .I_raw_tvalid   (mipi_tvalid),
        .I_raw_tuser    (mipi_tuser),
        .I_raw_tready   (mipi_tready),
        // Output to BLC
        .O_raw_tdata    (crop_tdata),
        .O_raw_tdest    (crop_tdest),
        .O_raw_tlast    (crop_tlast),
        .O_raw_tvalid   (crop_tvalid),
        .O_raw_tuser    (crop_tuser),
        .O_raw_tready   (crop_tready)
    );

    // ================================================================
    // 3. Black Level Correction (BLC)
    // ================================================================
    ui_BLC #(
        .Black_level_offset_r0  (10'd50),
        .Black_level_offset_r1  (10'd50),
        .Black_level_offset_r2  (10'd50),
        .Black_level_offset_r3  (10'd50)
    ) u_blc (
        .I_clk      (user_clk),
        .I_rst_n    (user_rst_n),
        // Input from image_correction
        .I_tdata    (crop_tdata),
        .I_tdest    (crop_tdest),
        .I_tlast    (crop_tlast),
        .I_tvalid   (crop_tvalid),
        .I_tuser    (crop_tuser),
        .I_tready   (crop_tready),
        // Output to demosaic
        .O_tdata    (blc_tdata),
        .O_tdest    (blc_tdest),
        .O_tlast    (blc_tlast),
        .O_tvalid   (blc_tvalid),
        .O_tuser    (blc_tuser),
        .O_tready   (blc_tready)
    );

    // ================================================================
    // 4. Demosaic (RAW10 Bayer → 128-bit RGB)
    //    128b = 4 pixels × {8'b0, R[7:0], G[7:0], B[7:0]}
    //    Uses 3 BRAM line buffers (ui_ram_demosaic × 2 + ui_ram_zhenghe × 1)
    // ================================================================
    ui_top_demosaic #(
        .data_complete_delay    (50),
        .BAYER_MODE             (BAYER_MODE)
    ) u_demosaic (
        .I_clk              (user_clk),
        .I_rst_n            (user_rst_n),
        // Runtime resolution
        .I_img_width        (cfg_img_width),
        .I_img_height       (cfg_img_height),
        // Input from BLC
        .I_axi4s_tdata      (blc_tdata),
        .I_axi4s_tdest      (blc_tdest),
        .I_axi4s_tlast      (blc_tlast),
        .I_axi4s_tvalid     (blc_tvalid),
        .I_axi4s_tuser      (blc_tuser),
        .I_axi4s_tready     (blc_tready),
        // Output to AWB chain
        .O_tdata            (demo_tdata),
        .O_tvalid           (demo_tvalid),
        .O_tlast            (demo_tlast),
        .O_tuser            (demo_tuser),
        .O_tready           (demo_tready)
    );

    // ================================================================
    // 4a. Auto White Balance (AWB) — Gray World algorithm
    //     Pipeline: demosaic(128b) → data128_96 → AWB(96b) → data96_128 → (128b)
    //     Uses divider IP (50-cycle latency) + signal_delay BRAM for data sync.
    //     Gain updated every 4 frames. G channel = reference, R/B adjusted.
    // ================================================================

    // 128b → 96b: strip per-pixel 8-bit padding from demosaic output
    ui_data128_96 u_data128_96 (
        .I_tdata    (demo_tdata),
        .O_tdata    (demo_tdata_96)
    );

    // AWB core (Gray World, 96-bit 4-pixel parallel)
    ui_awb #(
        .IMG_HEIGHT (2160),
        .IMG_WIDTH  (3840)
    ) u_awb (
        .I_clk      (user_clk),
        .I_rst_n    (user_rst_n),
        .I_img_width (cfg_img_width),
        .I_img_height(cfg_img_height),
        .I_tlast    (demo_tlast),
        .I_tuser    (demo_tuser),
        .I_tdata    (demo_tdata_96),
        .I_tvalid   (demo_tvalid),
        .I_tready   (demo_tready),
        .O_tlast    (awb_tlast),
        .O_tuser    (awb_tuser),
        .O_tdata    (awb_tdata),
        .O_tvalid   (awb_tvalid),
        .O_tready   (awb_tready)
    );

    // ================================================================
    // 4b. Image Cut — zero out edge pixels to remove demosaic boundary artifacts
    //     SKIP_COLS_left=1 → zeros first 4 pixels (1 beat at 4-pixel parallel)
    // ================================================================
    ui_image_cut #(
        .IMG_WIDTH      (3840),
        .IMG_HEIGHT     (2160),
        .DATA_WIDTH     (96),
        .SKIP_ROWS_top  (0),
        .SKIP_ROWS_bottom(0),
        .SKIP_COLS_left (1),
        .SKIP_COLS_right(0)
    ) u_image_cut (
        .I_clk      (user_clk),
        .I_rst_n    (user_rst_n),
        .I_img_width (cfg_img_width),
        .I_img_height(cfg_img_height),
        .I_tlast    (awb_tlast),
        .I_tuser    (awb_tuser),
        .I_tdata    (awb_tdata),
        .I_tvalid   (awb_tvalid),
        .I_tready   (awb_tready),
        .O_tlast    (cut_tlast),
        .O_tuser    (cut_tuser),
        .O_tdata    (cut_tdata),
        .O_tvalid   (cut_tvalid),
        .O_tready   (cut_tready)
    );

    // ================================================================
    // 4c. Gamma Correction (γ = 2.2)
    //     LUT-based per-channel correction, 4-pixel parallel
    // ================================================================
    ui_gamma #(
        .GAMMA_10x  (22)
    ) u_gamma (
        .I_clk      (user_clk),
        .I_rst_n    (user_rst_n),
        .I_tlast    (cut_tlast),
        .I_tuser    (cut_tuser),
        .I_tdata    (cut_tdata),
        .I_tvalid   (cut_tvalid),
        .I_tready   (cut_tready),
        .O_tlast    (gamma_tlast),
        .O_tuser    (gamma_tuser),
        .O_tdata    (gamma_tdata),
        .O_tvalid   (gamma_tvalid),
        .O_tready   (gamma_tready)
    );

    // ================================================================
    // 4d. Contrast Adjustment (level=140, 128=no change)
    // ================================================================
    ui_Contrast_adj #(
        .contrast_level (140)
    ) u_contrast (
        .I_clk      (user_clk),
        .I_rst_n    (user_rst_n),
        .I_tlast    (gamma_tlast),
        .I_tuser    (gamma_tuser),
        .I_tdata    (gamma_tdata),
        .I_tvalid   (gamma_tvalid),
        .I_tready   (gamma_tready),
        .O_tlast    (contrast_tlast),
        .O_tuser    (contrast_tuser),
        .O_tdata    (contrast_tdata),
        .O_tvalid   (contrast_tvalid),
        .O_tready   (contrast_tready)
    );

    // ================================================================
    // 4e. Brightness Adjustment (+5 offset)
    // ================================================================
    ui_Brightness_adj #(
        .BRIGHTNESS_ADD   (5),
        .BRIGHTNESS_MINUS (0)
    ) u_brightness (
        .I_clk      (user_clk),
        .I_rst_n    (user_rst_n),
        .I_tlast    (contrast_tlast),
        .I_tuser    (contrast_tuser),
        .I_tdata    (contrast_tdata),
        .I_tvalid   (contrast_tvalid),
        .I_tready   (contrast_tready),
        .O_tlast    (bright_tlast),
        .O_tuser    (bright_tuser),
        .O_tdata    (bright_tdata),
        .O_tvalid   (bright_tvalid),
        .O_tready   (bright_tready)
    );

    // ================================================================
    // 4f. Saturation Adjustment (level=130, 128=no change)
    // ================================================================
    ui_Saturation_adj #(
        .ADJUST_VAL (130)
    ) u_saturation (
        .I_clk      (user_clk),
        .I_rst_n    (user_rst_n),
        .I_tlast    (bright_tlast),
        .I_tuser    (bright_tuser),
        .I_tdata    (bright_tdata),
        .I_tvalid   (bright_tvalid),
        .I_tready   (bright_tready),
        .O_tlast    (sat_tlast),
        .O_tuser    (sat_tuser),
        .O_tdata    (sat_tdata),
        .O_tvalid   (sat_tvalid),
        .O_tready   (sat_tready)
    );

    // 96b → 128b: restore per-pixel 8-bit padding for downstream pack4
    ui_data96_128 u_data96_128 (
        .I_tdata    (sat_tdata),
        .O_tdata    (sat_tdata_128)
    );

    video_preprocess_input #(
        .IMAGE_WIDTH(1920),.IMAGE_HEIGHT(1080),.PREPROCESS_MODE(PREPROCESS_MODE),
        .RUNTIME_PREPROCESS(RUNTIME_PREPROCESS),.HOST_INPUT_ENABLE(HOST_INPUT_ENABLE)
    ) u_shared_preprocess (
        .user_clk(user_clk),.user_rst_n(user_rst_n),.enable(enable),
        .preprocess_enable((cfg_img_width==1920) && (cfg_img_height==1080)),
        .camera_rgb(sat_tdata_128),.camera_valid(sat_tvalid),
        .camera_sof(sat_tuser),.camera_eol(sat_tlast),.camera_ready(sat_tready),
        .host_select(host_select),.host_valid(host_valid),.host_sof(host_sof),
        .host_eol(host_eol),.host_rgb(host_rgb),.host_ready(host_ready),
        .cfg_preprocess_mode(cfg_preprocess_mode),.preprocess_mode_active(preprocess_mode_active),
        .median_error_count(median_error_count),.sobel_error_count(sobel_error_count),
        .dehaze_error_count(dehaze_error_count),.fifo_overflow_count(fifo_overflow_count),
        .m_tdata(m_tdata),.m_tvalid(m_tvalid),.m_tready(m_tready),
        .m_tlast(m_tlast),.m_frame_last(m_frame_last),.sof(sof),.eof(eof),
        .frame_count_out(raw_frame_count)
    );

    // Inject diagnostic sticky flags into frame_count_out[31:24]
    // F[31]: mipi_tuser_ever  F[30]: mipi_tlast_ever
    // F[29]: crop_tuser_ever  F[28]: crop_tlast_ever
    // F[27]: demo_tuser_ever  F[26]: demo_tlast_ever
    // F[25]: awb_tuser_ever   F[24]: awb_tlast_ever
    // F[23:0]: actual frame count
    assign frame_count_out = {
        mipi_tuser_ever, mipi_tlast_ever,
        crop_tuser_ever, crop_tlast_ever,
        demo_tuser_ever, demo_tlast_ever,
        awb_tuser_ever,  awb_tlast_ever,
        raw_frame_count[23:0]
    };

endmodule
