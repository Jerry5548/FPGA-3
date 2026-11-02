`timescale 1ns/1ps
// Mode 8: color-preserving low-light enhancement.
// Each RGB channel uses a fixed gamma=0.5 LUT: round(sqrt(255*x)).
// RGBX8888 x4, one registered stage, no drain and no backpressure.
module lowlight_enhance_stream #(
    parameter integer IMAGE_WIDTH=1920, IMAGE_HEIGHT=1080
)(
    input wire clk,rst_n,i_valid,i_sof,i_eol,
    input wire [127:0] i_rgb,
    output reg o_valid,o_sof,o_eol,
    output reg [127:0] o_rgb
);
    reg [7:0] gamma_lut [0:255];
    reg [127:0] rgb_d;
    reg v_d,s_d,e_d;
    integer gi,g,g2,p,k;
    initial begin
        for(gi=0;gi<256;gi=gi+1) begin
            p=gi*255; g=0;
            for(g2=0;g2<256;g2=g2+1) if(g2*g2<=p) g=g2;
            if(g<255 && ((g+1)*(g+1)-p)<=(p-g*g)) g=g+1;
            gamma_lut[gi]=g[7:0];
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            rgb_d<=0;v_d<=0;s_d<=0;e_d<=0;
            o_rgb<=0;o_valid<=0;o_sof<=0;o_eol<=0;
        end else begin
            rgb_d<=i_rgb;v_d<=i_valid;s_d<=i_valid&&i_sof;e_d<=i_valid&&i_eol;
            o_valid<=v_d;o_sof<=s_d;o_eol<=e_d;
            if(v_d) for(k=0;k<4;k=k+1) begin
                o_rgb[k*32 +: 8]    <= gamma_lut[rgb_d[k*32 +: 8]];
                o_rgb[k*32+8 +: 8]  <= gamma_lut[rgb_d[k*32+8 +: 8]];
                o_rgb[k*32+16 +: 8] <= gamma_lut[rgb_d[k*32+16 +: 8]];
                o_rgb[k*32+24 +: 8] <= rgb_d[k*32+24 +: 8];
            end
        end
    end
endmodule
