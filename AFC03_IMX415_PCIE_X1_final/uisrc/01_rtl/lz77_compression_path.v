`timescale 1ns/1ps
// DDR-read integration wrapper. Input is the existing 32-bit YUYV beat from
// ui_dbuf.R. Output is a framed LZ77 byte/word stream; transport is deliberately
// left outside so this path can be tested before changing the working display.
module lz77_compression_path #(
    parameter integer IMAGE_WIDTH=1920, IMAGE_HEIGHT=1080
)(
    input wire clk,rst_n,
    input wire i_valid, output wire i_ready,
    input wire [31:0] i_data, input wire i_sof, input wire i_eol,
    input wire [31:0] i_frame_id,
    output wire o_valid, input wire o_ready,
    output wire [31:0] o_data, output wire [2:0] o_keep,
    output wire o_sof,o_last,
    output wire [31:0] raw_bytes,compressed_bytes,token_count,frame_count,error_count
);
    wire b_valid,b_ready,b_sof,b_eol,b_last;
    wire [7:0] b_data;
    wire [15:0] enc_token;
    wire enc_match,enc_sof,enc_last,enc_valid,enc_ready;
    wire [1:0] enc_bytes;
    wire [31:0] enc_raw,enc_comp,enc_tokens,enc_frames,enc_errors;
    wire [31:0] fmt_frames,fmt_errors;

    yuyv32_byte_stream #(.IMAGE_HEIGHT(IMAGE_HEIGHT)) u_yuyv32_byte_stream(
        .clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_ready(i_ready),.i_data(i_data),
        .i_sof(i_sof),.i_eol(i_eol),.o_valid(b_valid),.o_ready(b_ready),.o_data(b_data),
        .o_sof(b_sof),.o_eol(b_eol),.o_last(b_last),.line_count(),.error_count());

    lz77_repeat_encoder u_lz77_repeat_encoder(
        .clk(clk),.rst_n(rst_n),.i_valid(b_valid),.i_ready(b_ready),.i_data(b_data),
        .i_sof(b_sof),.i_last(b_last),.o_valid(enc_valid),.o_ready(enc_ready),
        .o_token(enc_token),.o_match(enc_match),.o_sof(enc_sof),.o_last(enc_last),
        .o_bytes(enc_bytes),.raw_byte_count(enc_raw),.compressed_byte_count(enc_comp),
        .token_count(enc_tokens),.frame_count(enc_frames),.error_count(enc_errors));

    lz77_frame_formatter #(.IMAGE_WIDTH(IMAGE_WIDTH),.IMAGE_HEIGHT(IMAGE_HEIGHT)) u_lz77_frame_formatter(
        .clk(clk),.rst_n(rst_n),.i_valid(enc_valid),.i_ready(enc_ready),.i_token(enc_token),
        .i_match(enc_match),.i_bytes(enc_bytes),.i_sof(enc_sof),.i_last(enc_last),
        .i_frame_id(i_frame_id),.o_valid(o_valid),.o_ready(o_ready),.o_data(o_data),
        .o_keep(o_keep),.o_sof(o_sof),.o_last(o_last),.frame_count(fmt_frames),.error_count(fmt_errors));

    assign raw_bytes=enc_raw;
    assign compressed_bytes=enc_comp;
    assign token_count=enc_tokens;
    assign frame_count=fmt_frames;
    assign error_count=enc_errors+fmt_errors;
endmodule
