`timescale 1ns/1ps
// RGBX8888 x4 -> full-range gray8 x4. Pixel 0 occupies the low bits.
// Rounded Y=(77R+150G+29B+128)/256. Two registered stages, no backpressure.
module gray_pixel_stream (
    input wire clk, rst_n, i_valid, i_sof, i_eol,
    input wire [127:0] i_rgb,
    output reg o_valid, o_sof, o_eol,
    output reg [31:0] o_gray
);
    reg [15:0] sum [0:3];
    reg valid_d, sof_d, eol_d;
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            valid_d<=0; sof_d<=0; eol_d<=0;
            o_valid<=0; o_sof<=0; o_eol<=0; o_gray<=0;
            for(k=0;k<4;k=k+1) sum[k]<=0;
        end else begin
            valid_d<=i_valid; sof_d<=i_valid && i_sof; eol_d<=i_valid && i_eol;
            o_valid<=valid_d; o_sof<=sof_d; o_eol<=eol_d;
            if(i_valid) for(k=0;k<4;k=k+1)
                sum[k]<=i_rgb[k*32+16 +: 8]*16'd77 +
                        i_rgb[k*32+8 +: 8]*16'd150 +
                        i_rgb[k*32 +: 8]*16'd29 + 16'd128;
            if(valid_d) for(k=0;k<4;k=k+1) o_gray[k*8 +: 8]<=sum[k][15:8];
        end
    end
endmodule
