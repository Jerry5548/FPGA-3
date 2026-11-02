`timescale 1ns/1ps
// Model the camera ISP holding TVALID/TDATA while its FIFO is full.
// Mode 1 output must contain only accepted RGB beats, never replay stalls.
module tb_preprocess_handshake;
 reg clk=0,rst_n=0,valid=0,sof=0,eol=0,ready=0;
 reg [127:0] rgb=0;
 always #4 clk=~clk;
 wire ov,os,oe;wire [127:0] od;
 integer ticks=0,sent=0,seen=0,j,k;
 reg [127:0] expected[0:31];
 image_preprocess_quad #(.IMAGE_WIDTH(16),.IMAGE_HEIGHT(8),.MODE(1)) dut(
  .clk(clk),.rst_n(rst_n),.i_valid(valid && ready),.i_sof(sof && ready),
  .i_eol(eol && ready),.i_rgb(rgb),.i_mode(3'd1),.active_mode(),
  .o_valid(ov),.o_sof(os),.o_eol(oe),.o_rgb(od),.gaussian_errors(),.histogram_errors());
 always @(negedge clk) begin
   ticks=ticks+1;ready=(ticks%37)<11;
 end
 always @(posedge clk) if(rst_n) begin
   if(ov) begin
     if(seen>=sent || od!==expected[seen]) $fatal(1,"replayed/mismatched beat %0d",seen);
     if(os !== (seen==0) || oe !== ((seen%4)==3)) $fatal(1,"markers");
     seen=seen+1;
   end
   if(valid && ready) begin expected[sent]=rgb;sent=sent+1;end
 end
 initial begin
  repeat(5) @(negedge clk);rst_n=1;
  for(j=0;j<32;j=j+1) begin
   @(negedge clk);valid=1;sof=(j==0);eol=((j%4)==3);
   for(k=0;k<4;k=k+1) rgb[k*32+:32]={8'd0,{3{8'(j*4+k)}}};
   @(posedge clk);while(!ready) @(posedge clk);
  end
  @(negedge clk);valid=0;sof=0;eol=0;
  repeat(100) @(posedge clk);
  if(sent!=32 || seen!=32) $fatal(1,"counts %0d/%0d",sent,seen);
  $display("PASS preprocessing handshake: stalled source consumed once, 32 accepted beats");$finish;
 end
endmodule
