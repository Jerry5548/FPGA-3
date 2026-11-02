`timescale 1ns/1ps
module tb_packer_16k;
    localparam integer PACKET_BEATS=1024;
    reg clk=0,rst_n=0,i_valid=0,i_last=0,o_ready=1;
    reg [31:0] i_data=0;
    reg [2:0] i_keep=4;
    wire i_ready,o_valid,o_last;
    wire [127:0] o_data;
    wire [15:0] o_keep;
    integer output_beats=0,packets=0,index;

    always #4 clk=~clk;
    initial begin #1000000; $fatal(1,"16 KiB packetizer watchdog"); end
    lz77_c2h_word_packer #(.PACKET_BEATS(PACKET_BEATS)) dut(
        .clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_ready(i_ready),
        .i_data(i_data),.i_keep(i_keep),.i_last(i_last),
        .o_valid(o_valid),.o_ready(o_ready),.o_data(o_data),
        .o_keep(o_keep),.o_last(o_last));

    always @(posedge clk) if(rst_n && o_valid && o_ready) begin
        if(o_keep!=16'hffff && !o_last)
            $fatal(1,"partial non-final packet beat keep=%h",o_keep);
        output_beats=output_beats+1;
        if(o_last) begin
            packets=packets+1;
            if(packets==1 && output_beats!=PACKET_BEATS)
                $fatal(1,"first EOP at beat %0d, expected %0d",output_beats,PACKET_BEATS);
            if(packets==2 && (output_beats!=PACKET_BEATS+1 || o_keep!=16'h000f))
                $fatal(1,"final partial packet boundary beats=%0d keep=%h",output_beats,o_keep);
        end
    end

    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        for(index=0;index<PACKET_BEATS*4;index=index+1) begin
            @(negedge clk);
            while(!i_ready) @(negedge clk);
            i_valid=1;i_last=0;i_keep=4;i_data=index;
            @(posedge clk);
        end
        @(negedge clk);i_valid=0;
        wait(packets==1);
        @(negedge clk);
        while(!i_ready) @(negedge clk);
        i_valid=1;i_last=1;i_keep=4;i_data=32'hfeedface;
        @(posedge clk);
        @(negedge clk);i_valid=0;i_last=0;
        wait(packets==2);
        if(output_beats!=PACKET_BEATS+1)
            $fatal(1,"unexpected output beat count %0d",output_beats);
        $display("# PASS 16 KiB packetizer: EOP every %0d C2H beats; final short packet preserved",PACKET_BEATS);
        $finish;
    end
endmodule
