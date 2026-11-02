`timescale 1ns/1ps
// The next frame's first token is offered while the preceding final token
// is pending. It must not be acknowledged then discarded on ST_FOOTER.
module tb_formatter_eof;
 reg clk=0,rst_n=0,iv=0,sof=0,last=0,ready=0;
 reg [15:0] token=0;reg [31:0] fid=0;
 wire ir,ov,ol,os;wire [31:0] od,frames,errors;wire [2:0] ok;
 integer f,j,k,fd,ticks=0;
 always #4 clk=~clk;
 lz77_frame_formatter #(.IMAGE_WIDTH(1),.IMAGE_HEIGHT(1)) dut(
  .clk(clk),.rst_n(rst_n),.i_valid(iv),.i_ready(ir),.i_token(token),
  .i_match(1'b0),.i_bytes(2'd1),.i_sof(sof),.i_last(last),.i_frame_id(fid),
  .o_valid(ov),.o_ready(ready),.o_data(od),.o_keep(ok),.o_sof(os),.o_last(ol),
  .frame_count(frames),.error_count(errors));
 always @(negedge clk) begin
  ticks=ticks+1;ready=(ticks%11)<7;
  if(ticks>50000) $fatal(1,"watchdog");
 end
 always @(posedge clk) if(rst_n && ov && ready)
  for(k=0;k<ok;k=k+1) $fwrite(fd,"%02x\n",od[k*8+:8]);
 initial begin
  fd=$fopen("formatter_eof.hex","w");repeat(5) @(negedge clk);rst_n=1;
  for(f=0;f<100;f=f+1) for(j=0;j<3;j=j+1) begin
   @(negedge clk);iv=1;sof=(j==0);last=(j==2);fid=f;token=f*3+j;
   @(posedge clk);while(!ir) @(posedge clk);
  end
  @(negedge clk);iv=0;repeat(50) @(posedge clk);
  if(frames!=100 || errors!=0) $fatal(1,"frames=%0d errors=%0d",frames,errors);
  $display("PASS formatter EOF: 100 back-to-back frames, no next-frame token loss");$finish;
 end
endmodule
