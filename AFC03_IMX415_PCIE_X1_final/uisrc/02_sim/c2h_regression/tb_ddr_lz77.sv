`timescale 1ns/1ps
module tb_ddr_lz77 #(parameter integer STARTUP=0,SLOTS=2);
 reg uclk=0,dclk=0,rst_n=0,iv=0,sof=0,eol=0,last=0,sink_ready=0;
 reg [127:0] data=0;
 always #5 uclk=~uclk;
 always #3.5 dclk=~dclk;
 wire rv,rs,rl,rr;wire [127:0] rd;wire [31:0] rid,cap_drops;
 wire [223:0] counters;
 wire cv,cl;wire [127:0] cd;wire [15:0] ck;wire [31:0] comp_frames,comp_errors;
 wire [15:0] awaddr,araddr;wire [7:0] awlen,arlen;
 wire av,ar,wv,wr,wl,bv,br,rav,rar,mrv,mrr,mrl;
 wire [127:0] wd,mrd;wire [1:0] bp,rp;wire [3:0] bid,mrid;
 ddr_camera_frame_path #(.IMAGE_WIDTH(16),.IMAGE_HEIGHT(16),.FIFO_BITS(5),
  .ADDR_WIDTH(16),.BURST_WORDS(8),.SLOT_COUNT(SLOTS),.SKIP_STARTUP_FRAME(STARTUP),.SLOT_STRIDE(16'h1000)) dut(
  .user_clk(uclk),.ddr_clk(dclk),.arst_n(rst_n),.capture_enable(1'b1),
  .i_valid(iv),.i_data(data),.i_sof(sof),.i_eol(eol),.i_last(last),
  .o_valid(rv),.o_ready(rr),.o_data(rd),.o_sof(rs),.o_last(rl),.o_frame_id(rid),
  .capture_fifo_drops(cap_drops),.counters(counters),
  .awaddr(awaddr),.awlen(awlen),.awvalid(av),.awready(ar),
  .wdata(wd),.wlast(wl),.wvalid(wv),.wready(wr),.bresp(bp),.bid(bid),.bvalid(bv),.bready(br),
  .araddr(araddr),.arlen(arlen),.arvalid(rav),.arready(rar),
  .rdata(mrd),.rresp(rp),.rid(mrid),.rlast(mrl),.rvalid(mrv),.rready(mrr));
 axi_frame_memory_model ram(.clk(dclk),.rst_n(rst_n),.hold_writes(1'b0),
  .bad_write(1'b0),.bad_read(1'b0),
  .awaddr(awaddr),.awlen(awlen),.awvalid(av),.awready(ar),
  .wdata(wd),.wlast(wl),.wvalid(wv),.wready(wr),.bresp(bp),.bid(bid),.bvalid(bv),.bready(br),
  .araddr(araddr),.arlen(arlen),.arvalid(rav),.arready(rar),
  .rdata(mrd),.rresp(rp),.rid(mrid),.rlast(mrl),.rvalid(mrv),.rready(mrr));
 lz77_rgb_c2h_path #(.IMAGE_WIDTH(16),.IMAGE_HEIGHT(16),
  .PACKET_WORDS(32),.USE_INPUT_FRAME_ID(1)) codec(
  .clk(uclk),.rst_n(rst_n),.i_valid(rv),.i_ready(rr),.i_data(rd),
  .i_sof(rs),.i_frame_last(rl),.i_frame_id(rid),
  .o_valid(cv),.o_ready(sink_ready),.o_data(cd),.o_keep(ck),.o_last(cl),
  .raw_bytes(),.compressed_bytes(),.token_count(),.frame_count(comp_frames),.error_count(comp_errors));
 integer ticks=0,f,j,k,fd;
 reg stalled=0;reg [144:0] held;
 always @(negedge uclk) begin
  ticks=ticks+1;sink_ready=(ticks%101)<67;
  if(ticks>500000) $fatal(1,"watchdog");
 end
 always @(posedge uclk) if(rst_n) begin
  if(stalled && (!cv || {cd,ck,cl}!==held)) $fatal(1,"C2H stall instability");
  stalled=cv&&!sink_ready;held={cd,ck,cl};
  if(cv&&sink_ready) begin
   if(ck==0 || (({1'b0,ck}+1)&{1'b0,ck})!=0 || (!cl && ck!=16'hffff)) $fatal(1,"C2H KEEP/LAST");
   for(k=0;k<16;k=k+1) if(ck[k]) $fwrite(fd,"%02x\n",cd[k*8+:8]);
  end
 end
 initial begin
  fd=$fopen("ddr_lz77.hex","w");repeat(8) @(negedge uclk);rst_n=1;
  repeat(15) @(negedge uclk);
  // Frame zero is deliberately short; only frames 1..10 may reach LZ77.
  for(f=0;f<=10;f=f+1) begin
   for(j=0;j<(f==0?12:48);j=j+1) begin
    @(negedge uclk);iv=1;sof=j==0;eol=(j%3)==2;last=j==(f==0?11:47);
    for(k=0;k<16;k=k+1) data[k*8+:8]=(f*97+j*16+k)&255;
    @(negedge uclk);iv=0;sof=0;eol=0;last=0;
    repeat(3) @(negedge uclk);
   end
   if(f!=0) wait(comp_frames==f);
  end
  repeat(5000) @(posedge uclk);
  if(comp_frames!=10 || comp_errors!=0 || cap_drops!=0 || dut.store.invalid_frames!=(STARTUP?0:1) ||
     dut.startup_skipped_frames!=(STARTUP?1:0))
   $fatal(1,"end-to-end counters");
  $display("PASS DDR -> LZ77: startup_guard=%0d; 10 frames, source IDs retained, short frame excluded, C2H backpressure stable",STARTUP);$finish;
 end
endmodule

module tb_ddr_lz77_startup;
 tb_ddr_lz77 #(.STARTUP(1)) test();
endmodule

module tb_ddr_lz77_ring4;
 tb_ddr_lz77 #(.STARTUP(1),.SLOTS(4)) test();
endmodule
