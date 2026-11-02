`timescale 1ns/1ps
// Sobel edge detector over a 4-pixel-per-beat gray stream. Same contract as
// gaussian_3x3_stream: two line memories, replicated borders, no backpressure.
// Gx = [-1 0 1; -2 0 2; -1 0 1], Gy = [-1 -2 -1; 0 0 0; 1 2 1], magnitude
// G = |Gx| + |Gy| (per the task spec), then thresholded: 255 where G>THRESHOLD,
// else 0. Output is a binary edge image at the same 4-pixel/beat rate.
// Center row (mid) is the frame row being filtered; borders are clamped. Output
// lags input by the same pipeline as the Gaussian/median cores so the right
// neighbor of the last pixel of each word is available when it is emitted.
// Input must leave W/4+5 idle clocks after the final beat for bottom-row drain.
// busy indicates drain; input during drain increments protocol_error_count.
module sobel_3x3_stream #(
    parameter integer IMAGE_WIDTH=1920, IMAGE_HEIGHT=1080,
    parameter [7:0] THRESHOLD=128
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
    reg [31:0] top_d,mid_d,bot_d;  // line-buffer read data: current word rows
    reg [31:0] nxt_t,nxt_m,nxt_b;  // top-edge-corrected rows (Gaussian's vertical)
    reg [31:0] p_t,p_m,p_b;        // pending word rows (Gaussian's p)
    reg [7:0]  l_t,l_m,l_b;        // left neighbor: prev word's rightmost pixel
    reg v_d,sof_d,eol_d,first_d,top_edge_d,bottom_d;
    reg v_s,sof_s,eol_s,first_s;
    reg pending,p_sof,p_eol;
    reg sum_valid,sum_sof,sum_eol;
    reg [175:0] sum_data;
    integer k;
    wire [15:0] ix=i_sof ? 16'd0 : x;
    wire [15:0] iy=i_sof ? 16'd0 : y;
    assign busy=flushing || (v_d && bottom_d) || (v_s && eol_s) || (pending && p_eol) || (sum_valid && sum_eol);

    // Sobel magnitude + threshold for a 3x3 window. tl/tc/tr is the top row,
    // ml/mc/mr the middle, bl/bc/br the bottom. The center mc carries no weight
    // in either kernel. G = |Gx|+|Gy| fits in 11 bits (max 2040).
    // Register positive/negative kernel sums before magnitude calculation.
    // Adds one clock latency, preserves four pixels/clock and exact pixels.
    function [43:0] sobel_sums;
        input [7:0] tl,tc,tr, ml,mc,mr, bl,bc,br;
        reg [10:0] px,nx,py,ny;
        begin
            px={3'b0,tr}+{2'b0,mr,1'b0}+{3'b0,br};
            nx={3'b0,tl}+{2'b0,ml,1'b0}+{3'b0,bl};
            py={3'b0,bl}+{2'b0,bc,1'b0}+{3'b0,br};
            ny={3'b0,tl}+{2'b0,tc,1'b0}+{3'b0,tr};
            sobel_sums={ny,py,nx,px};
        end
    endfunction
    function [7:0] sobel_magnitude;
        input [43:0] sums;
        reg [10:0] ax,ay,g;
        begin
            ax=sums[10:0]>=sums[21:11] ? sums[10:0]-sums[21:11]:sums[21:11]-sums[10:0];
            ay=sums[32:22]>=sums[43:33] ? sums[32:22]-sums[43:33]:sums[43:33]-sums[32:22];
            g=ax+ay;
            sobel_magnitude=g>THRESHOLD ? 8'd255:8'd0;
        end
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
            v_s<=0;sof_s<=0;eol_s<=0;first_s<=0;
            nxt_t<=0;nxt_m<=0;nxt_b<=0;p_t<=0;p_m<=0;p_b<=0;
            l_t<=0;l_m<=0;l_b<=0;pending<=0;p_sof<=0;p_eol<=0;
            o_valid<=0;o_sof<=0;o_eol<=0;o_gray<=0;protocol_error_count<=0;
            sum_valid<=0;sum_sof<=0;sum_eol<=0;sum_data<=0;
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
            // Top-edge rows (== Gaussian's vertical), one beat before p.
            if(v_d) begin
                nxt_t<=top_edge_d ? mid_d : top_d;
                nxt_m<=mid_d; nxt_b<=bot_d;
            end
            o_valid<=sum_valid;o_sof<=sum_valid && sum_sof;o_eol<=sum_valid && sum_eol;
            if(sum_valid) begin
                o_gray[7:0]<=sobel_magnitude(sum_data[43:0]);
                o_gray[15:8]<=sobel_magnitude(sum_data[87:44]);
                o_gray[23:16]<=sobel_magnitude(sum_data[131:88]);
                o_gray[31:24]<=sobel_magnitude(sum_data[175:132]);
            end
            sum_valid<=0;sum_sof<=0;sum_eol<=0;
            // Emit the pending word once the next word's first pixel (right
            // neighbor) and the line-end flag are available.
            if(pending && (p_eol || v_s)) begin
                sum_valid<=1;sum_sof<=p_sof;sum_eol<=p_eol;
                // pixel 0: left neighbor from the previous word
                sum_data[43:0]   <=sobel_sums(l_t,p_t[7:0],p_t[15:8], l_m,p_m[7:0],p_m[15:8], l_b,p_b[7:0],p_b[15:8]);
                // pixel 1
                sum_data[87:44]  <=sobel_sums(p_t[7:0],p_t[15:8],p_t[23:16], p_m[7:0],p_m[15:8],p_m[23:16], p_b[7:0],p_b[15:8],p_b[23:16]);
                // pixel 2
                sum_data[131:88] <=sobel_sums(p_t[15:8],p_t[23:16],p_t[31:24], p_m[15:8],p_m[23:16],p_m[31:24], p_b[15:8],p_b[23:16],p_b[31:24]);
                // pixel 3: right neighbor from the next word (or replicated border)
                sum_data[175:132]<=sobel_sums(p_t[23:16],p_t[31:24],(p_eol?p_t[31:24]:nxt_t[7:0]),
                                       p_m[23:16],p_m[31:24],(p_eol?p_m[31:24]:nxt_m[7:0]),
                                       p_b[23:16],p_b[31:24],(p_eol?p_b[31:24]:nxt_b[7:0]));
                pending<=0;
            end
            if(v_s) begin
                p_t<=nxt_t; p_m<=nxt_m; p_b<=nxt_b;
                l_t<=first_s ? nxt_t[7:0] : p_t[31:24];
                l_m<=first_s ? nxt_m[7:0] : p_m[31:24];
                l_b<=first_s ? nxt_b[7:0] : p_b[31:24];
                p_sof<=sof_s;p_eol<=eol_s;pending<=1;
            end
        end
    end
endmodule
