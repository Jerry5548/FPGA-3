/*===========================================*\
Filename        : imx415_pcie_top.v
Project name    : Phase 11 �� IMX415 1080p60fps Camera via PCIe (AXI4-Stream)
Description     : Top module for PH1A90SEG324-2.
                  Camera-only design, no TPG.
                  Supports runtime resolution switching via REG_CAM_MODE:
                    0=1080p@60, 1=4K@30 , 2=720p.
ע�⣬pcie gen2 x1 ��֧��4k30��Ĭ��ʹ��1080p@60
\*===========================================*/
`timescale 1ns/1ps


module imx415_pcie_top #(
    parameter LINK_WIDTH    = 1,
    parameter DEVICE_FAMILY = "PH1A",
    parameter USER_CLK_FREQ = 125,
    parameter DATA_WIDTH    = 128,
    parameter KEEP_WIDTH    = DATA_WIDTH/8,
    parameter H2C_CHNL_NUM  = 1,
    parameter C2H_CHNL_NUM  = 1,
    parameter USR_IRQ_NUM   = 16,
    parameter MIPI_LAN      = 4
)(
    // ���� System ����
    input   wire                    sys_clk,        // 25 MHz

    // ���� PCIe ����
    input   wire                    refclk_p,
    input   wire                    refclk_n,
    output  wire   [LINK_WIDTH-1:0] txp,
    output  wire   [LINK_WIDTH-1:0] txn,
    input   wire   [LINK_WIDTH-1:0] rxp,
    input   wire   [LINK_WIDTH-1:0] rxn,
    input   wire                    pcie_mperst,

    // ���� MIPI Reference Clock (100MHz LVDS differential, T13/T14) ����
    input   wire                    mipi_ref_clk_p,         // 100MHz LVDS P (T13)

    // ���� IMX415 MIPI CSI-2 ����
    input   wire                    mipi_clk_hs_rx_p,       // MIPI clock lane (P)
    input   wire   [MIPI_LAN-1:0]  mipi_data_hs_p,         // MIPI data lanes (P)

    // ���� IMX415 I2C ����
    output wire [13:0] ddr_addr,
    output wire [2:0] ddr_ba,
    output wire ddr_cke,ddr_odt,ddr_cs_n,ddr_ras_n,ddr_cas_n,ddr_we_n,
    output wire ddr_ck_p,ddr_ck_n,ddr_reset_n,
    inout wire [1:0] ddr_dm,ddr_dqs_p,ddr_dqs_n,
    inout wire [15:0] ddr_dq,
    output  wire                    cam_scl,
    inout   wire                    cam_sda,

    // ���� IMX415 MCLK ����
    output  wire                    cam_mclk,               // 27MHz to sensor INCK (toggle)

    // ���� IMX415 XCLR (hardware reset, active-low on sensor) ����
    output  wire                    cam_xclr,               // Drive high to release reset

    // ���� Debug UART ����
    output  wire                    uart_tx,                // 115200 8N1 debug output (U11)
    input   wire                    uart_rx                 // 115200 8N1 debug input  (V11)
);

// ====================================================================
// Compile-time feature enable (same as Phase 8)
// ====================================================================
`ifdef  MSI_EN
localparam IRQ_LGCY_EN = 0; localparam IRQ_MSI_EN = 1; localparam IRQ_MSIX_EN = 0;
`elsif   MSIX_EN
localparam IRQ_LGCY_EN = 0; localparam IRQ_MSI_EN = 0; localparam IRQ_MSIX_EN = 1;
`else
localparam IRQ_LGCY_EN = 1; localparam IRQ_MSI_EN = 0; localparam IRQ_MSIX_EN = 0;
`endif
`ifdef  AXI4MM_BUS_EN          localparam AXI4MM_BUS_EN    = 1; `else localparam AXI4MM_BUS_EN    = 0; `endif
`ifdef  AXI4ST_BUS_EN          localparam AXI4ST_BUS_EN    = 1; `else localparam AXI4ST_BUS_EN    = 0; `endif
`ifdef  DSC_BYPASS_C2H_CHL0_EN localparam DSC_BYPASS_C2H0  = 1; `else localparam DSC_BYPASS_C2H0  = 0; `endif
`ifdef  DSC_BYPASS_C2H_CHL1_EN localparam DSC_BYPASS_C2H1  = 2; `else localparam DSC_BYPASS_C2H1  = 0; `endif
`ifdef  DSC_BYPASS_C2H_CHL2_EN localparam DSC_BYPASS_C2H2  = 4; `else localparam DSC_BYPASS_C2H2  = 0; `endif
`ifdef  DSC_BYPASS_C2H_CHL3_EN localparam DSC_BYPASS_C2H3  = 8; `else localparam DSC_BYPASS_C2H3  = 0; `endif
`ifdef  DSC_BYPASS_H2C_CHL0_EN localparam DSC_BYPASS_H2C0  = 1; `else localparam DSC_BYPASS_H2C0  = 0; `endif
`ifdef  DSC_BYPASS_H2C_CHL1_EN localparam DSC_BYPASS_H2C1  = 2; `else localparam DSC_BYPASS_H2C1  = 0; `endif
`ifdef  DSC_BYPASS_H2C_CHL2_EN localparam DSC_BYPASS_H2C2  = 4; `else localparam DSC_BYPASS_H2C2  = 0; `endif
`ifdef  DSC_BYPASS_H2C_CHL3_EN localparam DSC_BYPASS_H2C3  = 8; `else localparam DSC_BYPASS_H2C3  = 0; `endif
localparam [3:0]    H2C_DSC_BYP_MAP = DSC_BYPASS_H2C0 | DSC_BYPASS_H2C1 | DSC_BYPASS_H2C2 | DSC_BYPASS_H2C3;
localparam [3:0]    C2H_DSC_BYP_MAP = DSC_BYPASS_C2H0 | DSC_BYPASS_C2H1 | DSC_BYPASS_C2H2 | DSC_BYPASS_C2H3;
localparam          DESC_BYP_EN     = (C2H_DSC_BYP_MAP || H2C_DSC_BYP_MAP) ? 1'b1 : 1'b0;

// ====================================================================
// Internal wires
// ====================================================================

`ifdef AXI4ST_BUS_EN
    wire    [C2H_CHNL_NUM-1:0]             s0_axis_c2h_tready;
    wire    [DATA_WIDTH*C2H_CHNL_NUM-1:0]  s0_axis_c2h_tdata;
    wire    [KEEP_WIDTH*C2H_CHNL_NUM-1:0]  s0_axis_c2h_tkeep;
    wire    [KEEP_WIDTH*C2H_CHNL_NUM-1:0]  s0_axis_c2h_tuser;
    wire    [C2H_CHNL_NUM-1:0]             s0_axis_c2h_tlast;
    wire    [C2H_CHNL_NUM-1:0]             s0_axis_c2h_tvalid;

    wire    [H2C_CHNL_NUM-1:0]             m0_axis_h2c_tready;
    wire    [DATA_WIDTH*H2C_CHNL_NUM-1:0]  m0_axis_h2c_tdata;
    wire    [KEEP_WIDTH*H2C_CHNL_NUM-1:0]  m0_axis_h2c_tkeep;
    wire    [KEEP_WIDTH*H2C_CHNL_NUM-1:0]  m0_axis_h2c_tuser;
    wire    [H2C_CHNL_NUM-1:0]             m0_axis_h2c_tlast;
    wire    [H2C_CHNL_NUM-1:0]             m0_axis_h2c_tvalid;

    wire    [C2H_CHNL_NUM-1:0]             app_c2h_tready;
    wire    [DATA_WIDTH*C2H_CHNL_NUM-1:0]  app_c2h_tdata;
    wire    [KEEP_WIDTH*C2H_CHNL_NUM-1:0]  app_c2h_tkeep;
    wire    [KEEP_WIDTH*C2H_CHNL_NUM-1:0]  app_c2h_tuser;
    wire    [C2H_CHNL_NUM-1:0]             app_c2h_tlast;
    wire    [C2H_CHNL_NUM-1:0]             app_c2h_tvalid;

    // Camera output (128-bit AXI-Stream)
    wire    [DATA_WIDTH-1:0]                cam_tdata;
    wire                                    cam_tvalid;
    wire                                    cam_tready;
    wire                                    cam_tlast;
    wire                                    cam_frame_last;
    wire                                    cam_sof;
    wire                                    cam_eof;
`endif

`ifdef AXI4L_MBUS_EN
    wire    [31:0]                          m_axil_awaddr;
    wire    [2:0]                           m_axil_awprot;
    wire                                    m_axil_awvalid;
    wire                                    m_axil_awready;
    wire    [31:0]                          m_axil_wdata;
    wire    [3:0]                           m_axil_wstrb;
    wire                                    m_axil_wvalid;
    wire                                    m_axil_wready;
    wire                                    m_axil_bvalid;
    wire    [1:0]                           m_axil_bresp;
    wire                                    m_axil_bready;
    wire    [31:0]                          m_axil_araddr;
    wire    [2:0]                           m_axil_arprot;
    wire                                    m_axil_arvalid;
    wire                                    m_axil_arready;
    wire    [31:0]                          m_axil_rdata;
    wire    [1:0]                           m_axil_rresp;
    wire                                    m_axil_rvalid;
    wire                                    m_axil_rready;
    wire    [31:0]                          app_axil_rdata;
`ifndef AXI4ST_BUS_EN
    assign m_axil_rdata = app_axil_rdata;
`endif
`endif

`ifdef USR_IRQ_EN
    wire    [USR_IRQ_NUM-1:0]               usr_irq_req;
    wire    [USR_IRQ_NUM-1:0]               usr_irq_ack;
    wire                                    msi_enable;
    wire    [4:0]                           msi_vector_width;
`endif

`ifdef DSC_BYPASS_C2H_CHL0_EN
    wire c2h_dsc_byp_ready_0, c2h_dsc_byp_load_0;
    wire [63:0] c2h_dsc_byp_src_addr_0, c2h_dsc_byp_dst_addr_0;
    wire [27:0] c2h_dsc_byp_len_0;
    wire [15:0] c2h_dsc_byp_ctl_0;
`endif
`ifdef DSC_BYPASS_H2C_CHL0_EN
    wire h2c_dsc_byp_ready_0, h2c_dsc_byp_load_0;
    wire [63:0] h2c_dsc_byp_src_addr_0, h2c_dsc_byp_dst_addr_0;
    wire [27:0] h2c_dsc_byp_len_0;
    wire [15:0] h2c_dsc_byp_ctl_0;
`endif

    wire [7:0] c2h_sts_0, h2c_sts_0, c2h_sts_1, h2c_sts_1;
    wire [7:0] c2h_sts_2, h2c_sts_2, c2h_sts_3, h2c_sts_3;

    wire        sys_clk_g;
    wire        app_auxclk;
    wire        user_clk;
    wire        user_rst_n;
    wire        core_clk;
    wire        pll_lock;
    wire        user_link_up;

// ====================================================================
// Internal Power-On Reset
// ====================================================================
    reg  [9:0]  int_por_cnt = 10'd0;
    wire        int_por_done = &int_por_cnt;
    reg         int_por_done_r = 1'b0;

    always @(posedge sys_clk_g) begin
        if (!int_por_done)
            int_por_cnt <= int_por_cnt + 1'b1;
        int_por_done_r <= int_por_done;
    end

// ====================================================================
// Global Clock Buffer
// ====================================================================
PH1_LOGIC_BUFG u_sys_clk_bufg (
    .i  (sys_clk    ),
    .o  (sys_clk_g  )
);

// ====================================================================
// MIPI Reference Clock: 100MHz LVDS differential input (T13/T14)
// TD auto-infers LVDS input buffer from IOSTANDARD=LVDS18 constraint.
// Route through BUFG for global clock tree.
// ====================================================================
    wire mipi_ref_clk_bufg;
PH1_LOGIC_BUFG u_mipi_ref_clk_bufg (
    .i  (mipi_ref_clk_p ),
    .o  (mipi_ref_clk_bufg)
);

// ====================================================================
// Camera PLL: 100MHz LVDS -> 150MHz (cam_pclk) + 90MHz (cam_100m) + 54MHz (cam_24m)
// cam_pclk  = mipi_ref_clock for MIPI PHY (150MHz required for Eye-Scan)
// cam_100m  = reserved
// cam_24m   = MCLK source (ODDR) + I2C master clock
// ====================================================================
    wire cam_pclk, cam_100m, cam_24m, ui_pll_lock;
ui_pll u_ui_pll (
    .refclk     (mipi_ref_clk_bufg  ),
    .reset      (1'b0              ),
    .lock       (ui_pll_lock        ),
    .clk0_out   (cam_pclk           ),
    .clk1_out   (cam_100m           ),
    .clk2_out   (cam_24m            )
);

// ====================================================================
// PLL: 25MHz -> 125MHz (core_clk) + 25MHz (app_auxclk)
// ====================================================================
sgdma_pll u_sgdma_pll(
    .refclk     (sys_clk_g          ),
    .reset      (!int_por_done_r    ),
    .lock       (pll_lock           ),
    .clk0_out   (core_clk           ),
    .clk1_out   (app_auxclk         )
);

// ====================================================================
// PERST# + PLL stable
// ====================================================================
    reg  [21:0] pll_lock_cnt;
    wire        pll_lock_stable_comb = (pll_lock_cnt == 22'h3FFFFF);

    always @(posedge core_clk or negedge pll_lock) begin
        if (!pll_lock)
            pll_lock_cnt <= 22'd0;
        else if (!pll_lock_stable_comb)
            pll_lock_cnt <= pll_lock_cnt + 1'b1;
    end

    reg pll_lock_stable;
    always @(posedge core_clk or negedge pll_lock) begin
        if (!pll_lock)
            pll_lock_stable <= 1'b0;
        else
            pll_lock_stable <= pll_lock_stable_comb;
    end

    wire tl_power_on_rstn = pcie_mperst & pll_lock_stable;

    // debug_button removed (no physical button on AFC03 board)
    // Tie high = "not pressed" (same as PULLUP idle state)
    wire debug_button_w = 1'b1;

    // IMX415 XCLR: always release from reset
    assign cam_xclr = 1'b1;

// ====================================================================
// MCLK Generation: 27MHz toggle from cam_24m (ui_pll C2)
// PH1A has no ODDR primitive �� use toggle register.
// cam_24m (54MHz) / 2 = 27MHz, matching mode-0 sensor register timing.
// ====================================================================
    reg cam_mclk_r = 1'b0;
    always @(posedge cam_24m)
        cam_mclk_r <= ~cam_mclk_r;
    assign cam_mclk = cam_mclk_r;

// ====================================================================
// SGDMA Subsystem (identical to Phase 8)
// ====================================================================
sgdma_subsys #(
    .USER_CLK_FREQ  (USER_CLK_FREQ),
    .DEVICE_FAMILY  (DEVICE_FAMILY),
    .LINK_WIDTH     (LINK_WIDTH),
    .DATA_WIDTH     (DATA_WIDTH),
    .H2C_CHNL_NUM  (H2C_CHNL_NUM),
    .C2H_CHNL_NUM  (C2H_CHNL_NUM),
    .USR_IRQ_NUM    (USR_IRQ_NUM),
    .LGCY_EN        (IRQ_LGCY_EN),
    .MSI_EN         (IRQ_MSI_EN),
    .MSIX_EN        (IRQ_MSIX_EN),
    .AXI4MM_BUS_EN  (AXI4MM_BUS_EN),
    .AXI4ST_BUS_EN  (AXI4ST_BUS_EN),
    .H2C_DSC_BYP_MAP(H2C_DSC_BYP_MAP),
    .C2H_DSC_BYP_MAP(C2H_DSC_BYP_MAP)
) u_sgdma_subsys(
    .app_auxclk             (app_auxclk),
    .tl_power_on_rstn       (tl_power_on_rstn),
    .tl_clk_user            (core_clk),
    .pll_lock               (pll_lock),
    .ref_pad_clk_p          (refclk_p),
    .ref_pad_clk_n          (refclk_n),
    .pcie_tx_p              (txp),
    .pcie_tx_n              (txn),
    .pcie_rx_p              (rxp),
    .pcie_rx_n              (rxn),
    .c2h_sts_0              (c2h_sts_0),
    .h2c_sts_0              (h2c_sts_0),
    .c2h_sts_1              (c2h_sts_1),
    .h2c_sts_1              (h2c_sts_1),
    .c2h_sts_2              (c2h_sts_2),
    .h2c_sts_2              (h2c_sts_2),
    .c2h_sts_3              (c2h_sts_3),
    .h2c_sts_3              (h2c_sts_3),
`ifdef AXI4ST_BUS_EN
    .s0_axis_c2h_tready     (s0_axis_c2h_tready),
    .s0_axis_c2h_tdata      (s0_axis_c2h_tdata),
    .s0_axis_c2h_tkeep      (s0_axis_c2h_tkeep),
    .s0_axis_c2h_tuser      (s0_axis_c2h_tuser),
    .s0_axis_c2h_tlast      (s0_axis_c2h_tlast),
    .s0_axis_c2h_tvalid     (s0_axis_c2h_tvalid),
    .m0_axis_h2c_tready     (m0_axis_h2c_tready),
    .m0_axis_h2c_tdata      (m0_axis_h2c_tdata),
    .m0_axis_h2c_tkeep      (m0_axis_h2c_tkeep),
    .m0_axis_h2c_tuser      (m0_axis_h2c_tuser),
    .m0_axis_h2c_tlast      (m0_axis_h2c_tlast),
    .m0_axis_h2c_tvalid     (m0_axis_h2c_tvalid),
`endif
`ifdef AXI4L_MBUS_EN
    .m_axil_awaddr          (m_axil_awaddr),
    .m_axil_awprot          (m_axil_awprot),
    .m_axil_awvalid         (m_axil_awvalid),
    .m_axil_awready         (m_axil_awready),
    .m_axil_wdata           (m_axil_wdata),
    .m_axil_wstrb           (m_axil_wstrb),
    .m_axil_wvalid          (m_axil_wvalid),
    .m_axil_wready          (m_axil_wready),
    .m_axil_bvalid          (m_axil_bvalid),
    .m_axil_bresp           (m_axil_bresp),
    .m_axil_bready          (m_axil_bready),
    .m_axil_araddr          (m_axil_araddr),
    .m_axil_arprot          (m_axil_arprot),
    .m_axil_arvalid         (m_axil_arvalid),
    .m_axil_arready         (m_axil_arready),
    .m_axil_rdata           (m_axil_rdata),
    .m_axil_rresp           (m_axil_rresp),
    .m_axil_rvalid          (m_axil_rvalid),
    .m_axil_rready          (m_axil_rready),
`endif
`ifdef DSC_BYPASS_C2H_CHL0_EN
    .c2h_dsc_byp_ready_0_o (c2h_dsc_byp_ready_0),
    .c2h_dsc_byp_load_0_i  (c2h_dsc_byp_load_0),
    .c2h_dsc_byp_src_addr_0_i(c2h_dsc_byp_src_addr_0),
    .c2h_dsc_byp_dst_addr_0_i(c2h_dsc_byp_dst_addr_0),
    .c2h_dsc_byp_len_0_i   (c2h_dsc_byp_len_0),
    .c2h_dsc_byp_ctl_0_i   (c2h_dsc_byp_ctl_0),
`endif
`ifdef DSC_BYPASS_H2C_CHL0_EN
    .h2c_dsc_byp_ready_0_o (h2c_dsc_byp_ready_0),
    .h2c_dsc_byp_load_0_i  (h2c_dsc_byp_load_0),
    .h2c_dsc_byp_src_addr_0_i(h2c_dsc_byp_src_addr_0),
    .h2c_dsc_byp_dst_addr_0_i(h2c_dsc_byp_dst_addr_0),
    .h2c_dsc_byp_len_0_i   (h2c_dsc_byp_len_0),
    .h2c_dsc_byp_ctl_0_i   (h2c_dsc_byp_ctl_0),
`endif
`ifdef USR_IRQ_EN
    .usr_irq_req            (usr_irq_req),
    .usr_irq_ack            (usr_irq_ack),
    .msi_enable             (msi_enable),
    .msi_vector_width       (msi_vector_width),
`endif
    .user_link_up           (user_link_up),
    .user_clk               (user_clk),
    .user_rst_n             (user_rst_n)
);

// ====================================================================
// Video Source Pipeline
// ====================================================================
`ifdef AXI4ST_BUS_EN

    // ���� Config Registers (Camera) ����
    reg         reg_enable;
    reg         reg_soft_reset;
    reg [1:0]   reg_cam_mode;       // Camera resolution mode (0=1080p, 1=4K, 2=720p)
    reg [7:0]   reg_ae_gain;        // AE gain value
    reg [3:0]   reg_preprocess_mode; // 0=color,1=gray,2=Gaussian,3=HE,4=Gaussian+HE,5=median,6=Sobel;7=reserved;8=lowlight;9=dehaze
    reg [1:0]   reg_source_sel; // 1=camera (default), 2=H2V1 host; change only while stopped
    reg         reg_compress_mode;  // 1=compressed C2H, valid for 1080p only
    reg         ae_gain_wr_toggle;  // toggles on PCIe write �� CDC to cam_24m

    // ���� Resolution Mode LUT (runtime switchable) ����
    // cam_mode �� { img_width[12:0], img_height[12:0], crop_v_start[14:0], crop_v_end[14:0], crop_h_end[14:0] }
    reg  [12:0] cam_img_width;
    reg  [12:0] cam_img_height;
    reg  [14:0] cam_crop_v_start;
    reg  [14:0] cam_crop_v_end;
    reg  [14:0] cam_crop_h_end;

    always @(*) begin
        case (reg_cam_mode)
            2'd0: begin  // 1080p 2��2 binning
                cam_img_width    = 13'd1920;
                cam_img_height   = 13'd1080;
                cam_crop_v_start = 15'd19;
                cam_crop_v_end   = 15'd1100;
                cam_crop_h_end   = 15'd481;
            end
            2'd1: begin  // 4K full resolution
                cam_img_width    = 13'd3840;
                cam_img_height   = 13'd2160;
                cam_crop_v_start = 15'd35;  // was 36 �� fixed: first valid row must be even for correct RGGB Bayer phase
                cam_crop_v_end   = 15'd2196; // was 2197 �� adjusted to keep exactly 2160 valid rows
                cam_crop_h_end   = 15'd961;
            end
            2'd2: begin  // 720p
                cam_img_width    = 13'd1280;
                cam_img_height   = 13'd720;
                cam_crop_v_start = 15'd35;
                cam_crop_v_end   = 15'd756;
                cam_crop_h_end   = 15'd321;
            end
            default: begin // fallback to 1080p
                cam_img_width    = 13'd1920;
                cam_img_height   = 13'd1080;
                cam_crop_v_start = 15'd19;
                cam_crop_v_end   = 15'd1100;
                cam_crop_h_end   = 15'd481;
            end
        endcase
    end

    wire        vid_sys_rst_n = user_rst_n & ~reg_soft_reset;
    wire        cam_sys_rst_n = vid_sys_rst_n;

    // Enable gating
    wire ddr_ready;
    wire [31:0] ddr_status,ddr_capture_fifo_drops,ddr_startup_skips;
    wire [31:0] cam_median_errors,cam_sobel_errors,cam_dehaze_errors;
    wire [223:0] ddr_counters;
    wire [255:0] ddr_first_fault;
    wire host_selected=reg_source_sel[1];
    wire host_run=host_selected && reg_enable && user_link_up && reg_compress_mode && reg_cam_mode==0;
    wire host_valid,host_ready,host_sof,host_eol,host_h2c_ready;
    wire [127:0] host_rgb;
    wire [31:0] host_frame_id,host_frames,host_errors,host_status;
    wire [H2C_CHNL_NUM-1:0] app_h2c_ready;
    wire        cam_enable = host_selected ? host_run :
        (reg_enable & user_link_up & (!reg_compress_mode || ddr_ready));

    // Status wires
    wire [31:0] cam_frame_count;
    wire [31:0] cam_fifo_overflow_count;
    wire        cam_i2c_done;           // cam_24m domain
    wire        cam_mipi_div_clk;       // MIPI HS clock domain
    wire        cam_auto_delay_done;    // MIPI HS �� user_clk CDC
    wire        cam_mipi_tvalid;        // MIPI raw tvalid (debug)
    wire [7:0]  cam_dbg_mipi;           // MIPI debug bus (hs_div_clk)
    wire [7:0]  cam_dbg_delay;          // delay debug bus (hs_div_clk)
    wire [5:0]  cam_dbg_best_len;       // eye-scan best length
    wire        cam_i2c_bus_error;      // I2C bus error
    wire        frame_pulse;

    // ���� CDC: cam_i2c_done (cam_24m �� user_clk) ����
    reg [1:0]   cam_i2c_done_sync;
    wire        cam_i2c_done_s = cam_i2c_done_sync[1];
    always @(posedge user_clk or negedge user_rst_n) begin
        if (!user_rst_n)
            cam_i2c_done_sync <= 2'b00;
        else
            cam_i2c_done_sync <= {cam_i2c_done_sync[0], cam_i2c_done};
    end

    // ���� CDC: cam_auto_delay_done (hs_div_clk �� user_clk) ����
    reg [1:0]   cam_delay_done_sync;
    wire        cam_delay_done_s = cam_delay_done_sync[1];
    always @(posedge user_clk or negedge user_rst_n) begin
        if (!user_rst_n)
            cam_delay_done_sync <= 2'b00;
        else
            cam_delay_done_sync <= {cam_delay_done_sync[0], cam_auto_delay_done};
    end

    // ���� CDC: cam_dbg_best_len (hs_div_clk �� user_clk, quasi-static after calibration) ����
    reg [5:0]   cam_best_len_sync;
    always @(posedge user_clk) begin
        if (cam_delay_done_s)
            cam_best_len_sync <= cam_dbg_best_len;
    end

    // ���� Clock detect: cam_mipi_div_clk �� mipi_clk_present (user_clk) ����
    // Toggle a flag in MIPI clock domain, sample with 2FF sync in user_clk,
    // detect edges to determine clock is alive.
    reg         mipi_clk_toggle;
    always @(posedge cam_mipi_div_clk or negedge user_rst_n) begin
        if (!user_rst_n)
            mipi_clk_toggle <= 1'b0;
        else
            mipi_clk_toggle <= ~mipi_clk_toggle;
    end

    reg [1:0]   mipi_toggle_sync;
    reg         mipi_toggle_prev;
    reg         mipi_clk_present;
    always @(posedge user_clk or negedge user_rst_n) begin
        if (!user_rst_n) begin
            mipi_toggle_sync <= 2'b00;
            mipi_toggle_prev <= 1'b0;
            mipi_clk_present <= 1'b0;
        end else begin
            mipi_toggle_sync <= {mipi_toggle_sync[0], mipi_clk_toggle};
            mipi_toggle_prev <= mipi_toggle_sync[1];
            mipi_clk_present <= (mipi_toggle_sync[1] != mipi_toggle_prev);
        end
    end

    // Frame bytes calculation (same as Phase 8)
    // Active resolution: always from camera mode LUT
    wire [15:0] active_width  = {3'd0, cam_img_width};
    wire [15:0] active_height = {3'd0, cam_img_height};

    localparam BYTES_PER_BEAT = DATA_WIDTH / 8;  // 16 for 128-bit

    wire [31:0] line_bytes_w      = {16'd0, active_width} * 32'd3;  // RGB24 = 3 bytes/pixel
    wire [31:0] beats_raw         = line_bytes_w / BYTES_PER_BEAT;
    wire [31:0] beats_mod         = line_bytes_w % BYTES_PER_BEAT;
    wire [15:0] beats_per_line_w  = (beats_mod == 32'd0) ? beats_raw[15:0] : beats_raw[15:0] + 16'd1;
    wire [31:0] frame_total_beats = {16'd0, beats_per_line_w} * {16'd0, active_height};
    wire [31:0] padded_frame_bytes = frame_total_beats * BYTES_PER_BEAT;

    // ���� cam_video_source (IMX415 camera video source, v2 verified) ����
    // Resolution parameters now driven by runtime registers via reg_cam_mode LUT
    cam_video_source #(
        .MIPI_LAN       (MIPI_LAN),
        .DEVICE         ("PH1A"),
        .BAYER_MODE     ("RGGB"),
        .HOST_INPUT_ENABLE(1)
    ) u_cam_video_source (
        .user_clk           (user_clk),
        .user_rst_n         (cam_sys_rst_n & (host_selected || cam_i2c_done_s)),
        .enable             (cam_enable & (host_selected || cam_i2c_done_s)),
        .host_select(host_selected),.host_valid(host_valid),.host_ready(host_ready),
        .host_sof(host_sof),.host_eol(host_eol),.host_rgb(host_rgb),
        // Runtime resolution parameters
        .cfg_img_width      (cam_img_width),
        .cfg_img_height     (cam_img_height),
        .cfg_crop_v_start   (cam_crop_v_start),
        .cfg_crop_v_end     (cam_crop_v_end),
        .cfg_crop_h_end     (cam_crop_h_end),
        // MIPI CSI-2
        .mipi_ref_clock     (cam_pclk),          // 150MHz from ui_pll C0
        .mipi_clk_hs_rx_p   (mipi_clk_hs_rx_p),
        .mipi_data_hs_p     (mipi_data_hs_p),
        // Accept every frame �� FIFO(2048) + frame_completer absorb tready gaps
        .frame_request      (1'b1),
        // 128-bit AXI-Stream output
        .m_tdata            (cam_tdata),
        .m_tvalid           (cam_tvalid),
        .m_tready           (cam_tready),
        .m_tlast            (cam_tlast),
        .m_frame_last       (cam_frame_last),
        .sof                (cam_sof),
        .eof                (cam_eof),
        .frame_count_out    (cam_frame_count),
        .fifo_overflow_count(cam_fifo_overflow_count),
        .cfg_preprocess_mode(reg_preprocess_mode),
        .preprocess_mode_active(),
        .median_error_count(cam_median_errors),.sobel_error_count(cam_sobel_errors),.dehaze_error_count(cam_dehaze_errors),
        // Debug / status
        .debug_button       (debug_button_w),
        .mipi_div_clk_out   (cam_mipi_div_clk),
        .auto_delay_done    (cam_auto_delay_done),
        .mipi_tvalid_out    (cam_mipi_tvalid),
        .dbg_mipi           (cam_dbg_mipi),
        .dbg_delay          (cam_dbg_delay),
        .dbg_best_len       (cam_dbg_best_len)
    );

    // ���� Camera �� video pipeline (direct, no MUX) ����
    wire [DATA_WIDTH-1:0]   vid_tdata      = cam_tdata;
    wire                    vid_tvalid     = cam_tvalid && !host_selected;
    wire                    vid_frame_last = cam_frame_last;

    // ���� Frame-level gate: pass or drop entire frames based on FIFO capacity ����
    // Prevents mixed-frame artifacts when DMA can't keep up (e.g. 1080p@60fps).
    // Decision made at SOF: if FIFO fill < threshold �� pass; else �� drop silently.
    wire [DATA_WIDTH-1:0]   gated_tdata;
    wire                    gated_tvalid;
    wire                    gated_frame_last;
    wire [31:0]             gate_drop_count;
    wire [31:0]             gate_pass_count;

    wire [11:0]             fifo_fill_level;  // 0..2048

    vid_frame_gate #(
        .DATA_WIDTH     (DATA_WIDTH),
        .FILL_BITS      (12),
        .GATE_THRESHOLD (1024)           // drop if FIFO >= 50% full (1024/2048)
    ) u_frame_gate (
        .clk              (user_clk),
        .rst_n            (vid_sys_rst_n),
        .s_tdata          (vid_tdata),
        .s_tvalid         (vid_tvalid),
        .s_tready         (),            // always 1, unused
        .s_tlast          (cam_tlast),
        .s_frame_last     (vid_frame_last),
        .s_sof            (cam_sof),
        .m_tdata          (gated_tdata),
        .m_tvalid         (gated_tvalid),
        .m_frame_last     (gated_frame_last),
        .fifo_fill_level  (fifo_fill_level),
        .gate_drop_count  (gate_drop_count),
        .gate_pass_count  (gate_pass_count)
    );

    // ���� Frame drop detection + tlast injection ����
    // Detects mid-frame drops (tvalid low for >DROP_IDLE_THRESH cycles)
    // and injects zero+tlast to cleanly terminate partial FIFO packets.
    wire [DATA_WIDTH-1:0] fifo_s_tdata;
    wire                  fifo_s_tvalid;
    wire                  fifo_s_tlast;
    wire                  vid_frame_drop;

    wire                    fifo_in_tready;

    vid_drop_detect #(
        .DATA_WIDTH       (DATA_WIDTH),
        .DROP_IDLE_THRESH (50000)        // ~200us @ 250MHz, beyond H-blank (~35us max)
    ) u_drop_detect (
        .clk              (user_clk),
        .rst_n            (user_rst_n),
        .vid_tdata        (gated_tdata),
        .vid_tvalid       (gated_tvalid),
        .vid_frame_last   (gated_frame_last),
        .downstream_ready (fifo_in_tready),
        .out_tdata        (fifo_s_tdata),
        .out_tvalid       (fifo_s_tvalid),
        .out_tlast        (fifo_s_tlast),
        .drop_pulse       (vid_frame_drop)
    );

    // ���� AXI-Stream FIFO: absorb brief SGDMA tready gaps ����
    wire [DATA_WIDTH-1:0]   fifo_out_tdata;
    wire                    fifo_out_tvalid;
    wire                    fifo_out_tlast;

    wire                    fc_in_tready;

    axis_stream_fifo #(
        .DATA_WIDTH (DATA_WIDTH),
        .DEPTH      (2048),
        .ADDR_BITS  (11)
    ) u_c2h_fifo (
        .clk        (user_clk),
        .rst_n      (vid_sys_rst_n),
        .s_tdata    (fifo_s_tdata),
        .s_tvalid   (fifo_s_tvalid),
        .s_tready   (fifo_in_tready),
        .s_tlast    (fifo_s_tlast),
        .m_tdata    (fifo_out_tdata),
        .m_tvalid   (fifo_out_tvalid),
        .m_tready   (fc_in_tready),
        .m_tlast    (fifo_out_tlast),
        .fill_level (fifo_fill_level)
    );

    // ���� Frame Guardian: flush dropped frames to maintain SGDMA packet boundary ����
    wire [DATA_WIDTH-1:0]   fc_out_tdata;
    wire                    fc_out_tvalid;
    wire                    fc_out_tlast;
    wire [31:0]             fc_drop_count;

    frame_completer #(
        .DATA_WIDTH     (DATA_WIDTH),
        .TIMEOUT_CYCLES (50000)          // ~200us at 250MHz (backup safety net)
    ) u_frame_completer (
        .clk                 (user_clk),
        .rst_n               (vid_sys_rst_n),
        .s_tdata             (fifo_out_tdata),
        .s_tvalid            (fifo_out_tvalid),
        .s_tready            (fc_in_tready),
        .s_tlast             (fifo_out_tlast),
        .m_tdata             (fc_out_tdata),
        .m_tvalid            (fc_out_tvalid),
        .m_tready            (s0_axis_c2h_tready),
        .m_tlast             (fc_out_tlast),
        .drop_count          (fc_drop_count)
    );

    // Backpressure: camera always accepted (gate drops entire frames when needed)
    wire compress_active = reg_compress_mode && (cam_img_width==13'd1920) && (cam_img_height==13'd1080);
    wire comp_in_ready, comp_valid, comp_last;
    wire [127:0] comp_data; wire [15:0] comp_keep;
    wire [31:0] comp_raw_bytes, comp_bytes, comp_tokens, comp_frames, comp_errors;
    wire replay_valid,replay_sof,replay_last;
    wire [127:0] replay_data;
    wire [31:0] replay_id;
    pcie_ddr_camera u_pcie_ddr (
        .ref_clk(mipi_ref_clk_bufg),.user_clk(user_clk),
        .reset_n(vid_sys_rst_n && ui_pll_lock),
        .enable(compress_active && reg_enable && !host_selected),
        .i_valid(cam_tvalid),.i_data(cam_tdata),.i_sof(cam_sof),
        .i_eol(cam_tlast),.i_last(cam_frame_last),
        .o_valid(replay_valid),.o_ready(comp_in_ready && compress_active && reg_enable),
        .o_data(replay_data),.o_sof(replay_sof),.o_last(replay_last),.o_frame_id(replay_id),
        .ready(ddr_ready),.ddr_status(ddr_status),
        .capture_fifo_drops(ddr_capture_fifo_drops),.counters(ddr_counters),
        .startup_skipped_frames(ddr_startup_skips),
        .first_fault(ddr_first_fault),
        .ddr_addr(ddr_addr),.ddr_ba(ddr_ba),.ddr_cke(ddr_cke),.ddr_odt(ddr_odt),
        .ddr_cs_n(ddr_cs_n),.ddr_ras_n(ddr_ras_n),.ddr_cas_n(ddr_cas_n),.ddr_we_n(ddr_we_n),
        .ddr_ck_p(ddr_ck_p),.ddr_ck_n(ddr_ck_n),.ddr_reset_n(ddr_reset_n),
        .ddr_dm(ddr_dm),.ddr_dq(ddr_dq),.ddr_dqs_p(ddr_dqs_p),.ddr_dqs_n(ddr_dqs_n)
    );
    // 16 KiB EOP packets amortize SGDMA/read completion overhead. Keep each
    // packet below the Linux 256 KiB descriptor window and let the receiver
    // reassemble the unchanged frame-level header/payload/footer protocol.
    lz77_rgb_c2h_path #(.IMAGE_WIDTH(1920),.IMAGE_HEIGHT(1080),
        .USE_INPUT_FRAME_ID(1),.PACKET_WORDS(4096),.BLK1_ENABLE(1),.BLK1_BLOCK_BYTES(32768)) u_lz77_rgb_c2h (
        .clk(user_clk), .rst_n(vid_sys_rst_n),
        .i_valid((host_selected ? cam_tvalid : replay_valid) && compress_active && reg_enable),
        .i_ready(comp_in_ready), .i_data(host_selected ? cam_tdata : replay_data),
        .i_sof(host_selected ? cam_sof : replay_sof),
        .i_frame_last(host_selected ? cam_frame_last : replay_last),
        .i_frame_id(host_selected ? host_frame_id : replay_id),
        .o_valid(comp_valid), .o_ready(s0_axis_c2h_tready[0] && compress_active), .o_data(comp_data),
        .o_keep(comp_keep), .o_last(comp_last), .raw_bytes(comp_raw_bytes),
        .compressed_bytes(comp_bytes), .token_count(comp_tokens),
        .frame_count(comp_frames), .error_count(comp_errors)
    );

    h2c_video_source u_host_video (
        .clk(user_clk),.rst_n(vid_sys_rst_n),.enable(host_run),
        .s_data(m0_axis_h2c_tdata[127:0]),.s_keep(m0_axis_h2c_tkeep[15:0]),
        .s_valid(m0_axis_h2c_tvalid[0] && host_selected),.s_ready(host_h2c_ready),
        .o_rgb(host_rgb),.o_valid(host_valid),.o_sof(host_sof),.o_eol(host_eol),.o_ready(host_ready),
        .frame_consumed(cam_tvalid && cam_tready && cam_frame_last),
        .frame_id(host_frame_id),.frame_count(host_frames),.error_count(host_errors),.status(host_status)
    );
    assign m0_axis_h2c_tready = host_selected ? {{(H2C_CHNL_NUM-1){1'b0}},host_h2c_ready} : app_h2c_ready;
    assign cam_tready = host_selected ? (comp_in_ready && host_run) : 1'b1; // DDR capture never stalls the live ISP

    // ���� C2H routing: Frame Completer output �� SGDMA engine ����
    assign s0_axis_c2h_tdata  = compress_active ? comp_data : fc_out_tdata;
    assign s0_axis_c2h_tkeep  = compress_active ? comp_keep : {KEEP_WIDTH{1'b1}};
    assign s0_axis_c2h_tuser  = {KEEP_WIDTH{1'b1}};
    assign s0_axis_c2h_tlast  = compress_active ? comp_last : fc_out_tlast;
    assign s0_axis_c2h_tvalid = compress_active ? comp_valid : fc_out_tvalid;

    // ���� Stall/drop counter (observable via REG_DROP_COUNT) ����
    // Tracks flush-terminated frames. Should be 0 for perfect operation.
    // Non-zero = frames with short SGDMA packet (driver can detect & hold prev).
    wire [31:0] fifo_drop_count = fc_drop_count;

    // ���� Debug counters ����
    reg [31:0] dbg_dma_beat_cnt;
    reg        dbg_tready_ever;
    reg [31:0] drop_detect_count;       // vid_drop_detect trigger count
    reg [31:0] comp_valid_beat_cnt;
    reg [31:0] comp_last_beat_cnt;
    wire       dma_beat_fire_dbg = fc_out_tvalid & s0_axis_c2h_tready;

    always @(posedge user_clk or negedge vid_sys_rst_n) begin
        if (!vid_sys_rst_n) begin
            dbg_dma_beat_cnt  <= 32'd0;
            dbg_tready_ever   <= 1'b0;
            drop_detect_count <= 32'd0;
            comp_valid_beat_cnt <= 32'd0;
            comp_last_beat_cnt  <= 32'd0;
        end else begin
            if (dma_beat_fire_dbg)
                dbg_dma_beat_cnt <= dbg_dma_beat_cnt + 1'b1;
            if (s0_axis_c2h_tready)
                dbg_tready_ever <= 1'b1;
            if (vid_frame_drop)
                drop_detect_count <= drop_detect_count + 1'b1;
            if (comp_valid && s0_axis_c2h_tready[0])
                comp_valid_beat_cnt <= comp_valid_beat_cnt + 1'b1;
            if (comp_valid && s0_axis_c2h_tready[0] && comp_last)
                comp_last_beat_cnt <= comp_last_beat_cnt + 1'b1;
        end
    end

    // Camera SOF detection (for status register)
    reg cam_sof_seen;
    always @(posedge user_clk or negedge vid_sys_rst_n) begin
        if (!vid_sys_rst_n)
            cam_sof_seen <= 1'b0;
        else if (cam_sof)
            cam_sof_seen <= 1'b1;
    end

    assign app_c2h_tready = 1'b0;
`endif

// ====================================================================
// IMX415 I2C Configuration (runs on cam_24m = 54MHz from ui_pll)
// CLK_DIV = 539; 54MHz / (539+1) = 100kHz I2C
// ====================================================================
    // CDC: reg_cam_mode (user_clk 125MHz) �� cam_24m (54MHz)
    (* ASYNC_REG = "TRUE" *) reg [1:0] cam_mode_sync1, cam_mode_sync2;
    always @(posedge cam_24m or negedge ui_pll_lock) begin
        if (!ui_pll_lock) begin
            cam_mode_sync1 <= 2'd0;
            cam_mode_sync2 <= 2'd0;
        end else begin
            cam_mode_sync1 <= reg_cam_mode;
            cam_mode_sync2 <= cam_mode_sync1;
        end
    end

    // ���� AE Gain: CDC + auto-trigger ����
    // reg_ae_gain (user_clk) �� ae_gain_sync (cam_24m)
    (* ASYNC_REG = "TRUE" *) reg [7:0] ae_gain_sync1, ae_gain_sync2;
    always @(posedge cam_24m or negedge ui_pll_lock) begin
        if (!ui_pll_lock) begin
            ae_gain_sync1 <= 8'd100;
            ae_gain_sync2 <= 8'd100;
        end else begin
            ae_gain_sync1 <= reg_ae_gain;
            ae_gain_sync2 <= ae_gain_sync1;
        end
    end

    // CDC: ae_gain_wr_toggle (user_clk) �� cam_24m, edge detect
    (* ASYNC_REG = "TRUE" *) reg [1:0] ae_toggle_sync;
    reg ae_toggle_prev;
    wire ae_wr_edge = ae_toggle_sync[1] ^ ae_toggle_prev;
    always @(posedge cam_24m or negedge ui_pll_lock) begin
        if (!ui_pll_lock) begin
            ae_toggle_sync <= 2'b0;
            ae_toggle_prev <= 1'b0;
        end else begin
            ae_toggle_sync <= {ae_toggle_sync[0], ae_gain_wr_toggle};
            ae_toggle_prev <= ae_toggle_sync[1];
        end
    end

    // AE trigger: pending flag in cam_24m domain
    //   Set on: PCIe write to REG_AE_GAIN (via CDC edge detect)
    //   Cleared on: ae_cfg_done FALLING edge (FSM accepted request and started)
    //   NOTE: Must clear on FSM START (not FSM END) to prevent same-cycle
    //         NBA race where FSM sees old pending=1 and restarts immediately.
    wire ae_cfg_done_w;   // from ui_cfg_imx415
    reg  ae_cfg_done_d1;
    wire ae_cfg_done_rise = ae_cfg_done_w & ~ae_cfg_done_d1;
    wire ae_cfg_done_fall = ~ae_cfg_done_w & ae_cfg_done_d1;
    reg  ae_trig_pending;
    reg  [7:0] ae_write_cnt;  // debug: AE I2C write count (increments each ae_cfg_done_rise)

    always @(posedge cam_24m or negedge ui_pll_lock) begin
        if (!ui_pll_lock) begin
            ae_trig_pending <= 1'b0;   // Initial config already writes gain; trigger from PCIe write only
            ae_cfg_done_d1  <= 1'b1;   // match O_ae_cfg_done reset value
            ae_write_cnt    <= 8'd0;
        end else begin
            ae_cfg_done_d1 <= ae_cfg_done_w;
            if (ae_wr_edge)
                ae_trig_pending <= 1'b1;
            else if (ae_cfg_done_fall)       // clear on FSM START
                ae_trig_pending <= 1'b0;
            if (ae_cfg_done_rise)            // count on FSM END (independent)
                ae_write_cnt <= ae_write_cnt + 1'b1;
        end
    end

    ui_cfg_imx415 #(
        .CLK_DIV    (`CAM_I2C_CLK_DIV)
    ) u_cam_i2c_cfg (
        .I_clk          (cam_24m),
        .I_rst_n        (ui_pll_lock),
        .I_cam_mode     (cam_mode_sync2),  // CDC-synchronized mode
        .I_ae_req       (ae_trig_pending),  // AE trigger: auto on startup + PCIe write
        .I_ae_data      (ae_gain_sync2),    // CDC-synchronized gain value
        .O_cam_scl      (cam_scl),
        .IO_cam_sda     (cam_sda),
        .O_cfg_done     (cam_i2c_done),
        .O_ae_cfg_done  (ae_cfg_done_w),
        .O_bus_error    (cam_i2c_bus_error)
    );

// ====================================================================
// User BAR Register Intercept (0x40-0xA0)
// Extended with camera registers at 0x80-0xA0
// ====================================================================
`ifdef AXI4L_MBUS_EN
`ifdef AXI4ST_BUS_EN
    // ���� Write intercept ����
    // BUG FIX v18: axil_anal.v generates awready/wready with 1-cycle latency,
    // so awvalid & wvalid stay high for 2 cycles per write. Using raw wr_hit
    // causes ae_gain_wr_toggle to flip TWICE (cancelling itself). Fix: use
    // rising-edge pulse to ensure exactly one register update per AXI write.
    wire wr_hit = m_axil_wvalid && m_axil_awvalid &&
                  (m_axil_awaddr[15:8] == 8'h00);
    reg  wr_hit_d1;
    always @(posedge user_clk or negedge user_rst_n)
        if (!user_rst_n) wr_hit_d1 <= 1'b0;
        else             wr_hit_d1 <= wr_hit;
    wire wr_pulse = wr_hit && !wr_hit_d1;  // rising edge of wr_hit

    always @(posedge user_clk or negedge user_rst_n) begin
        if (!user_rst_n) begin
            reg_enable      <= 1'b0;
            reg_source_sel  <= 2'd1;
            reg_soft_reset  <= 1'b0;
            reg_cam_mode    <= 2'd0;    // Default: 1080p@60fps
            reg_ae_gain     <= 8'd100;
            reg_preprocess_mode <= 4'd4;
            reg_compress_mode <= 1'b0;  // Default: 30dB (100 �� 0.3dB)
            ae_gain_wr_toggle <= 1'b0;
        end else begin
            if (reg_soft_reset)
                reg_soft_reset <= 1'b0;

            if (wr_pulse) begin
                case (m_axil_awaddr[7:0])
                    `REG_CTRL: begin
                        reg_enable     <= m_axil_wdata[0];
                        reg_soft_reset <= m_axil_wdata[1];
                    end
                    `REG_SOURCE_SEL: if(!reg_enable && (m_axil_wdata==1 || m_axil_wdata==2))
                        reg_source_sel <= m_axil_wdata[1:0];
                    `REG_CAM_MODE:    reg_cam_mode    <= m_axil_wdata[1:0];
                    `REG_PREPROCESS_MODE: reg_preprocess_mode <= ((m_axil_wdata <= 32'd6) || (m_axil_wdata == 32'd8) || (m_axil_wdata == 32'd9)) ? m_axil_wdata[3:0] : 4'd4;
                    `REG_COMPRESS_MODE: reg_compress_mode <= m_axil_wdata[0];
                    `REG_AE_GAIN: begin
                        reg_ae_gain       <= m_axil_wdata[7:0];
                        ae_gain_wr_toggle <= ~ae_gain_wr_toggle;
                    end
                endcase
            end
        end
    end

    // ���� Read intercept (register range 0x40-0xA0) ����
    reg        vid_rd_sel_d1;

    always @(posedge user_clk or negedge user_rst_n) begin
        if (!user_rst_n)
            vid_rd_sel_d1 <= 1'b0;
        else
            vid_rd_sel_d1 <= m_axil_arvalid &&
                             (m_axil_araddr[15:0] >= 16'h0040) &&
                             (m_axil_araddr[15:0] <= 16'h0130);
    end

    // Active frame count: always camera
    wire [31:0] active_frame_count = host_selected ? host_frames : cam_frame_count;

    reg [31:0] vid_reg_rdata_d1;

    always @(posedge user_clk) begin
        case (m_axil_araddr[15:0])
            // ���� Video registers (0x40-0x7C) ����
            `REG_TPG_STATUS:      vid_reg_rdata_d1 <= {30'd0,
                                                       user_link_up, reg_enable};
            `REG_WIDTH:           vid_reg_rdata_d1 <= {16'd0, active_width};
            `REG_HEIGHT:          vid_reg_rdata_d1 <= {16'd0, active_height};
            `REG_PIXEL_FORMAT:    vid_reg_rdata_d1 <= 32'h0000_0001;
            `REG_FRAME_COUNT:     vid_reg_rdata_d1 <= active_frame_count;
            `REG_FPS_CONFIG:      vid_reg_rdata_d1 <= 32'd0;
            `REG_BYTES_PER_FRAME: vid_reg_rdata_d1 <= {16'd0, active_width} *
                                                      {16'd0, active_height} * 32'd3;
            `REG_VERSION:         vid_reg_rdata_d1 <= `PHASE9_VERSION;
            `REG_CTRL:            vid_reg_rdata_d1 <= {30'd0, reg_soft_reset, reg_enable};
            `REG_PADDED_BYTES:    vid_reg_rdata_d1 <= padded_frame_bytes;
            `REG_DROP_COUNT:      vid_reg_rdata_d1 <= fifo_drop_count;
            `REG_PATTERN_SEL:     vid_reg_rdata_d1 <= 32'd0;
            `REG_DELIVERED_COUNT: vid_reg_rdata_d1 <= active_frame_count;
            `REG_DBG_STATE:       vid_reg_rdata_d1 <= {20'd0,
                                                       1'b1,               // [11] source=Camera (always)
                                                       cam_i2c_done_s,      // [10] I2C config done (synced)
                                                       cam_sof_seen,        // [9]  camera SOF detected
                                                       s0_axis_c2h_tready,  // [8]  DMA tready
                                                       vid_tvalid,          // [7]  video output valid
                                                       cam_enable,          // [6]  camera path enabled
                                                       1'b0,               // [5]  (was TPG enable)
                                                       mipi_clk_present,    // [4]  MIPI clock alive
                                                       vid_frame_last,      // [3]  frame tlast
                                                       dbg_tready_ever,     // [2]  tready ever asserted
                                                       reg_enable,          // [1]  global enable
                                                       user_link_up};       // [0]  PCIe link up
            `REG_DBG_PIX_CNT:     vid_reg_rdata_d1 <= frame_total_beats;
            `REG_DBG_DMA_BEAT:    vid_reg_rdata_d1 <= dbg_dma_beat_cnt;

            // ���� Camera registers (0x80-0x98) ����
            `REG_SOURCE_SEL:      vid_reg_rdata_d1 <= {30'd0,reg_source_sel};  // always camera
            `REG_CAM_STATUS:      vid_reg_rdata_d1 <= {ae_write_cnt,          // [31:24] AE I2C write count
                                                       9'd0,
                                                       ae_trig_pending,     // [14] AE trigger pending
                                                       ae_cfg_done_w,       // [13] AE cfg done from FSM
                                                       1'b0,
                                                       cam_best_len_sync,   // [11:6] eye-scan best length
                                                       cam_mipi_tvalid,     // [5] MIPI raw tvalid (debug, async!)
                                                       cam_delay_done_s,    // [4] auto delay calibration done
                                                       cam_i2c_bus_error,   // [3] I2C bus error (async!)
                                                       cam_sof_seen,        // [2] camera frame active
                                                       mipi_clk_present,    // [1] MIPI clock alive (synced)
                                                       cam_i2c_done_s};     // [0] I2C config done (synced)
            `REG_CAM_FRAME_COUNT: vid_reg_rdata_d1 <= cam_frame_count;
            `REG_CAM_ERROR:       vid_reg_rdata_d1 <= {3'd0, cam_img_width,    // [28:16] active camera width
                                                       3'd0, cam_img_height}; // [12:0]  active camera height
            `REG_CAM_MODE:        vid_reg_rdata_d1 <= {30'd0, reg_cam_mode};
            `REG_DROP_DETECT_CNT: vid_reg_rdata_d1 <= drop_detect_count;
            `REG_AE_GAIN:         vid_reg_rdata_d1 <= {24'd0, reg_ae_gain};
            `REG_GATE_DROP_CNT:   vid_reg_rdata_d1 <= gate_drop_count;
            `REG_GATE_PASS_CNT:   vid_reg_rdata_d1 <= gate_pass_count;
            `REG_PREPROCESS_MODE: vid_reg_rdata_d1 <= {28'd0, reg_preprocess_mode};
            `REG_COMPRESS_MODE:   vid_reg_rdata_d1 <= {31'd0, reg_compress_mode};
            `REG_COMP_RAW_BYTES:  vid_reg_rdata_d1 <= comp_raw_bytes;
            `REG_COMP_BYTES:      vid_reg_rdata_d1 <= comp_bytes;
            `REG_COMP_TOKENS:     vid_reg_rdata_d1 <= comp_tokens;
            `REG_COMP_FRAMES:     vid_reg_rdata_d1 <= comp_frames;
            `REG_COMP_ERRORS:     vid_reg_rdata_d1 <= comp_errors;
            `REG_CAM_FIFO_DROPS:  vid_reg_rdata_d1 <= cam_fifo_overflow_count;
            `REG_DDR_STATUS:      vid_reg_rdata_d1 <= ddr_status;
            `REG_DDR_PUBLISHED:   vid_reg_rdata_d1 <= ddr_counters[63:32];
            `REG_DDR_NO_SLOT:     vid_reg_rdata_d1 <= ddr_counters[95:64];
            `REG_DDR_INVALID:     vid_reg_rdata_d1 <= ddr_counters[127:96];
            `REG_DDR_WRITE_ERR:   vid_reg_rdata_d1 <= ddr_counters[159:128];
            `REG_DDR_READ_ERR:    vid_reg_rdata_d1 <= ddr_counters[191:160];
            `REG_DDR_CAP_DROPS:   vid_reg_rdata_d1 <= ddr_capture_fifo_drops;
            `REG_DDR_REPLAYED:    vid_reg_rdata_d1 <= ddr_counters[223:192];
            `REG_DDR_STORE_STATE: vid_reg_rdata_d1 <= ddr_counters[31:0];
            `REG_DDR_STARTUP_SKIPS: vid_reg_rdata_d1 <= ddr_startup_skips;
            `REG_PRE_MEDIAN_ERRORS: vid_reg_rdata_d1 <= cam_median_errors;
            `REG_PRE_SOBEL_ERRORS: vid_reg_rdata_d1 <= cam_sobel_errors;
            `REG_PRE_DEHAZE_ERRORS: vid_reg_rdata_d1 <= cam_dehaze_errors;
            `REG_HOST_STATUS: vid_reg_rdata_d1 <= host_status;
            `REG_HOST_FRAMES: vid_reg_rdata_d1 <= host_frames;
            `REG_HOST_ERRORS: vid_reg_rdata_d1 <= host_errors;
            `REG_HOST_FRAME_ID: vid_reg_rdata_d1 <= host_frame_id;
            `REG_DDR_FAULT_REASON: vid_reg_rdata_d1 <= ddr_first_fault[31:0];
            `REG_DDR_FAULT_FRAME_ID: vid_reg_rdata_d1 <= ddr_first_fault[63:32];
            `REG_DDR_FAULT_WORDS: vid_reg_rdata_d1 <= ddr_first_fault[95:64];
            `REG_DDR_FAULT_INDEX: vid_reg_rdata_d1 <= ddr_first_fault[127:96];
            `REG_DDR_FAULT_POSITION: vid_reg_rdata_d1 <= ddr_first_fault[159:128];
            `REG_DDR_FAULT_FLAGS: vid_reg_rdata_d1 <= ddr_first_fault[191:160];
            `REG_DDR_FAULT_SEEN_ID: vid_reg_rdata_d1 <= ddr_first_fault[223:192];
            `REG_DDR_FAULT_EXPECTED_WORDS: vid_reg_rdata_d1 <= ddr_first_fault[255:224];
            `REG_COMP_STATUS:     vid_reg_rdata_d1 <= {17'd0,
                                                        comp_last_beat_cnt[7:0],
                                                        comp_valid,
                                                        s0_axis_c2h_tready[0],
                                                        comp_last,
                                                        cam_frame_last,
                                                        cam_tvalid,
                                                        cam_tready,
                                                        compress_active};
            `REG_COMP_VALID_BEATS: vid_reg_rdata_d1 <= comp_valid_beat_cnt;

            default:              vid_reg_rdata_d1 <= 32'd0;
        endcase
    end

    assign m_axil_rdata = vid_rd_sel_d1 ? vid_reg_rdata_d1 : app_axil_rdata;
`endif
`endif

// ====================================================================
// SGDMA Application (identical to Phase 8)
// ====================================================================
sgdma_app #(
    .ODATA_WIDTH    (DATA_WIDTH),
    .OKEEP_WIDTH    (KEEP_WIDTH),
    .H2C_CHNL_NUM  (H2C_CHNL_NUM),
    .H2C_DSC_BYP_MAP(H2C_DSC_BYP_MAP),
    .C2H_CHNL_NUM  (C2H_CHNL_NUM),
    .C2H_DSC_BYP_MAP(C2H_DSC_BYP_MAP),
    .DESC_BYP_EN   (DESC_BYP_EN)
) u_sgdma_app(
    .usr_rst_n                  (user_rst_n),
    .usr_clk                    (user_clk),
`ifdef AXI4ST_BUS_EN
    .m0_axis_h2c_tready         (app_h2c_ready),
    .m0_axis_h2c_tdata          (m0_axis_h2c_tdata),
    .m0_axis_h2c_tkeep          (m0_axis_h2c_tkeep),
    .m0_axis_h2c_tuser          (m0_axis_h2c_tuser),
    .m0_axis_h2c_tlast          (m0_axis_h2c_tlast),
    .m0_axis_h2c_tvalid         (m0_axis_h2c_tvalid & {H2C_CHNL_NUM{!host_selected}}),
    .s0_axis_c2h_tready         (app_c2h_tready),
    .s0_axis_c2h_tdata          (app_c2h_tdata),
    .s0_axis_c2h_tkeep          (app_c2h_tkeep),
    .s0_axis_c2h_tuser          (app_c2h_tuser),
    .s0_axis_c2h_tlast          (app_c2h_tlast),
    .s0_axis_c2h_tvalid         (app_c2h_tvalid),
`endif
`ifdef AXI4L_MBUS_EN
    .m_axil_awaddr              (m_axil_awaddr),
    .m_axil_awprot              (m_axil_awprot),
    .m_axil_awvalid             (m_axil_awvalid),
    .m_axil_awready             (m_axil_awready),
    .m_axil_wdata               (m_axil_wdata),
    .m_axil_wstrb               (m_axil_wstrb),
    .m_axil_wvalid              (m_axil_wvalid),
    .m_axil_wready              (m_axil_wready),
    .m_axil_bvalid              (m_axil_bvalid),
    .m_axil_bresp               (m_axil_bresp),
    .m_axil_bready              (m_axil_bready),
    .m_axil_araddr              (m_axil_araddr),
    .m_axil_arprot              (m_axil_arprot),
    .m_axil_arvalid             (m_axil_arvalid),
    .m_axil_arready             (m_axil_arready),
    .m_axil_rdata               (app_axil_rdata),
    .m_axil_rresp               (m_axil_rresp),
    .m_axil_rvalid              (m_axil_rvalid),
    .m_axil_rready              (m_axil_rready),
`endif
`ifdef DSC_BYPASS_C2H_CHL0_EN
    .c2h_dsc_byp_ready_0_i     (c2h_dsc_byp_ready_0),
    .c2h_dsc_byp_load_0_o      (c2h_dsc_byp_load_0),
    .c2h_dsc_byp_src_addr_0_o  (c2h_dsc_byp_src_addr_0),
    .c2h_dsc_byp_dst_addr_0_o  (c2h_dsc_byp_dst_addr_0),
    .c2h_dsc_byp_len_0_o       (c2h_dsc_byp_len_0),
    .c2h_dsc_byp_ctl_0_o       (c2h_dsc_byp_ctl_0),
`endif
`ifdef DSC_BYPASS_H2C_CHL0_EN
    .h2c_dsc_byp_ready_0_i     (h2c_dsc_byp_ready_0),
    .h2c_dsc_byp_load_0_o      (h2c_dsc_byp_load_0),
    .h2c_dsc_byp_src_addr_0_o  (h2c_dsc_byp_src_addr_0),
    .h2c_dsc_byp_dst_addr_0_o  (h2c_dsc_byp_dst_addr_0),
    .h2c_dsc_byp_len_0_o       (h2c_dsc_byp_len_0),
    .h2c_dsc_byp_ctl_0_o       (h2c_dsc_byp_ctl_0),
`endif
`ifdef USR_IRQ_EN
    .usr_irq_req                (usr_irq_req),
    .usr_irq_ack                (usr_irq_ack),
    .msi_enable                 (msi_enable),
    .msi_vector_width           (msi_vector_width),
`endif
    .c2h_sts_0                  (c2h_sts_0),
    .h2c_sts_0                  (h2c_sts_0),
    .c2h_sts_1                  (c2h_sts_1),
    .h2c_sts_1                  (h2c_sts_1),
    .c2h_sts_2                  (c2h_sts_2),
    .h2c_sts_2                  (h2c_sts_2),
    .c2h_sts_3                  (c2h_sts_3),
    .h2c_sts_3                  (h2c_sts_3)
);

// ====================================================================
// Debug UART (115200 8N1, periodic status output every 0.5s)
// Clock: app_auxclk (25MHz from sgdma_pll, always available after PLL lock)
// Output format: "S:xx F:xxxxxxxx\r\n"
// Status byte: [0]=pll_lock [1]=pll_lock_stable [2]=link_up [3]=ui_pll_lock
// ====================================================================

    // CDC: pll_lock_stable (core_clk �� app_auxclk, same PLL but different freq)
    reg [1:0] dbg_pll_stable_sync;
    always @(posedge app_auxclk)
        dbg_pll_stable_sync <= {dbg_pll_stable_sync[0], pll_lock_stable};

    // CDC: user_link_up (user_clk �� app_auxclk, fully async)
    reg [2:0] dbg_link_up_sync;
    always @(posedge app_auxclk or negedge pll_lock) begin
        if (!pll_lock)
            dbg_link_up_sync <= 3'b0;
        else
            dbg_link_up_sync <= {dbg_link_up_sync[1:0], user_link_up};
    end

    // Assemble status word
    wire [15:0] dbg_uart_status = {12'd0,
                                   ui_pll_lock,              // [3]
                                   dbg_link_up_sync[2],      // [2]
                                   dbg_pll_stable_sync[1],   // [1]
                                   pll_lock};                // [0]

    // Frame count (user_clk domain, sampled without formal CDC �� debug display only)
`ifdef AXI4ST_BUS_EN
    wire [31:0] dbg_uart_fcount = cam_frame_count;
`else
    wire [31:0] dbg_uart_fcount = 32'd0;
`endif

    debug_uart #(
        .CLK_FREQ   (25_000_000),       // app_auxclk = 25MHz
        .BAUD_RATE  (115200)
    ) u_debug_uart (
        .clk         (app_auxclk),
        .rst_n       (pll_lock),
        .tx          (uart_tx),
        .rx          (uart_rx),
        .status      (dbg_uart_status),
        .frame_count (dbg_uart_fcount)
    );

endmodule
