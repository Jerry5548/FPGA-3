`timescale 1ns/1ps
// Regression for repeated SOFs after the camera FIFO drops frame contents.
// SOF from the next sensor frame arrives before TOTAL_BEATS have survived.
module tb_rgb_repeated_sof;
    reg clk=0, rst_n=0, iv=0, sof=0, last=0;
    always #4 clk=~clk;
    wire ir, ov, os, ol;
    wire [7:0] od;
    wire [31:0] errors;
    integer frame, beat, bytes_seen=0, ends_seen=0, cycles=0;
    rgb128_byte_stream #(.IMAGE_WIDTH(16),.IMAGE_HEIGHT(16)) dut(
        .clk(clk),.rst_n(rst_n),.i_valid(iv),.i_ready(ir),
        .i_data({16{8'h55}}),.i_sof(sof),.i_frame_last(last),
        .o_valid(ov),.o_ready(1'b1),.o_data(od),.o_sof(os),
        .o_last(ol),.error_count(errors));
    always @(posedge clk) begin
        cycles=cycles+1;
        if(cycles>10000) $fatal(1,"watchdog");
        if(rst_n && ov) begin
            bytes_seen=bytes_seen+1;
            if(ol) ends_seen=ends_seen+1;
        end
    end
    initial begin
        repeat(5) @(negedge clk);
        rst_n=1;
        // 4 shortened source frames: 192 bytes each instead of 768.
        // The old counter never generated LAST. Now each later SOF closes
        // the preceding shortened image and reports a frame error.
        for(frame=0; frame<4; frame=frame+1) begin
            for(beat=0; beat<12; beat=beat+1) begin
                @(negedge clk); iv=1; sof=(beat==0);
                @(posedge clk); while(!ir) @(posedge clk);
            end
        end
        // A good frame closes the fourth short image and then itself.
        for(beat=0;beat<48;beat=beat+1) begin
            @(negedge clk);iv=1;sof=(beat==0);last=(beat==47);
            @(posedge clk);while(!ir) @(posedge clk);
        end
        @(negedge clk); iv=0; sof=0;last=0;
        repeat(40) @(posedge clk);
        if(bytes_seen!=1536 || ends_seen!=5 || errors!=4)
            $fatal(1,"unexpected reproduction: bytes=%0d ends=%0d errors=%0d",
                   bytes_seen,ends_seen,errors);
        $display("PASS repeated SOF recovery: bytes=%0d LAST=%0d errors=%0d",
                 bytes_seen,ends_seen,errors);
        $finish;
    end
endmodule
