`timescale 1ns/1ps
module tb_edge_ddr_lz77 #(parameter integer MODE=5,BLK1=0);
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
 wire qv,qs,qe;wire [127:0] qd;wire [31:0] me,se;
 wire pv,ps,pe,pl;wire [127:0] pd;
 ddr_camera_frame_path #(.IMAGE_WIDTH(16),.IMAGE_HEIGHT(16),.FIFO_BITS(5),
  .ADDR_WIDTH(16),.BURST_WORDS(8),.SLOT_COUNT(4),.SKIP_STARTUP_FRAME(1),.SLOT_STRIDE(16'h1000)) dut(
  .user_clk(uclk),.ddr_clk(dclk),.arst_n(rst_n),.capture_enable(1'b1),
  .i_valid(pv),.i_data(pd),.i_sof(ps),.i_eol(pe),.i_last(pl),
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
  .PACKET_WORDS(32),.USE_INPUT_FRAME_ID(1),.BLK1_ENABLE(BLK1),.BLK1_BLOCK_BYTES(256)) codec(
  .clk(uclk),.rst_n(rst_n),.i_valid(rv),.i_ready(rr),.i_data(rd),
  .i_sof(rs),.i_frame_last(rl),.i_frame_id(rid),
  .o_valid(cv),.o_ready(sink_ready),.o_data(cd),.o_keep(ck),.o_last(cl),
  .raw_bytes(),.compressed_bytes(),.token_count(),.frame_count(comp_frames),.error_count(comp_errors));

 image_preprocess_quad #(.IMAGE_WIDTH(16),.IMAGE_HEIGHT(16),.MODE(4),.RUNTIME_MODE(1)) pre(
  .clk(uclk),.rst_n(rst_n),.i_valid(iv),.i_sof(sof),.i_eol(eol),.i_rgb(data),
  .i_mode(3'(MODE)),.active_mode(),.o_valid(qv),.o_sof(qs),.o_eol(qe),.o_rgb(qd),
  .gaussian_errors(),.histogram_errors(),.median_errors(me),.sobel_errors(se));
 pack4_rgb24_to_128 #(.IMAGE_HEIGHT(16)) pack(
  .clk(uclk),.rst_n(rst_n),.enable(1'b1),.s_tdata(qd),.s_tvalid(qv),.s_tready(),
  .s_tlast(qe),.s_tuser(qs),.m_tdata(pd),.m_tvalid(pv),.m_tready(1'b1),
  .m_tlast(pe),.m_frame_last(pl),.sof(ps),.eof(),.frame_count_out());
 reg [127:0] src[0:319];
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
  fd=$fopen(BLK1 ? (MODE==5?"edge5_blk1.hex":"edge6_blk1.hex") :
                  (MODE==5?"edge5.hex":"edge6.hex"),"w");
  $readmemh("vectors_16x16/rgb.hex",src);
  repeat(8) @(negedge uclk);rst_n=1;
  repeat(270) @(negedge uclk);
  for(f=0;f<5;f=f+1) begin
   for(j=0;j<64;j=j+1) begin
    @(negedge uclk);iv=1;sof=j==0;eol=(j%4)==3;data=src[f*64+j];
   end
   @(negedge uclk);iv=0;sof=0;eol=0;
   repeat(350) @(negedge uclk);
   if(f>0) wait(comp_frames==f);
  end
  repeat(1000) @(posedge uclk);
  if(comp_frames!=4 || comp_errors!=0 || cap_drops!=0 || dut.store.invalid_frames!=0 ||
     dut.startup_skipped_frames!=1 || me!=0 || se!=0) $fatal(1,"end-to-end integrity");
  $display("PASS mode %0d preprocessing -> RGB24 pack -> DDR -> LZ77: 4 frames after startup guard, zero integrity errors",MODE);
  $finish;
 end
endmodule
