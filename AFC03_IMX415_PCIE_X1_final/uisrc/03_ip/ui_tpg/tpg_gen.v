// ============================================================================
// tpg_gen.v - 标准视频时序 TPG 包装器（无背压版本）
//
// 数据流：ui_vtc -> ui_tpg -> stdvid_nobp_packer
//
// 设计目标：
//   1. 源头始终按标准视频时序自由流动（vs/hs/de）
//   2. 不通过 m_tready 反控视频源
//   3. 仅在需要输出 beat 的时刻检查 m_tready
//      若下游未就绪，则丢弃当前帧剩余数据，等待下一帧重新开始
//   4. 保持原 tpg_gen 顶层接口不变，便于继续挂接现有顶层/寄存器
// ============================================================================

`timescale 1ns / 1ps

`include "../../01_rtl/param_tpg.v"

module tpg_gen #(
    parameter integer SRC_H_ACTIVE = `DEFAULT_WIDTH,
    parameter integer SRC_H_FRONT  = 88,
    parameter integer SRC_H_SYNC   = 44,
    parameter integer SRC_H_BACK   = 148,
    parameter integer SRC_V_ACTIVE = `DEFAULT_HEIGHT,
    parameter integer SRC_V_FRONT  = 4,
    parameter integer SRC_V_SYNC   = 5,
    parameter integer SRC_V_BACK   = 36
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         enable,
    input  wire         frame_pulse,
    input  wire [15:0]  cfg_width,
    input  wire [15:0]  cfg_height,
    input  wire [3:0]   cfg_pattern,
    input  wire [23:0]  cfg_solid_color,
    output wire [511:0] m_tdata,
    output wire         m_tvalid,
    input  wire         m_tready,
    output wire         m_tlast,
    output wire         m_frame_last,
    output wire         sof,
    output wire         eof,
    output wire [31:0]  frame_count_out
);

    localparam integer SRC_H_FRAME = SRC_H_ACTIVE + SRC_H_FRONT + SRC_H_SYNC + SRC_H_BACK;
    localparam integer SRC_V_FRAME = SRC_V_ACTIVE + SRC_V_FRONT + SRC_V_SYNC + SRC_V_BACK;
    localparam [15:0]  SRC_W_U16   = SRC_H_ACTIVE;
    localparam [15:0]  SRC_H_U16   = SRC_V_ACTIVE;

    wire        src_rst_n = rst_n & enable;
    wire        src_vs;
    wire        src_hs;
    wire        src_de;
    wire        src_user;
    wire        src_last;
    wire [23:0] src_data;

    reg         src_vs_d;
    reg [15:0]  act_width;
    reg [15:0]  act_height;
    reg [3:0]   act_pattern;
    reg [23:0]  act_solid_color;

    wire src_vs_rise = src_vs & ~src_vs_d;

    wire [15:0] clamped_width = (cfg_width < 16'd64) ? 16'd64 :
                                ((cfg_width > SRC_W_U16) ? SRC_W_U16 : cfg_width);
    wire [15:0] clamped_height = (cfg_height == 16'd0) ? 16'd1 :
                                 ((cfg_height > SRC_H_U16) ? SRC_H_U16 : cfg_height);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            src_vs_d        <= 1'b0;
            act_width       <= `DEFAULT_WIDTH;
            act_height      <= `DEFAULT_HEIGHT;
            act_pattern     <= `PATTERN_COLORBAR;
            act_solid_color <= 24'hFF0000;
        end else begin
            src_vs_d <= src_vs;

            // 在场同步起始处锁存新配置，保证首个有效像素到来前配置已稳定
            if (src_vs_rise) begin
                act_width       <= clamped_width;
                act_height      <= clamped_height;
                act_pattern     <= cfg_pattern;
                act_solid_color <= cfg_solid_color;
            end
        end
    end

    ui_vtc #(
        .H_ActiveSize (SRC_H_ACTIVE),
        .H_FrameSize  (SRC_H_FRAME),
        .H_SyncStart  (SRC_H_ACTIVE + SRC_H_FRONT),
        .H_SyncEnd    (SRC_H_ACTIVE + SRC_H_FRONT + SRC_H_SYNC),
        .V_ActiveSize (SRC_V_ACTIVE),
        .V_FrameSize  (SRC_V_FRAME),
        .V_SyncStart  (SRC_V_ACTIVE + SRC_V_FRONT),
        .V_SyncEnd    (SRC_V_ACTIVE + SRC_V_FRONT + SRC_V_SYNC)
    ) X_ui_vtc (
        .I_vtc_rstn     (src_rst_n),
        .I_vtc_clk      (clk),
        .O_vtc_vs       (src_vs),
        .O_vtc_hs       (src_hs),
        .O_vtc_de_valid (src_de),
        .O_vtc_user     (src_user),
        .O_vtc_last     (src_last)
    );

    ui_tpg X_ui_tpg (
        .I_tpg_clk         (clk),
        .I_tpg_rstn        (src_rst_n),
        .I_tpg_vs          (src_vs),
        .I_tpg_hs          (src_hs),
        .I_tpg_de          (src_de),
        .I_tpg_width       (act_width),
        .I_tpg_mode        (act_pattern),
        .I_tpg_solid_color (act_solid_color),
        .O_tpg_vs          (),
        .O_tpg_hs          (),
        .O_tpg_de          (),
        .O_tpg_data        (src_data)
    );

    stdvid_nobp_packer u_stdvid_nobp_packer (
        .clk             (clk),
        .rst_n           (rst_n),
        .enable          (enable),
        .frame_request   (frame_pulse),
        .act_width       (act_width),
        .act_height      (act_height),
        .src_de          (src_de),
        .src_user        (src_user),
        .src_last        (src_last),
        .src_data        (src_data),
        .m_tdata         (m_tdata),
        .m_tvalid        (m_tvalid),
        .m_tready        (m_tready),
        .m_tlast         (m_tlast),
        .m_frame_last    (m_frame_last),
        .sof             (sof),
        .eof             (eof),
        .frame_count_out (frame_count_out)
    );

endmodule
