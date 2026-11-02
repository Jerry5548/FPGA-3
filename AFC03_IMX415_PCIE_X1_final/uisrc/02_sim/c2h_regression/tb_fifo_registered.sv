`timescale 1ns/1ps
module tb_fifo_registered;
 reg clk=0,rst_n=0,we=0,re=0;
 reg [129:0] wd=0;
 wire [129:0] rd;
 wire full,empty;
 always #4 clk=~clk;
 sync_fifo_130 #(.ADDR_WIDTH(3)) dut(.clk(clk),.rst_n(rst_n),
   .wr_data(wd),.wr_en(we),.full(full),.rd_data(rd),.rd_en(re),.empty(empty));
 reg [129:0] expected[0:50000];
 reg [129:0] held;
 reg hold_valid=0;
 integer pushed=0,popped=0,i,seed=3576;
 integer full_seen=0,empty_seen=0,simultaneous=0;
 always @(posedge clk) if(rst_n) begin
   if(hold_valid && (empty || rd!==held)) $fatal(1,"head changed under stall");
   hold_valid=!empty && !re; held=rd;
   if(re && !empty) begin
     if(popped>=pushed || rd!==expected[popped]) $fatal(1,"FIFO order at %0d",popped);
     popped=popped+1;
   end
   if(we && !full) begin expected[pushed]=wd;pushed=pushed+1;end
   if(full) full_seen=full_seen+1;
   if(empty) empty_seen=empty_seen+1;
   if(we && !full && re && !empty) simultaneous=simultaneous+1;
 end
 initial begin
   repeat(4) @(negedge clk);rst_n=1;
   for(i=0;i<20000;i=i+1) begin
     @(negedge clk);
     if(i<40) begin we=1;re=0;end
     else if(i<80) begin we=0;re=1;end
     else begin we=($random(seed)&3)!=0;re=($random(seed)&3)!=0;end
     wd={2'b10,$random(seed),$random(seed),$random(seed),$random(seed)};
   end
   @(negedge clk);we=0;re=1;
   repeat(20) @(negedge clk);
   if(pushed!=popped || !full_seen || !empty_seen || !simultaneous)
      $fatal(1,"coverage or missing items %0d/%0d",pushed,popped);
   // Reset while stalled with queued data, then check a fresh stream.
   we=1;re=0;repeat(6) @(negedge clk);
   rst_n=0;we=0;hold_valid=0;pushed=0;popped=0;
   repeat(3) @(negedge clk);rst_n=1;
   repeat(20) begin @(negedge clk);we=1;re=1;wd=wd+1;end
   @(negedge clk);we=0;re=1;repeat(15) @(negedge clk);
   if(pushed!=popped) $fatal(1,"reset/drain");
   $display("PASS registered FIFO: order, stalls, full/empty, simultaneous IO, wrap and reset");$finish;
 end
endmodule
