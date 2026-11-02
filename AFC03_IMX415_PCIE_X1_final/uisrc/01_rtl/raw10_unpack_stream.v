`timescale 1ns/1ps
// Consume 0..4 bytes/cycle, emit four RAW10 pixels/cycle (pixel0 at [9:0]).
// Explicit packet boundaries, never infer a line from blanking time.
module raw10_unpack_stream(
    input wire clk, rst_n,
    input wire frame_start, frame_end, abort_packet,
    input wire line_start, line_end, payload_valid,
    input wire [2:0] payload_bytes,
    input wire [31:0] payload_data,
    output reg raw_frame_start, raw_frame_end,
    output reg raw_valid, raw_line_start, raw_line_end,
    output reg [39:0] raw_data,
    output reg [31:0] format_error_count
);
    reg [63:0] buffer;
    reg [3:0] count;
    reg first_group;
    reg [63:0] buf_next;
    reg [3:0] count_next;
    integer j;
    always @* begin
        buf_next=line_start ? 64'd0 : buffer;
        count_next=line_start ? 4'd0 : count;
        for(j=0;j<4;j=j+1)
            if(j<payload_bytes) begin
                buf_next[count_next*8 +: 8]=payload_data[31-j*8 -: 8];
                count_next=count_next+1'b1;
            end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            buffer<=0; count<=0; first_group<=1;
            raw_frame_start<=0; raw_frame_end<=0; raw_valid<=0;
            raw_line_start<=0; raw_line_end<=0; raw_data<=0; format_error_count<=0;
        end else begin
            raw_frame_start<=frame_start; raw_frame_end<=frame_end;
            raw_valid<=0; raw_line_start<=0; raw_line_end<=0;
            if(frame_start || frame_end || abort_packet) begin
                count<=0; buffer<=0; first_group<=1;
            end else if(payload_valid) begin
                if(count_next>=5) begin
                    raw_data<={buf_next[31:24],buf_next[39:38],
                               buf_next[23:16],buf_next[37:36],
                               buf_next[15:8],buf_next[35:34],
                               buf_next[7:0],buf_next[33:32]};
                    raw_valid<=1; raw_line_start<=line_start || first_group;
                    raw_line_end<=line_end;
                    buffer<=buf_next>>40; count<=count_next-5;
                    first_group<=0;
                end else begin
                    buffer<=buf_next; count<=count_next;
                    if(line_start) first_group<=1;
                end
                if(line_end) begin
                    count<=0; buffer<=0; first_group<=1;
                    if(count_next!=5) format_error_count<=format_error_count+1'b1;
                end
            end
        end
    end
endmodule
