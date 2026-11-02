`timescale 1ns/1ps
// Centered Gaussian [1 2 1]'*[1 2 1]/16, rounded once; replicated borders.
// Four neighboring pixels per beat; W multiple of four, W>=4, H>=2.
// Two synchronous-read line memories, no frame buffer, no backpressure.
// Input must leave W/4+5 idle clocks after the final beat for bottom-row drain.
// busy indicates drain; input during drain increments protocol_error_count.
module gaussian_3x3_stream #(
    parameter integer IMAGE_WIDTH=1920, IMAGE_HEIGHT=1080
)(
    input wire clk,rst_n,i_valid,i_sof,i_eol,
    input wire [31:0] i_gray,
    output reg o_valid,o_sof,o_eol,
    output reg [31:0] o_gray,
    output wire busy,
    output reg [31:0] protocol_error_count
);
    localparam integer WORDS=IMAGE_WIDTH/4;
    reg [31:0] line1[0:WORDS-1], line2[0:WORDS-1];
    reg [15:0] x,y,flush_x;
    reg flushing,armed;
    reg [31:0] top_d,mid_d,bot_d;
    reg v_d,sof_d,eol_d,first_d,top_edge_d,bottom_d;
    reg [39:0] vertical;
    reg v_s,sof_s,eol_s,first_s;
    reg pending,p_sof,p_eol;
    reg [39:0] p;
    reg [9:0] left;
    integer k;
    wire [15:0] ix=i_sof ? 16'd0 : x;
    wire [15:0] iy=i_sof ? 16'd0 : y;
    assign busy=flushing || (v_d && bottom_d) || (v_s && eol_s) || (pending && p_eol);
    function [7:0] horizontal;
        input [9:0] a,b,c;
        reg [11:0] total;
        begin total={2'b0,a}+({2'b0,b}<<1)+{2'b0,c}+12'd8;
            horizontal=total[11:4]; end
    endfunction
    // No reset on memories/read data: synchronous RAM inference in TD.
    always @(posedge clk) begin
        if(flushing) begin
            top_d<=line2[flush_x]; mid_d<=line1[flush_x]; bot_d<=line1[flush_x];
        end else if(i_valid && (armed || i_sof)) begin
            top_d<=line2[ix]; mid_d<=line1[ix]; bot_d<=i_gray;
            line2[ix]<=line1[ix]; line1[ix]<=i_gray;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            x<=0;y<=0;flush_x<=0;flushing<=0;armed<=0;
            v_d<=0;sof_d<=0;eol_d<=0;first_d<=0;top_edge_d<=0;bottom_d<=0;
            vertical<=0;v_s<=0;sof_s<=0;eol_s<=0;first_s<=0;
            pending<=0;p_sof<=0;p_eol<=0;p<=0;left<=0;
            o_valid<=0;o_sof<=0;o_eol<=0;o_gray<=0;protocol_error_count<=0;
        end else begin
            v_d<=0; sof_d<=0; eol_d<=0; first_d<=0; bottom_d<=0;
            if(flushing) begin
                v_d<=1;first_d<=(flush_x==0);eol_d<=(flush_x==WORDS-1);
                top_edge_d<=0;bottom_d<=1;
                if(i_valid) protocol_error_count<=protocol_error_count+1'b1;
                if(flush_x==WORDS-1) begin flushing<=0;flush_x<=0;armed<=0;end
                else flush_x<=flush_x+1'b1;
            end else if(i_valid && (armed || i_sof)) begin
                armed<=1;
                v_d<=(iy!=0); sof_d<=(iy==1 && ix==0);
                first_d<=(ix==0); eol_d<=(ix==WORDS-1);top_edge_d<=(iy==1);
                if(i_eol!=(ix==WORDS-1)) protocol_error_count<=protocol_error_count+1'b1;
                if(ix==WORDS-1) begin
                    x<=0;y<=iy+1'b1;
                    if(iy==IMAGE_HEIGHT-1) begin flushing<=1;flush_x<=0;end
                end else begin x<=ix+1'b1;y<=iy;end
            end
            v_s<=v_d;sof_s<=v_d && sof_d;eol_s<=v_d && eol_d;first_s<=first_d;
            if(v_d) for(k=0;k<4;k=k+1)
                vertical[k*10 +: 10]<=
                    {2'b0,(top_edge_d ? mid_d[k*8 +: 8] : top_d[k*8 +: 8])}+
                    ({2'b0,mid_d[k*8 +: 8]}<<1)+{2'b0,bot_d[k*8 +: 8]};
            o_valid<=0;o_sof<=0;o_eol<=0;
            // Hold one beat for its right neighbor; flush right edge next cycle.
            if(pending && (p_eol || v_s)) begin
                o_valid<=1;o_sof<=p_sof;o_eol<=p_eol;
                o_gray[7:0]<=horizontal(left,p[9:0],p[19:10]);
                o_gray[15:8]<=horizontal(p[9:0],p[19:10],p[29:20]);
                o_gray[23:16]<=horizontal(p[19:10],p[29:20],p[39:30]);
                o_gray[31:24]<=horizontal(p[29:20],p[39:30],p_eol ? p[39:30] : vertical[9:0]);
                pending<=0;
            end
            if(v_s) begin
                p<=vertical;p_sof<=sof_s;p_eol<=eol_s;pending<=1;
                left<=first_s ? vertical[9:0] : p[39:30];
            end
        end
    end
endmodule
