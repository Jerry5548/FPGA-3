`timescale 1ns/1ps
// Incompressible bytes exercise the slowest path: every input byte becomes
// a literal token. The encoder must sustain one accepted byte per user clock
// after pipeline fill, while retaining exact counters and a clean frame end.
module tb_encoder_throughput;
    localparam integer N=10000;
    reg clk=0,rst_n=0,i_valid=0,i_sof=0,i_last=0,o_ready=1;
    reg [7:0] i_data=0;
    wire i_ready,o_valid,o_sof,o_last,o_match;
    wire [15:0] o_token;
    wire [1:0] o_bytes;
    wire [31:0] raw,comp,tokens,frames,errors;
    integer accepted,emitted,ticks,start_tick,end_tick;

    always #4 clk=~clk;
    lz77_repeat_encoder dut(
        .clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_ready(i_ready),
        .i_data(i_data),.i_sof(i_sof),.i_last(i_last),
        .o_valid(o_valid),.o_ready(o_ready),.o_token(o_token),
        .o_match(o_match),.o_sof(o_sof),.o_last(o_last),.o_bytes(o_bytes),
        .raw_byte_count(raw),.compressed_byte_count(comp),
        .token_count(tokens),.frame_count(frames),.error_count(errors));

    initial begin
        accepted=0;emitted=0;ticks=0;start_tick=-1;end_tick=-1;
        repeat(4) @(negedge clk);
        rst_n=1;
        while(accepted<N || emitted<N) begin
            @(negedge clk);
            ticks=ticks+1;
            if(accepted<N) begin
                i_valid=1;
                i_sof=(accepted==0);
                i_last=(accepted==N-1);
                // Consecutive values never repeat, so all tokens are literals.
                i_data=accepted%251;
            end else begin
                i_valid=0;i_sof=0;i_last=0;
            end
            @(posedge clk);
            if(i_valid && i_ready) begin
                if(accepted==0) start_tick=ticks;
                accepted=accepted+1;
            end
            if(o_valid && o_ready) begin
                if(o_bytes!=1 || o_match) $fatal(1,"unexpected match in literal-only stream");
                emitted=emitted+1;
                if(o_last) end_tick=ticks;
            end
            if(ticks>N+32) $fatal(1,"throughput timeout accepted=%0d emitted=%0d",accepted,emitted);
        end
        repeat(2) @(posedge clk);
        if(raw!=N || tokens!=N || frames!=1 || errors!=0 || end_tick<start_tick)
            $fatal(1,"encoder counters raw=%0d tokens=%0d frames=%0d errors=%0d",raw,tokens,frames,errors);
        if(end_tick-start_tick+1>N+8)
            $fatal(1,"literal throughput regressed: %0d cycles for %0d bytes",end_tick-start_tick+1,N);
        $display("# PASS encoder throughput: %0d literal bytes in %0d cycles, no bubbles, frame/counters valid",N,end_tick-start_tick+1);
        $finish;
    end
endmodule
