`timescale 1ns/1ps
module tb_ddr_frame_path #(parameter integer STARTUP=0,DIAG=0,SLOTS=2);
 reg uclk=0,dclk=0,rst_n=0,en=1,iv=0,sof=0,eol=0,last=0,ready=0;
 reg [127:0] data=0;
 always #5 uclk=~uclk;
 always #3.5 dclk=~dclk;
 wire ov,os,ol;wire [127:0] od;wire [31:0] id,cap_drops;wire [223:0] counters;
 wire [15:0] awaddr,araddr;wire [7:0] awlen,arlen;
 wire awv,awr,wv,wr,wl,bv,br,arv,arr,rv,rr,rl;
 wire [127:0] wd,rd;wire [1:0] bp,rp;wire [3:0] bid,rid;
 reg hold_writes=0,bad_write=0,bad_read=0,stall_sink=0;
 ddr_camera_frame_path #(.IMAGE_WIDTH(16),.IMAGE_HEIGHT(16),.FIFO_BITS(5),
   .ADDR_WIDTH(16),.BURST_WORDS(8),.SKIP_STARTUP_FRAME(STARTUP),.SLOT_COUNT(SLOTS),.SLOT_STRIDE(16'h1000)) dut(
  .user_clk(uclk),.ddr_clk(dclk),.arst_n(rst_n),.capture_enable(en),
  .i_valid(iv),.i_data(data),.i_sof(sof),.i_eol(eol),.i_last(last),
  .o_valid(ov),.o_ready(ready),.o_data(od),.o_sof(os),.o_last(ol),.o_frame_id(id),
  .capture_fifo_drops(cap_drops),.counters(counters),
  .awaddr(awaddr),.awlen(awlen),.awvalid(awv),.awready(awr),
  .wdata(wd),.wlast(wl),.wvalid(wv),.wready(wr),.bresp(bp),.bid(bid),.bvalid(bv),.bready(br),
  .araddr(araddr),.arlen(arlen),.arvalid(arv),.arready(arr),
  .rdata(rd),.rresp(rp),.rid(rid),.rlast(rl),.rvalid(rv),.rready(rr));
 axi_frame_memory_model ram(.clk(dclk),.rst_n(rst_n),.hold_writes(hold_writes),
  .bad_write(bad_write),.bad_read(bad_read),
  .awaddr(awaddr),.awlen(awlen),.awvalid(awv),.awready(awr),
  .wdata(wd),.wlast(wl),.wvalid(wv),.wready(wr),.bresp(bp),.bid(bid),.bvalid(bv),.bready(br),
  .araddr(araddr),.arlen(arlen),.arvalid(arv),.arready(arr),
  .rdata(rd),.rresp(rp),.rid(rid),.rlast(rl),.rvalid(rv),.rready(rr));
 integer tick=0,words=0,completed=0,f,k;
 reg [31:0] current_id;
 reg [31:0] last_completed_id;
 reg stalled=0;reg [161:0] held;
 function [127:0] pattern(input integer frame,input integer beat);
  integer n;
  begin for(n=0;n<16;n=n+1) pattern[n*8+:8]=(frame*97+beat*16+n)&255;end
 endfunction
 always @(negedge uclk) begin
  tick=tick+1;ready=rst_n && !stall_sink && (tick%31)<21;
  if(tick>500000) $fatal(1,"watchdog");
 end
 always @(posedge uclk) if(rst_n) begin
  if(stalled && (!ov || {id,os,ol,od}!==held)) $fatal(1,"replay changed under stall");
  stalled=ov&&!ready;held={id,os,ol,od};
  if(ov&&ready) begin
   if(os) begin
    if(words!=0) $fatal(1,"new frame before prior LAST");
    if(completed>0 && id<=last_completed_id) $fatal(1,"published frame queue reordered");
    current_id=id;
   end
   if(os !== (words==0) || id!==current_id || od!==pattern(id,words))
    $fatal(1,"word/identity mismatch id=%0d word=%0d",id,words);
   if(ol !== (words==47)) $fatal(1,"wrong frame LAST");
   if(ol) begin words=0;completed=completed+1;last_completed_id=id;end
   else words=words+1;
  end
 end
 task reset_case;
  begin
   @(negedge uclk);rst_n=0;en=1;iv=0;sof=0;last=0;eol=0;
   completed=0;words=0;stalled=0;hold_writes=0;bad_write=0;bad_read=0;stall_sink=0;
   repeat(8) @(negedge uclk);rst_n=1;
   repeat(12) @(negedge uclk);
  end
 endtask
 task send_frame(input integer frame,input integer count,input integer kind,input integer gap);
  integer j;
  begin
   for(j=0;j<count;j=j+1) begin
    @(negedge uclk);iv=1;sof=j==0;eol=(j%3)==2;
    last=(j==count-1 && kind!=1);data=pattern(frame,j);
    if(kind==2 && j==3) eol=1;
    @(negedge uclk);iv=0;sof=0;eol=0;last=0;
    repeat(gap) @(negedge uclk);
   end
  end
 endtask
 initial begin
  if(DIAG) begin
   reset_case();
   if(dut.first_fault!==256'd0) $fatal(1,"fault reset");
   send_frame(0,12,0,3);wait(dut.store.invalid_frames==1);
   repeat(100) @(negedge uclk);
   if(dut.first_fault[31:0]!==32'h80000004 || dut.first_fault[63:32]!==0 ||
      dut.first_fault[95:64]!==12 || dut.first_fault[127:96]!==11 ||
      dut.first_fault[159:128]!==32'h00030002 || dut.first_fault[255:224]!==48)
    $fatal(1,"short LAST diagnostic %h",dut.first_fault);
   // Later errors must not overwrite the first one.
   send_frame(1,48,2,3);wait(dut.store.invalid_frames==2);
   repeat(100) @(negedge uclk);
   if(dut.first_fault[31:0]!==32'h80000004 || dut.first_fault[63:32]!==0 ||
      dut.first_fault[95:64]!==12) $fatal(1,"first fault overwritten");
   @(negedge uclk);en=0;repeat(50) @(negedge uclk);
   if(dut.first_fault[31:0]!==32'h80000004) $fatal(1,"disable cleared evidence");
   $display("PASS fault recorder: short frame words/index/row/column, coherent CDC, sticky first record");
   reset_case();send_frame(0,48,2,3);wait(dut.store.invalid_frames==1);
   repeat(100) @(negedge uclk);
   if(dut.first_fault[31:0]!==32'h80000010 || dut.first_fault[95:64]!==48 ||
      dut.first_fault[127:96]!==3 || dut.first_fault[159:128]!==32'h00010000)
    $fatal(1,"EOL diagnostic %h",dut.first_fault);
   reset_case();send_frame(0,48,1,3);wait(dut.store.invalid_frames==1);
   repeat(100) @(negedge uclk);
   if(dut.first_fault[31:0]!==32'h80000008 || dut.first_fault[95:64]!==48 ||
      dut.first_fault[127:96]!==47) $fatal(1,"missing LAST diagnostic");
   // No LAST before next SOF: observe the interruption without consuming SOF.
   reset_case();send_frame(0,12,1,3);send_frame(1,48,0,3);wait(completed==1);
   repeat(100) @(negedge uclk);
   if(dut.first_fault[31:0]!==32'h80000003 || dut.first_fault[95:64]!==12 ||
      dut.first_fault[127:96]!==12 || dut.first_fault[223:192]!==1)
    $fatal(1,"SOF/ID diagnostic %h",dut.first_fault);
   $display("PASS fault recorder: EOL, missing LAST, premature SOF/ID and accepted-word count");
   // Inject a sticky capture-loss marker on a complete input frame.
   reset_case();force dut.store.s_bad=1'b1;
   send_frame(0,48,0,3);wait(dut.store.invalid_frames==1);
   release dut.store.s_bad;repeat(100) @(negedge uclk);
   if(dut.first_fault[31:0]!==32'h80000020 || dut.first_fault[127:96]!==0)
    $fatal(1,"capture bad diagnostic");
   // A changed ID without SOF is distinct from a normal next-SOF interruption.
   reset_case();send_frame(0,12,1,3);
   force dut.store.s_sof=1'b0;
   send_frame(1,12,1,3);release dut.store.s_sof;
   wait(dut.store.invalid_frames==1);repeat(100) @(negedge uclk);
   if(dut.first_fault[31:0]!==32'h80000002 || dut.first_fault[95:64]!==12 ||
      dut.first_fault[223:192]!==1) $fatal(1,"ID-only diagnostic %h",dut.first_fault);
   $display("PASS fault recorder: capture bad marker, ID-only change, disable preserves evidence");
   reset_case();bad_write=1;send_frame(0,48,0,3);wait(dut.store.invalid_frames==1);
   repeat(100) @(negedge uclk);
   if(dut.first_fault[31:0]!==32'h80000040 || dut.first_fault[95:64]!==48 ||
      dut.first_fault[127:96]!==8 || dut.first_fault[175:172]!==4 ||
      dut.first_fault[167:166]!==2) $fatal(1,"BRESP diagnostic %h",dut.first_fault);
   reset_case();send_frame(0,48,0,3);wait(completed==1);
   repeat(100) @(negedge uclk);
   if(dut.first_fault!==0) $fatal(1,"clean frame generated fault");
   $display("PASS fault recorder: BRESP context, reset clears record, clean frames unaffected");
   $finish;
  end
  if(STARTUP) begin
   reset_case();
   // Ignore a mid-frame tail before the first observed SOF.
   repeat(20) begin
    @(negedge uclk);iv=1;sof=0;eol=1;last=0;data=0;
   end
   @(negedge uclk);iv=0;eol=0;
   // Invalid first exposure is intentionally skipped, including all its data.
   send_frame(0,12,0,0);
   send_frame(1,48,0,3);wait(completed==1);
   if(current_id!=1 || dut.store.invalid_frames!=0 || cap_drops!=0 ||
      dut.startup_skipped_frames!=1) $fatal(1,"startup exclusion/identity");
   // A later invalid frame MUST still fail validation, never be hidden.
   send_frame(2,12,0,3);send_frame(3,48,0,3);wait(completed==2);
   if(current_id!=3 || dut.store.invalid_frames!=1) $fatal(1,"runtime error masked");
   // Disable/enable without a soft reset: skip again and preserve capture IDs.
   repeat(150) @(negedge uclk);
   en=0;repeat(12) @(negedge uclk);en=1;
   send_frame(4,48,0,3);send_frame(5,48,0,3);wait(completed==3);
   if(current_id!=5 || dut.startup_skipped_frames!=2 || dut.store.invalid_frames!=1)
    $fatal(1,"re-enable guard");
   // Enable deasserted during warmup: rearm at a new SOF.
   reset_case();send_frame(0,12,1,0);
   @(negedge uclk);en=0;repeat(12) @(negedge uclk);en=1;
   send_frame(1,12,0,0);send_frame(2,48,0,3);wait(completed==1);
   if(current_id!=2 || dut.startup_skipped_frames!=2 || dut.store.invalid_frames!=0 || cap_drops!=0)
    $fatal(1,"warmup disable recovery");
   // Every soft-reset cycle must skip exactly one exposure, never only once.
   for(f=0;f<3;f=f+1) begin
    reset_case();send_frame(0,48,0,3);send_frame(1,48,0,3);wait(completed==1);
    if(current_id!=1 || dut.startup_skipped_frames!=1 || dut.store.invalid_frames!=0)
     $fatal(1,"soft reset guard");
   end
   $display("PASS DDR startup: partial tail/first frame excluded, second SOF retained, IDs preserved, later faults rejected, enable/reset rearmed");
   $finish;
  end
  reset_case();
  for(f=0;f<100;f=f+1) begin
   send_frame(f,48,0,3);wait(completed==f+1);
  end
  if(dut.store.published_frames!=100 || dut.store.invalid_frames!=0 || cap_drops!=0)
   $fatal(1,"baseline counters");
  $display("PASS DDR: 100 complete frames with unrelated clocks and random AXI/sink stalls");

  reset_case();stall_sink=1;
  for(f=0;f<=SLOTS;f=f+1) send_frame(f,48,0,3);
  repeat(150) @(negedge uclk);
  if(dut.store.published_frames!=SLOTS || dut.store.dropped_frames!=1 || completed!=0)
   $fatal(1,"slot admission %0d %0d",dut.store.published_frames,dut.store.dropped_frames);
  stall_sink=0;wait(completed==SLOTS);
  if(current_id!=SLOTS-1) $fatal(1,"slot overwrite/publication order");
  $display("PASS DDR: %0d busy slots protected; extra incoming frame dropped whole; FIFO publication order retained",SLOTS);

  if(SLOTS>2) begin
   // Producer does not wait for replay: wrap slot and queue pointers while
   // source writes, replay reads, and sink stalls overlap.
   reset_case();
   for(f=0;f<48;f=f+1) begin
    stall_sink=(f%9)<5;
    send_frame(f,48,0,3);
   end
   stall_sink=0;
   repeat(8000) @(negedge uclk);
   if(dut.store.invalid_frames!=0 || cap_drops!=0 ||
      dut.store.published_frames+dut.store.dropped_frames!=48 ||
      completed!=dut.store.published_frames || dut.store.ready_count!=0)
    $fatal(1,"queued stress counters pub=%0d drop=%0d done=%0d ready=%0d",dut.store.published_frames,dut.store.dropped_frames,completed,dut.store.ready_count);
   $display("PASS DDR four-slot queue: 48 exposures without replay waits, concurrent publish/dequeue, slot/queue wrap, exact payload/order");
  end

  reset_case();
  send_frame(0,12,0,3);send_frame(1,48,0,3);wait(completed==1);
  if(current_id!=1) $fatal(1,"short frame published");
  send_frame(2,48,1,3);send_frame(3,48,0,3);wait(completed==2);
  if(current_id!=3) $fatal(1,"missing LAST published");
  send_frame(4,48,2,3);send_frame(5,48,0,3);wait(completed==3);
  if(current_id!=5 || dut.store.invalid_frames!=3) $fatal(1,"marker validation");
  $display("PASS DDR: short frames, missing LAST and wrong EOL never published");

  reset_case();hold_writes=1;
  send_frame(0,48,0,0);repeat(50) @(negedge uclk);
  if(cap_drops==0) $fatal(1,"overflow injection missed");
  hold_writes=0;repeat(150) @(negedge uclk);
  send_frame(1,48,0,3);wait(completed==1);
  if(current_id!=1 || dut.store.invalid_frames==0) $fatal(1,"overflow frame published");
  $display("PASS DDR: capture FIFO overflow invalidates entire frame and resynchronizes");

  reset_case();bad_write=1;
  send_frame(0,48,0,3);wait(dut.store.invalid_frames==1);bad_write=0;
  if(dut.store.published_frames!=0 || dut.store.write_errors==0) $fatal(1,"BRESP handling");
  send_frame(1,48,0,3);wait(completed==1);
  if(current_id!=1) $fatal(1,"bad write published");
  $display("PASS DDR: BRESP errors reject the frame before publication");

  reset_case();bad_read=1;
  send_frame(0,48,0,3);wait(dut.store.read_errors!=0);repeat(150) @(negedge uclk);
  if(completed!=0 || dut.store.rs!=3) $fatal(1,"RRESP did not halt replay");
  reset_case();send_frame(0,48,0,3);wait(completed==1);
  $display("PASS DDR: RRESP errors halt without frame LAST; reset recovers cleanly");
  $finish;
 end
endmodule

module tb_ddr_startup;
 tb_ddr_frame_path #(.STARTUP(1)) test();
endmodule

module tb_ddr_diagnostics;
 tb_ddr_frame_path #(.DIAG(1)) test();
endmodule

module tb_ddr_ring4;
 tb_ddr_frame_path #(.SLOTS(4)) test();
endmodule
