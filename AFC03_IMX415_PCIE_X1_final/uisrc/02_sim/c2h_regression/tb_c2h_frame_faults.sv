`timescale 1ns/1ps
module tb_c2h_frame_faults;
 reg clk=0,rst_n=0,iv=0,sof=0,last=0,ready=0;
 reg [127:0] data=0;
 always #4 clk=~clk;
 wire ir,ov,ol;
 wire [127:0] od;
 wire [15:0] ok;
 wire [31:0] errors,frames;
 integer f,j,k,limit,fd,rawfd,ticks=0;
 reg stalled=0;reg [144:0] held;
 lz77_rgb_c2h_path #(.IMAGE_WIDTH(16),.IMAGE_HEIGHT(16),.PACKET_WORDS(8)) dut(
  .clk(clk),.rst_n(rst_n),.i_valid(iv),.i_ready(ir),.i_data(data),.i_sof(sof),
  .i_frame_last(last),.i_frame_id(32'hff00ffff),.o_valid(ov),.o_ready(ready),
  .o_data(od),.o_keep(ok),.o_last(ol),.raw_bytes(),.compressed_bytes(),
  .token_count(),.frame_count(frames),.error_count(errors));
 always @(negedge clk) begin
  ticks=ticks+1;ready=(ticks%53)<37;
  if(ticks>200000) $fatal(1,"watchdog");
 end
 always @(posedge clk) if(rst_n) begin
  if(stalled && (!ov || {od,ok,ol}!==held)) $fatal(1,"stalled output");
  stalled=ov&&!ready;held={od,ok,ol};
  if(ov&&ready) begin
   if(ok==0 || (({1'b0,ok}+1)&{1'b0,ok})!=0 || (!ol && ok!=16'hffff))
     $fatal(1,"KEEP/LAST");
   for(k=0;k<16;k=k+1) if(ok[k]) $fwrite(fd,"%02x\n",od[k*8+:8]);
  end
 end
 initial begin
  fd=$fopen("fault_stream.hex","w");
  repeat(5) @(negedge clk);rst_n=1;
  for(f=0;f<5;f=f+1) begin
   limit=(f==1)?12:48;
   rawfd=$fopen($sformatf("fault_raw_%0d.hex",f),"w");
   for(j=0;j<limit;j=j+1) begin
    @(negedge clk);iv=1;sof=j==0;last=(j==limit-1 && f!=1 && f!=3);
    data={16{8'h30+f[7:0]}};
    for(k=0;k<16;k=k+1) $fwrite(rawfd,"%02x\n",data[k*8+:8]);
    @(posedge clk);while(!ir) @(posedge clk);
   end
   $fclose(rawfd);
   if(f==0) begin
    // Four orphan beats after a completed frame must not become a header.
    for(j=0;j<4;j=j+1) begin
     @(negedge clk);iv=1;sof=0;last=0;data={16{8'hff}};
     @(posedge clk);while(!ir) @(posedge clk);
    end
   end
  end
  @(negedge clk);iv=0;sof=0;last=0;
  repeat(20000) @(posedge clk);
  if(frames!=5 || errors!=6) $fatal(1,"frames=%0d errors=%0d",frames,errors);
  $display("PASS C2H faults: short frame closed before SOF, missing LAST bounded, orphan bytes rejected, errors=%0d",errors);$finish;
 end
endmodule
