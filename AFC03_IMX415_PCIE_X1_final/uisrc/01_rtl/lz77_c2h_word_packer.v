`timescale 1ns/1ps
// Pack formatter words into contiguous 128-bit C2H beats.
// The formatter emits 2 or 4 valid bytes in a 32-bit word.  Padding that word
// directly to 128 bits loses TKEEP information in the Linux character stream.
// This module concatenates the valid bytes and emits full 16-byte beats.
module lz77_c2h_word_packer #(
    parameter integer PACKET_BEATS=64
)(
    input wire clk, input wire rst_n,
    input wire i_valid, output wire i_ready,
    input wire [31:0] i_data, input wire [2:0] i_keep, input wire i_last,
    output reg o_valid, input wire o_ready,
    output reg [127:0] o_data, output reg [15:0] o_keep, output reg o_last
);
    reg [127:0] acc;
    reg [4:0] acc_bytes;
    localparam integer BEAT_BITS=(PACKET_BEATS>1) ? $clog2(PACKET_BEATS) : 1;
    reg [BEAT_BITS-1:0] packet_beats;
    reg out_valid;
    reg [159:0] next_acc;
    reg [5:0] next_bytes;
    reg end_pending;
    integer n, j;
    wire [4:0] input_bytes = (i_keep == 3'd4) ? 5'd4 :
                             (i_keep == 3'd2) ? 5'd2 : 5'd0;
    // 14 + 4 bytes emits a FULL beat with two carry bytes. Partial TKEEP is
    // used only on TLAST, never in the middle of a PCIe packet.
    assign i_ready = !out_valid && !end_pending && input_bytes != 0;
    function [15:0] mask_for_bytes;
        input [4:0] cnt;
        begin
            if (cnt >= 16) mask_for_bytes = 16'hffff;
            else if (cnt == 0) mask_for_bytes = 16'h0000;
            else mask_for_bytes = (16'h0001 << cnt) - 1'b1;
        end
    endfunction
    always @(*) begin
        next_acc = {32'd0,acc};
        for (j=0; j<4; j=j+1)
            if (j < input_bytes)
                next_acc[(acc_bytes+j)*8 +: 8] = i_data[j*8 +: 8];
        next_bytes = acc_bytes + input_bytes;
    end
    always @(*) begin
        o_valid = out_valid;
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc<=0; acc_bytes<=0; packet_beats<=0; out_valid<=0;end_pending<=0;
            o_data<=0; o_keep<=0; o_last<=0;
        end else begin
            if (out_valid && o_ready) begin
                out_valid <= 0;
                o_last <= 0;
                if (o_last) packet_beats <= 0;
                else packet_beats <= packet_beats + 1'b1;
            end
            // The last input word may itself straddle two output beats.
            if (!out_valid && end_pending) begin
                o_data <= acc;
                o_keep <= mask_for_bytes(acc_bytes);
                o_last <= 1;
                out_valid <= 1;
                acc <= 0;
                acc_bytes <= 0;
                end_pending <= 0;
            end else if (i_valid && i_ready) begin
                if (next_bytes >= 16 || i_last) begin
                    o_data <= next_acc[127:0];
                    o_keep <= next_bytes >= 16 ? 16'hffff : mask_for_bytes(next_bytes[4:0]);
                    o_last <= (i_last && next_bytes <= 16) || (packet_beats == PACKET_BEATS-1);
                    out_valid <= 1;
                    if(next_bytes>16) begin
                        acc <= {96'd0,next_acc[159:128]};
                        acc_bytes <= next_bytes-16;
                        end_pending <= i_last;
                    end else begin
                        acc <= 0;acc_bytes <= 0;
                    end
                end else begin
                    acc <= next_acc[127:0];
                    acc_bytes <= next_bytes[4:0];
                end
            end
        end
    end
endmodule
