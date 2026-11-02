`timescale 1ns/1ps
// 128-bit RGBX/packed video beat to low-byte-first stream. The PCIe camera
// source already runs in user_clk and supplies SOF/frame-last.
module rgb128_byte_stream #(
    parameter integer IMAGE_WIDTH=1920,
    parameter integer IMAGE_HEIGHT=1080
)(
    input wire clk,rst_n,input wire i_valid,output wire i_ready,
    input wire [127:0] i_data,input wire i_sof,input wire i_frame_last,
    input wire [31:0] i_frame_id,output wire [31:0] o_frame_id,
    output reg o_valid,input wire o_ready,output reg [7:0] o_data,
    output reg o_sof,o_last,output reg [31:0] error_count
);
    localparam integer TOTAL_BEATS=(IMAGE_WIDTH*IMAGE_HEIGHT*3)/16;
    // Hold the last byte until a following SOF is known. An early SOF
    // closes the shortened old frame rather than appending another image.
    reg active,in_frame;
    reg [127:0] data_q,peek_data;
    reg [3:0] index;
    reg sof_q,last_q,peek_valid,peek_sof,peek_last;
    reg [31:0] frame_id_q,peek_id;
    reg [31:0] beat_count;
    assign i_ready=!peek_valid;
    assign o_frame_id=frame_id_q;
    always @(*) begin
        o_valid=active && (index!=15 || last_q || peek_valid);
        o_data=data_q[index*8 +: 8];
        o_sof=o_valid && sof_q && (index==0);
        o_last=o_valid && (index==15) &&
               (last_q || (peek_valid && peek_sof));
    end
    task load_beat;
        input [127:0] d;
        input s,l;
        input [31:0] id;
        reg [31:0] count;
        begin
            if(s || in_frame) begin
                count=s ? 32'd1 : beat_count+1'b1;
                active<=1;data_q<=d;index<=0;sof_q<=s;
                if(s) frame_id_q<=id;
                in_frame<=1;beat_count<=count;
                last_q<=l || (count>=TOTAL_BEATS);
                if((l && count!=TOTAL_BEATS) || (!l && count>=TOTAL_BEATS))
                    error_count<=error_count+1'b1;
            end else begin
                // Never manufacture a new header from an orphan tail.
                active<=0;error_count<=error_count+1'b1;
            end
        end
    endtask
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            active<=0;in_frame<=0;data_q<=0;index<=0;sof_q<=0;last_q<=0;
            peek_data<=0;peek_valid<=0;peek_sof<=0;peek_last<=0;
            beat_count<=0;error_count<=0;
            frame_id_q<=0;peek_id<=0;
        end else begin
            if(o_valid && o_ready) begin
                if(index==15) begin
                    active<=0;index<=0;
                    if(o_last) begin
                        in_frame<=0;beat_count<=0;
                        if(!last_q) error_count<=error_count+1'b1;
                    end
                end else index<=index+1'b1;
            end
            // A separate promotion cycle observes the preceding frame end.
            if(!active && peek_valid) begin
                load_beat(peek_data,peek_sof,peek_last,peek_id);
                peek_valid<=0;
            end
            if(i_valid && i_ready) begin
                if(!active) load_beat(i_data,i_sof,i_frame_last,i_frame_id);
                else begin
                    peek_valid<=1;peek_data<=i_data;
                    peek_sof<=i_sof;peek_last<=i_frame_last;
                    peek_id<=i_frame_id;
                end
            end
        end
    end
endmodule
