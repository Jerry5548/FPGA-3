`timescale 1ns/1ps
// H2V1: one 16-byte little-endian header then W*H*4 BGRX bytes.
// Header: magic "H2V1", uint16 width,height, uint32 frame_id,payload_bytes.
// H2C TLAST marks DMA writes, NOT frames; framing is length-driven.
// Invalid headers/keep/sequence fail closed until a video soft reset.
module h2c_video_source #(
    parameter integer IMAGE_WIDTH=1920, IMAGE_HEIGHT=1080,
    parameter integer FRAME_GAP=4096
)(
    input wire clk,rst_n,enable,
    input wire [127:0] s_data,
    input wire [15:0] s_keep,
    input wire s_valid,
    output wire s_ready,
    output wire [127:0] o_rgb,
    output wire o_valid,o_sof,o_eol,
    input wire o_ready,
    // Last packed RGB24 beat accepted by the encoder.
    input wire frame_consumed,
    output reg [31:0] frame_id,frame_count,error_count,
    output wire [31:0] status
);
    localparam integer LINE_WORDS=IMAGE_WIDTH/4;
    localparam integer FRAME_WORDS=LINE_WORDS*IMAGE_HEIGHT;
    localparam integer FRAME_BYTES=IMAGE_WIDTH*IMAGE_HEIGHT*4;
    localparam [2:0] HEADER=0,PIXELS=1,DRAIN=2,GAP=3,FAULT=4;
    reg [2:0] state;
    reg [31:0] word_index,expected_id,gap_count;
    reg [15:0] column;
    wire keep_ok=&s_keep;
    wire header_ok=s_data[31:0]==32'h31563248 &&
        s_data[47:32]==IMAGE_WIDTH && s_data[63:48]==IMAGE_HEIGHT &&
        s_data[95:64]==expected_id && s_data[127:96]==FRAME_BYTES;
    assign s_ready=enable && (state==HEADER || (state==PIXELS && o_ready));
    assign o_rgb=s_data;
    assign o_valid=enable && state==PIXELS && s_valid && keep_ok;
    assign o_sof=o_valid && word_index==0;
    assign o_eol=o_valid && column==LINE_WORDS-1;
    assign status={24'd0,state,1'b0,(state==FAULT),(state!=HEADER),s_ready,enable};
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=HEADER;word_index<=0;column<=0;expected_id<=1;gap_count<=0;
            frame_id<=0;frame_count<=0;error_count<=0;
        end else if(enable) begin
            if(s_valid && s_ready) begin
                if(!keep_ok || (state==HEADER && !header_ok)) begin
                    state<=FAULT;error_count<=error_count+1'b1;
                end else if(state==HEADER) begin
                    state<=PIXELS;word_index<=0;column<=0;
                    frame_id<=s_data[95:64];
                end else if(state==PIXELS) begin
                    word_index<=word_index+1'b1;
                    if(column==LINE_WORDS-1) column<=0;
                    else column<=column+1'b1;
                    if(word_index==FRAME_WORDS-1) state<=DRAIN;
                end
            end
            if(state==DRAIN && frame_consumed) begin
                state<=GAP;gap_count<=0;
                frame_count<=frame_count+1'b1;expected_id<=expected_id+1'b1;
            end
            // Includes the bottom-row drain and histogram LUT scan budget.
            if(state==GAP) begin
                if(gap_count==FRAME_GAP-1) state<=HEADER;
                else gap_count<=gap_count+1'b1;
            end
        end
    end
endmodule
