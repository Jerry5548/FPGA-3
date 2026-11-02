`timescale 1ns/1ps
module tb_h2v1 #(
 parameter integer W=16,H=16,FRAMES=3,MODE=8,BLOCK_BYTES=256,HOST=1,T0=40
);
 localparam integer WORDS=W*H/4;
 reg clk=0,rst_n=0,enable=0,sv=0,sink_ready=0;
 reg [127:0] sd=0;
 reg [15:0] sk=16'hffff;
 always #5 clk=~clk;
 wire sr,hv,hr,hs,he,pv,pr,ps,pe,pl,cv,cl;
 wire [127:0] hd,pd,cd;
 wire [15:0] ck;
 wire [31:0] fid,frames,errors,status,cf,ce,overflow,me,se,de;
 h2c_video_source #(.IMAGE_WIDTH(W),.IMAGE_HEIGHT(H)) source(
  .clk(clk),.rst_n(rst_n),.enable(enable),.s_data(sd),.s_keep(sk),.s_valid(sv),.s_ready(sr),
  .o_rgb(hd),.o_valid(hv),.o_sof(hs),.o_eol(he),.o_ready(HOST ? hr : 1'b1),
  .frame_consumed(pv&&pr&&pl),.frame_id(fid),.frame_count(frames),.error_count(errors),.status(status));
 video_preprocess_input #(.IMAGE_WIDTH(W),.IMAGE_HEIGHT(H),.HOST_INPUT_ENABLE(1)) shared(
  .user_clk(clk),.user_rst_n(rst_n),.enable(enable),.preprocess_enable(1'b1),
  // Deliberate competing camera data must never reach host output.
  .camera_rgb(HOST ? 128'hdeadbeef : hd),.camera_valid(HOST ? 1'b1 : hv),
  .camera_sof(HOST ? 1'b1 : hs),.camera_eol(HOST ? 1'b1 : he),.camera_ready(),
  .host_select(1'(HOST)),.host_valid(hv),.host_sof(hs),.host_eol(he),.host_rgb(hd),.host_ready(hr),
  .cfg_preprocess_mode(4'(MODE)),.preprocess_mode_active(),
  .median_error_count(me),.sobel_error_count(se),.dehaze_error_count(de),.fifo_overflow_count(overflow),
  .m_tdata(pd),.m_tvalid(pv),.m_tready(pr),.m_tlast(pe),.m_frame_last(pl),.sof(ps),.eof(),.frame_count_out());
 lz77_rgb_c2h_path #(.IMAGE_WIDTH(W),.IMAGE_HEIGHT(H),.USE_INPUT_FRAME_ID(1),
  .PACKET_WORDS(4096),.BLK1_ENABLE(1),.BLK1_BLOCK_BYTES(BLOCK_BYTES)) codec(
  .clk(clk),.rst_n(rst_n),.i_valid(pv),.i_ready(pr),.i_data(pd),.i_sof(ps),.i_frame_last(pl),.i_frame_id(fid),
  .o_valid(cv),.o_ready(sink_ready),.o_data(cd),.o_keep(ck),.o_last(cl),
  .raw_bytes(),.compressed_bytes(),.token_count(),.frame_count(cf),.error_count(ce));
 reg [127:0] src[0:FRAMES*WORDS-1];
 integer ticks=0,j,f,k,fd;
 reg stalled=0;reg [144:0] held;
 always @(negedge clk) begin
  ticks=ticks+1;
  sink_ready=(ticks%117)<71 && !(ticks>1500 && ticks<5000);
  if(ticks>FRAMES*WORDS*50+50000) $fatal(1,"H2V1 watchdog state=%0d credit=%0d cf=%0d",source.state,shared.host_outstanding,cf);
 end
 always @(posedge clk) if(rst_n) begin
  if(stalled && (!cv || {cd,ck,cl}!==held)) $fatal(1,"C2H changed under backpressure");
  stalled=cv&&!sink_ready;held={cd,ck,cl};
  if(shared.host_outstanding>1000) $fatal(1,"credit overflow/underflow");
  if(cv&&sink_ready) begin
   if(ck==0 || (({1'b0,ck}+1)&{1'b0,ck})!=0 || (!cl && ck!=16'hffff)) $fatal(1,"KEEP/LAST");
   for(k=0;k<16;k=k+1) if(ck[k]) $fwrite(fd,"%c",cd[k*8+:8]);
  end
 end
 task send_word(input [127:0] word);
  begin
   @(negedge clk);sd=word;sv=1;
   do @(posedge clk); while(!sr);
   @(negedge clk);sv=0;
   if((ticks%13)==0) repeat(3) @(negedge clk);
  end
 endtask
 task reset_all;
  begin
   @(negedge clk);enable=0;rst_n=0;sv=0;sk=16'hffff;
   repeat(5) @(negedge clk);rst_n=1;enable=1;
   repeat(300) @(negedge clk);
  end
 endtask
 initial begin
  fd=$fopen("stream.bin","wb");$readmemh("input.hex",src);
  reset_all();
  for(f=0;f<FRAMES;f=f+1) begin
   send_word({32'(W*H*4),32'(f+1),16'(H),16'(W),32'h31563248});
   for(j=0;j<WORDS;j=j+1) send_word(src[f*WORDS+j]);
  end
  wait(cf==FRAMES && frames==FRAMES);
  repeat(1500) @(posedge clk);
  if(errors || ce || overflow || me || se || de || shared.host_outstanding) $fatal(1,"integrity errors");
  $fclose(fd);
  $display("PASS H2V1 real shared path mode=%0d %0dx%0d frames=%0d: no frame skips, bounded credit, backpressure",MODE,W,H,FRAMES);
  reset_all();
  send_word({32'(W*H*4),32'd1,16'(H),16'(W),32'h0});
  if(errors!=1 || sr || hv) $fatal(1,"bad magic not rejected");
  reset_all();
  send_word({32'(W*H*4+16),32'd1,16'(H),16'(W),32'h31563248});
  if(errors!=1 || sr) $fatal(1,"bad length not rejected");
  reset_all();
  send_word({32'(W*H*4),32'd2,16'(H),16'(W),32'h31563248});
  if(errors!=1 || sr) $fatal(1,"bad frame id not rejected");
  reset_all();sk=16'h0fff;
  send_word({32'(W*H*4),32'd1,16'(H),16'(W),32'h31563248});
  if(errors!=1 || sr) $fatal(1,"short header keep not rejected");
  reset_all();
  send_word({32'(W*H*4),32'd1,16'(H),16'(W),32'h31563248});
  sk=16'hfffe;send_word(128'd123);
  if(errors!=1 || sr || hv) $fatal(1,"short payload keep not rejected");
  $display("PASS H2V1 fail-closed magic/length/frame-id/header-keep/payload-keep and reset recovery");
  $finish;
 end
endmodule
