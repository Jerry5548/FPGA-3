`timescale 1ns/1ps
// The controller is an interface-only stub: this checks wrapper status/reset
// sequencing with independent clocks, not DDR calibration or metastability.
module tb_ddr_status;
    reg ref_clk=0,user_clk=0,ddr_clk=0,reset_n=0;
    reg cal=0,locked=0,phy=0;
    reg [7:0] err=0,step=0;
    wire [31:0] status;
    wire ready;
    reg [31:0] sample1=0,sample2=0;
    integer checked=0,round;
    always #5 ref_clk=~ref_clk;
    always #4 user_clk=~user_clk;
    always #3.75 ddr_clk=~ddr_clk;
    pcie_ddr_camera dut(.ref_clk(ref_clk),.user_clk(user_clk),.reset_n(reset_n),
        .enable(1'b0),.i_valid(1'b0),.i_data(128'd0),.i_sof(1'b0),
        .i_eol(1'b0),.i_last(1'b0),.o_ready(1'b0),.ready(ready),.ddr_status(status));

    always @(posedge user_clk or negedge reset_n) begin
        if(!reset_n) begin sample1<=0;sample2<=0;end
        else begin
            sample1<={err,step,12'd0,dut.controller_rst_n,phy,locked,cal};
            sample2<=sample1;
        end
        #0.01;
        if(status!==sample2) $fatal(1,"status not synchronized: got=%h expected=%h",status,sample2);
        if(ready!==(sample2[0] && sample2[1] && sample2[2])) $fatal(1,"ready mismatch");
        checked=checked+1;
    end
    initial begin
        force dut.ddr_clk=ddr_clk;
        force dut.cal_done=cal;
        force dut.pll_locked=locked;
        force dut.phy_rst_n=phy;
        force dut.cal_error=err;
        force dut.cal_step=step;
        // Force a reset edge even on simulators that initialize regs at t=0.
        #1 reset_n=1; #1 reset_n=0;
        for(round=0;round<3;round=round+1) begin
            #11.3 reset_n=1;
            repeat(254) @(posedge ref_clk);
            #0.1;
            if(dut.controller_rst_n!==0) $fatal(1,"controller reset released early");
            repeat(8) @(posedge ref_clk);
            #0.1;
            if(status[3]!==1) $fatal(1,"controller reset status did not release");
            #1.7 locked=1;phy=1;step=8'h20;
            #23.1 cal=1;err=8'h81;
            repeat(8) @(posedge user_clk);
            #0.1;
            if(status!==32'h8120000f || ready!==1) $fatal(1,"stable status mismatch");
            #1.3 reset_n=0;cal=0;locked=0;phy=0;err=0;step=0;
            #0.1;
            if(status!==0 || ready!==0) $fatal(1,"reset did not clear status");
        end
        $display("PASS DDR status: independent clocks, 3 restarts, %0d samples, two-cycle status and reset",checked);
        $finish;
    end
    initial begin #20000; $fatal(1,"timeout");end
endmodule
