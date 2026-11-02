`timescale 1ns/1ps
// Existing DDR read path is 32-bit YUYV (two pixels) per beat. This adapter
// emits its four bytes, low byte first, while deriving frame-last from EOL and
// IMAGE_HEIGHT. It accepts one input word only after the previous word drained
// so a downstream LZ77 encoder can apply backpressure without data loss.
module yuyv32_byte_stream #(
    parameter integer IMAGE_HEIGHT=1080
)(
    input wire clk,rst_n,
    input wire i_valid,
    output wire i_ready,
    input wire [31:0] i_data,
    input wire i_sof,
    input wire i_eol,
    output reg o_valid,
    input wire o_ready,
    output reg [7:0] o_data,
    output reg o_sof,
    output reg o_eol,
    output reg o_last,
    output reg [15:0] line_count,
    output reg [31:0] error_count
);
    reg active;
    reg [31:0] data_q;
    reg [1:0] byte_index;
    reg sof_q,eol_q,last_q;
    reg [15:0] line_q;
    assign i_ready=!active;
    always @(*) begin
        o_valid=active;
        o_data=data_q[byte_index*8 +: 8];
        o_sof=active && sof_q && byte_index==0;
        o_eol=active && eol_q && byte_index==3;
        o_last=active && last_q && byte_index==3;
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            active<=0;data_q<=0;byte_index<=0;sof_q<=0;eol_q<=0;last_q<=0;
            line_q<=0;line_count<=0;error_count<=0;
        end else begin
            if(i_valid && i_ready) begin
                if(i_sof && line_q!=0) error_count<=error_count+1'b1;
                data_q<=i_data;byte_index<=0;active<=1;sof_q<=i_sof;eol_q<=i_eol;
                last_q<=i_eol && ((i_sof ? 16'd0 : line_q)==IMAGE_HEIGHT-1);
                if(i_sof) line_q<=i_eol ? 16'd1 : 16'd0;
                else if(i_eol) line_q<=line_q+1'b1;
            end else if(o_valid && o_ready) begin
                if(byte_index==3) begin active<=0;byte_index<=0;end
                else byte_index<=byte_index+1'b1;
            end
            line_count<=line_q;
        end
    end
endmodule
