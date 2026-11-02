`timescale 1ns/1ps
// Phase-1 LZ77 frame formatter. Header and footer are little-endian 32-bit
// words; payload bytes are packed little-endian in o_data according to o_keep.
//
// Header (16 bytes):
//   word0 = ASCII "LZ77" (0x37375a4c)
//   word1 = {height[15:0], width[15:0]}
//   word2 = 0 (raw length is reported in footer in phase 1)
//   word3 = frame id
// Footer (20 bytes):
//   word0 = ASCII "END!" (0x21444e45)
//   word1 = raw byte count recovered from match/literal tokens
//   word2 = compressed payload byte count
//   word3 = token count
//   word4 = reflected CRC32 of payload bytes
// Payload token bytes are self-describing: literal=00,literal; match=80|len,distance.
module lz77_frame_formatter #(
    parameter integer IMAGE_WIDTH=1920,
    parameter integer IMAGE_HEIGHT=1080
)(
    input wire clk,rst_n,
    input wire i_valid,
    output wire i_ready,
    input wire [15:0] i_token,
    input wire i_match,
    input wire [1:0] i_bytes,
    input wire i_sof,
    input wire i_last,
    input wire [31:0] i_frame_id,
    output reg o_valid,
    input wire o_ready,
    output reg [31:0] o_data,
    output reg [2:0] o_keep,
    output reg o_sof,
    output reg o_last,
    output reg [31:0] frame_count,
    output reg [31:0] error_count
);
    localparam ST_IDLE=2'd0,ST_HEADER=2'd1,ST_PAYLOAD=2'd2,ST_FOOTER=2'd3;
    reg [1:0] state;
    reg [3:0] word_index;
    reg pending_valid,pending_match,pending_last;
    reg [1:0] pending_bytes;
    reg [15:0] pending_token;
    reg [31:0] pending_frame;
    reg [31:0] raw_count,comp_count,tokens;
    reg [31:0] footer_raw,footer_comp,footer_tokens,footer_crc,crc_reg;
    function [31:0] crc32_byte;
        input [31:0] c; input [7:0] b; reg [31:0] x; integer k;
        begin x=c^b; for(k=0;k<8;k=k+1) x=x[0]?((x>>1)^32'hEDB88320):(x>>1); crc32_byte=x; end
    endfunction
    wire [7:0] payload_b0=pending_match?(8'h80|pending_token[14:8]):8'h00;
    wire [7:0] payload_b1=pending_token[7:0];
    wire [31:0] crc_after=crc32_byte(crc32_byte(crc_reg,payload_b0),payload_b1);
    wire take_out=o_valid && o_ready;
    assign i_ready = (state==ST_IDLE) ||
                     (state==ST_PAYLOAD &&
                      (!pending_valid || (o_ready && !pending_last)));

    always @(*) begin
        o_valid=0;o_data=0;o_keep=0;o_sof=0;o_last=0;
        if(state==ST_HEADER) begin
            o_valid=1;o_keep=3'd4;o_sof=(word_index==0);
            case(word_index)
                0:o_data=32'h37375a4c;
                1:o_data={IMAGE_HEIGHT[15:0],IMAGE_WIDTH[15:0]};
                2:o_data=32'd0;
                default:o_data=pending_frame;
            endcase
        end else if(state==ST_PAYLOAD && pending_valid) begin
            o_valid=1;o_keep=3'd2;o_data={16'd0,payload_b1,payload_b0};
            o_sof=0;o_last=0;
        end else if(state==ST_FOOTER) begin
            o_valid=1;o_keep=3'd4;o_last=(word_index==4);
            case(word_index)
                0:o_data=32'h21444e45;
                1:o_data=footer_raw;
                2:o_data=footer_comp;
                3:o_data=footer_tokens;
                default:o_data=footer_crc;
            endcase
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=ST_IDLE;word_index<=0;pending_valid<=0;pending_match<=0;pending_last<=0;
            pending_bytes<=0;pending_token<=0;pending_frame<=0;
            raw_count<=0;comp_count<=0;tokens<=0;footer_raw<=0;footer_comp<=0;footer_tokens<=0;footer_crc<=0;crc_reg<=32'hFFFFFFFF;
            frame_count<=0;error_count<=0;
        end else begin
            if(state==ST_IDLE) begin
                if(i_valid && i_ready) begin
                    if(!i_sof) error_count<=error_count+1'b1;
                    pending_valid<=1;pending_match<=i_match;pending_last<=i_last;
                    pending_bytes<=i_bytes;pending_token<=i_token;pending_frame<=i_frame_id;
                    raw_count<=0;comp_count<=0;tokens<=0;crc_reg<=32'hFFFFFFFF;word_index<=0;state<=ST_HEADER;
                end
            end else if(state==ST_HEADER) begin
                if(take_out) begin
                    if(word_index==3) begin state<=ST_PAYLOAD;word_index<=0;end
                    else word_index<=word_index+1'b1;
                end
            end else if(state==ST_PAYLOAD) begin
                if(pending_valid && o_ready) begin
                    if(pending_match) raw_count<=raw_count+pending_token[14:8];
                    else raw_count<=raw_count+1'b1;
                    comp_count<=comp_count+2;
                    tokens<=tokens+1'b1;
                    crc_reg<=crc_after;
                    if(pending_last) begin
                        footer_raw<=raw_count+(pending_match ? pending_token[14:8] : 1);
                        footer_comp<=comp_count+2;
                        footer_tokens<=tokens+1'b1;
                        footer_crc<=~crc_after;
                        pending_valid<=0;word_index<=0;state<=ST_FOOTER;
                    end else if(i_valid && i_ready) begin
                        pending_valid<=1;pending_match<=i_match;pending_last<=i_last;
                        pending_bytes<=i_bytes;pending_token<=i_token;pending_frame<=pending_frame;
                    end else pending_valid<=0;
                end else if(!pending_valid && i_valid && i_ready) begin
                    pending_valid<=1;pending_match<=i_match;pending_last<=i_last;
                    pending_bytes<=i_bytes;pending_token<=i_token;
                end
            end else if(state==ST_FOOTER) begin
                if(take_out) begin
                    if(word_index==4) begin
                        frame_count<=frame_count+1'b1;state<=ST_IDLE;word_index<=0;
                    end else word_index<=word_index+1'b1;
                end
            end
        end
    end
endmodule
