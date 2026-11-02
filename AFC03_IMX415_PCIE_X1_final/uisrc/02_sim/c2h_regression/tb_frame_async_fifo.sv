`timescale 1ns/1ps
module tb_frame_async_fifo;
 parameter integer AW=4,N=6000;
 localparam DEPTH=(1<<AW);
 reg wclk=0,rclk=0,wrst_n=0,rrst_n=0,wvalid=0,rready=0;
 reg [31:0] wdata=0;
 wire wready,rvalid;
 wire [31:0] rdata;
 always #5 wclk=~wclk;
 always #7 rclk=~rclk;
 frame_async_fifo #(.WIDTH(32),.ADDR_BITS(AW)) dut(
  .wclk(wclk),.wrst_n(wrst_n),.wvalid(wvalid),.wready(wready),.wdata(wdata),
  .rclk(rclk),.rrst_n(rrst_n),.rvalid(rvalid),.rready(rready),.rdata(rdata));
 reg [31:0] expected[0:2*N-1];
 reg [31:0] held;
 reg stalled=0;
 integer pushed=0,popped=0,cycles=0,seed=3576,full_seen=0,empty_seen=0;
 integer phase=0,target=N;
 always @(negedge wclk) begin
  if(!wrst_n) begin wvalid=0;end
  else begin
   wvalid=(pushed<target) && (($random(seed)&7)!=0);
   wdata=32'h91ab57d3 ^ (pushed*32'h10101) ^ pushed;
  end
 end
 always @(posedge wclk) if(wrst_n) begin
  if(wready && wvalid) begin expected[pushed]=wdata;pushed=pushed+1;end
  if(!wready) full_seen=full_seen+1;
 end
 always @(negedge rclk) begin
  if(!rrst_n) rready=0;
  else rready=(cycles>DEPTH*2+50) && (($random(seed)&7)!=0);
 end
 always @(posedge rclk) if(rrst_n) begin
  cycles=cycles+1;
  if(stalled && (!rvalid || rdata!==held)) $fatal(1,"held head changed");
  held=rdata;stalled=rvalid&&!rready;
  if(cycles>200000) $fatal(1,"async fifo watchdog pushed=%0d popped=%0d",pushed,popped);
  if(rvalid && rready) begin
   if(popped>=pushed || rdata!==expected[popped])
    $fatal(1,"async fifo order at %0d got=%h expected=%h pushed=%0d",popped,rdata,expected[popped],pushed);
   popped=popped+1;
  end
  if(!rvalid) empty_seen=empty_seen+1;
 end
 initial begin
  repeat(5) @(negedge wclk);wrst_n=1;rrst_n=1;
  wait(popped==N);
  repeat(8) @(negedge rclk);
  if(pushed!=N || popped!=N || empty_seen==0 || full_seen==0)
   $fatal(1,"async fifo counters p=%0d r=%0d empty=%0d",pushed,popped,empty_seen);
  // Reset with a queued head held by downstream backpressure, then require
  // only newly written bytes. Both reset inputs are asserted together.
  target=2*N;rready=0;
  force rready=0;
  repeat(24) @(negedge wclk);
  wrst_n=0;rrst_n=0;stalled=0;
  repeat(5) @(negedge wclk);
  pushed=0;popped=0;cycles=0;target=N;release rready;
  wrst_n=1;rrst_n=1;
  wait(popped==N);repeat(8) @(negedge rclk);
  $display("PASS async FIFO optimized Gray pointer: width=%0d, two x %0d items, full/empty, wrap, independent clocks, stalls and queued reset",AW,N);
  $finish;
 end
 always @(negedge wclk) if(wrst_n)
  if(dut.wgray !== ((dut.wbin>>1)^dut.wbin)) $fatal(1,"write Gray mismatch");
 always @(negedge rclk) if(rrst_n)
  if(dut.rgray !== ((dut.rbin>>1)^dut.rbin)) $fatal(1,"read Gray mismatch");
endmodule
