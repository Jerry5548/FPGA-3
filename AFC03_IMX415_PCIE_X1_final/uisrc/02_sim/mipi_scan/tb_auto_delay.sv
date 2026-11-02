`timescale 1ns/1ps
module scan_case #(parameter integer TAPS=32)(output reg finished=0);
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg [63:0] good=0;
    integer pattern=0;
    wire [5:0] tap;
    wire load,done;
    wire [5:0] best;
    wire [3:0] aligned=(good[tap] && (pattern!=1 || dut.cnt[0])) ? 4'hf : 4'h0;
    auto_delay_ctl #(.DELAY_TAPS(TAPS),.TEST_CYCLES(16),
        .PASS_CYCLES(4),.SETTLE_CYCLES(2),.WAIT_DATA_CYCLES(8)) dut(
        .I_byte_clk(clk),.I_reset_n(rst_n),.I_byte_align_done(aligned),
        .O_delay_value(tap),.O_delay_vaild(load),
        .O_auto_delay_done(done),.O_dbg_best_len(best));
    reg [63:0] visited;
    integer scan_loads;
    always @(negedge clk) if(rst_n && load && dut.state==3) begin
        if(tap>=TAPS) $fatal(1,"Out-of-range tap: %0d/%0d",tap,TAPS);
        if(visited[tap]) $fatal(1,"Duplicate physical scan tap %0d",tap);
        visited[tap]=1;
        scan_loads=scan_loads+1;
    end
    task check(input [63:0] mask,input integer expected_len,
               input integer expected_tap,input integer sparse);
        integer cycles,reported;
        begin
            @(negedge clk); rst_n=0;good=mask;pattern=sparse;
            visited=0;scan_loads=0;
            repeat(3) @(negedge clk);
            rst_n=1;cycles=0;
            while(!done && cycles<5000) begin @(negedge clk);cycles=cycles+1;end
            if(!done) $fatal(1,"Scan did not complete");
            reported=expected_len>63 ? 63 : expected_len;
            if(best!==reported || tap!==expected_tap || dut.best_len!==expected_len)
                $fatal(1,"TAPS=%0d len=%0d/%0d tap=%0d/%0d debug=%0d/%0d",TAPS,
                    dut.best_len,expected_len,tap,expected_tap,best,reported);
            if(scan_loads!=TAPS) $fatal(1,"Incorrect number of scan loads: %0d",scan_loads);
            repeat(10) begin
                @(negedge clk);
                if(!done || load || tap!==expected_tap) $fatal(1,"Unstable final selection");
            end
        end
    endtask
    initial begin
        check(0,0,TAPS/2,0);                // no eye: explicit midpoint fallback
        check(64'hff0,8,8,0);               // taps 4..11: exact center
        check(64'hff0,8,8,1);               // aligned bursts with gaps
        check(64'h3f0000f,6,23,0);          // select longer of disjoint eyes
        check(64'b1<<(TAPS-1),1,TAPS-1,0); // highest legal tap
        if(TAPS==32) check(64'hffffffff,32,16,0);
        else begin
            check(64'hffffffffffffffff,64,32,0); // old six-bit length overflow
            check(64'h3ffffffffffff,50,25,0);
        end
        $display("PASS scan TAPS=%0d: absent/burst/multiple/edge/full eyes, exact centers and unique physical taps",TAPS);
        finished=1;
    end
endmodule
module tb_auto_delay;
    wire a,b;
    scan_case #(.TAPS(32)) ph1a(a);
    scan_case #(.TAPS(64)) ph2(b);
    initial begin wait(a&&b);$display("PASS all MIPI scan tests");$finish;end
    initial begin #2000000; $fatal(1,"Watchdog");end
endmodule
