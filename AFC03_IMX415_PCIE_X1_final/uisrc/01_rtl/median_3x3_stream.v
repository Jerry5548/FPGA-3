`timescale 1ns/1ps
// 3x3 median filter over a 4-pixel-per-beat gray stream. Same contract as
// gaussian_3x3_stream: two line memories, replicated borders, no backpressure.
// Center row (mid) is the frame row being filtered; top/bottom are clamped at
// the frame edges. Left/right neighbors across a word boundary come from the
// previous/next word's edge pixel, clamped at the line edges. A nine-stage
// compare-exchange pipeline follows window construction; throughput stays
// four pixels/clock. Allow W/4+14 idle clocks after the final input beat to
// drain the bottom row and sorting/output pipeline.
// busy includes pending output. Input during line-memory bottom-row drain
// increments protocol_error_count; busy is status, not an input ready signal.
module median_3x3_stream #(
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
    reg [31:0] top_d,mid_d,bot_d;  // line-buffer read data: current word rows
    reg [31:0] nxt_t,nxt_m,nxt_b;  // top-edge-corrected rows (Gaussian's vertical)
    reg [31:0] p_t,p_m,p_b;        // pending word rows (Gaussian's p)
    reg [7:0]  l_t,l_m,l_b;        // left neighbor: prev word's rightmost pixel
    reg v_d,sof_d,eol_d,first_d,top_edge_d,bottom_d;
    reg v_s,sof_s,eol_s,first_s;
    reg pending,p_sof,p_eol;
    integer k;
    wire [15:0] ix=i_sof ? 16'd0 : x;
    wire [15:0] iy=i_sof ? 16'd0 : y;
    wire emit_median=pending && (p_eol || v_s);
    wire [71:0] median_in0={p_b[15:8],p_b[7:0],l_b,
                             p_m[15:8],p_m[7:0],l_m,
                             p_t[15:8],p_t[7:0],l_t};
    wire [71:0] median_in1={p_b[23:16],p_b[15:8],p_b[7:0],
                             p_m[23:16],p_m[15:8],p_m[7:0],
                             p_t[23:16],p_t[15:8],p_t[7:0]};
    wire [71:0] median_in2={p_b[31:24],p_b[23:16],p_b[15:8],
                             p_m[31:24],p_m[23:16],p_m[15:8],
                             p_t[31:24],p_t[23:16],p_t[15:8]};
    wire [71:0] median_in3={(p_eol?p_b[31:24]:nxt_b[7:0]),p_b[31:24],p_b[23:16],
                             (p_eol?p_m[31:24]:nxt_m[7:0]),p_m[31:24],p_m[23:16],
                             (p_eol?p_t[31:24]:nxt_t[7:0]),p_t[31:24],p_t[23:16]};
    wire [7:0] median_out0,median_out1,median_out2,median_out3;
    wire median_valid,median_sof,median_eol,median_pipe_busy;
    assign busy=flushing || (v_d && bottom_d) || (v_s && eol_s) ||
                (pending && p_eol) || median_pipe_busy;

    // Nine registered compare-exchange phases keep one-word-per-clock throughput.
    median9_sort_pipe median_lane0(.clk(clk),.rst_n(rst_n),.i_valid(emit_median),
        .i_sof(p_sof),.i_eol(p_eol),.i_values(median_in0),
        .o_valid(median_valid),.o_sof(median_sof),.o_eol(median_eol),
        .o_median(median_out0),.busy(median_pipe_busy));
    median9_sort_pipe median_lane1(.clk(clk),.rst_n(rst_n),.i_valid(emit_median),
        .i_sof(p_sof),.i_eol(p_eol),.i_values(median_in1),
        .o_valid(),.o_sof(),.o_eol(),.o_median(median_out1),.busy());
    median9_sort_pipe median_lane2(.clk(clk),.rst_n(rst_n),.i_valid(emit_median),
        .i_sof(p_sof),.i_eol(p_eol),.i_values(median_in2),
        .o_valid(),.o_sof(),.o_eol(),.o_median(median_out2),.busy());
    median9_sort_pipe median_lane3(.clk(clk),.rst_n(rst_n),.i_valid(emit_median),
        .i_sof(p_sof),.i_eol(p_eol),.i_values(median_in3),
        .o_valid(),.o_sof(),.o_eol(),.o_median(median_out3),.busy());

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
            o_valid<=median_valid;o_sof<=median_sof;o_eol<=median_eol;
            if(median_valid) o_gray<={median_out3,median_out2,median_out1,median_out0};
            // Emit the pending word once the next word's first pixel (right
            // neighbor) and the line-end flag are available.
            if(pending && (p_eol || v_s)) begin
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

module median9_sort_pipe(
    input wire clk,rst_n,i_valid,i_sof,i_eol,
    input wire [71:0] i_values,
    output wire o_valid,o_sof,o_eol,
    output wire [7:0] o_median,
    output wire busy
);
    wire [647:0] sorted_pipe;
    reg [8:0] valid_pipe,sof_pipe,eol_pipe;
    genvar stage;
    generate for(stage=0;stage<9;stage=stage+1) begin: SORT_STAGE
        wire [71:0] stage_in;
        if(stage==0) begin
            assign stage_in=i_values;
            always @(posedge clk or negedge rst_n) begin
                if(!rst_n) begin
                    valid_pipe[stage]<=0;sof_pipe[stage]<=0;eol_pipe[stage]<=0;
                end else begin
                    valid_pipe[stage]<=i_valid;sof_pipe[stage]<=i_sof;eol_pipe[stage]<=i_eol;
                end
            end
        end else begin
            assign stage_in=sorted_pipe[(stage-1)*72 +: 72];
            always @(posedge clk or negedge rst_n) begin
                if(!rst_n) begin
                    valid_pipe[stage]<=0;sof_pipe[stage]<=0;eol_pipe[stage]<=0;
                end else begin
                    valid_pipe[stage]<=valid_pipe[stage-1];
                    sof_pipe[stage]<=sof_pipe[stage-1];
                    eol_pipe[stage]<=eol_pipe[stage-1];
                end
            end
        end
        median9_sort_stage #(.ODD(stage%2)) u_sort(
            .clk(clk),.i_values(stage_in),.o_values(sorted_pipe[stage*72 +: 72]));
    end endgenerate
    assign o_valid=valid_pipe[8];
    assign o_sof=sof_pipe[8];
    assign o_eol=eol_pipe[8];
    assign o_median=sorted_pipe[8*72+32 +: 8];
    assign busy=|valid_pipe;
endmodule

module median9_sort_stage #(
    parameter integer ODD=0
)(
    input wire clk,
    input wire [71:0] i_values,
    output reg [71:0] o_values
);
    function [71:0] compare_exchange;
        input [71:0] values;
        reg [7:0] x0,x1,x2,x3,x4,x5,x6,x7,x8,t;
        begin
            x0=values[7:0];x1=values[15:8];x2=values[23:16];
            x3=values[31:24];x4=values[39:32];x5=values[47:40];
            x6=values[55:48];x7=values[63:56];x8=values[71:64];
            if(ODD) begin
                if(x1>x2) begin t=x1;x1=x2;x2=t;end
                if(x3>x4) begin t=x3;x3=x4;x4=t;end
                if(x5>x6) begin t=x5;x5=x6;x6=t;end
                if(x7>x8) begin t=x7;x7=x8;x8=t;end
            end else begin
                if(x0>x1) begin t=x0;x0=x1;x1=t;end
                if(x2>x3) begin t=x2;x2=x3;x3=t;end
                if(x4>x5) begin t=x4;x4=x5;x5=t;end
                if(x6>x7) begin t=x6;x6=x7;x7=t;end
            end
            compare_exchange={x8,x7,x6,x5,x4,x3,x2,x1,x0};
        end
    endfunction
    always @(posedge clk) o_values<=compare_exchange(i_values);
endmodule
