`timescale 1ns/1ps
module tb_blk1_bram;
 parameter integer W=64,H=17,BLOCK=256,FRAMES=12;
 localparam integer SIZE=W*H*3;
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,i_valid=0,i_sof=0,i_frame_last=0,o_ready=0;
 wire i_ready,o_valid,o_last;
 reg [127:0] i_data=0;reg [31:0] i_frame_id=0;
 wire [127:0] o_data;wire [15:0] o_keep;
 wire [31:0] raw_bytes,compressed_bytes,token_count,frame_count,error_count;
 lz77_rgb_c2h_path #(.IMAGE_WIDTH(W),.IMAGE_HEIGHT(H),.BLK1_ENABLE(1),
  .BLK1_BLOCK_BYTES(BLOCK),.PACKET_WORDS(4096),.USE_INPUT_FRAME_ID(1)) dut(.*);
 integer f,p,b,fd,rawfd,cycles=0,accepted=0,ep_bytes=0;
 reg [31:0] rng=32'h35762917;
 reg stalled=0;reg [127:0] held;reg [15:0] held_keep;reg held_last;
 function [7:0] pixel;
  input integer frame_n,offset;
  integer region;
  begin
   region=offset/BLOCK;
   case(frame_n%6)
    0:pixel=(offset*73+(offset>>8)*29+frame_n*11)&255;
    1:pixel=8'h5a;
    2:pixel=(region%2)==0 ? 8'hcc:(offset*47+(offset>>5))&255;
    3:pixel=((offset/128)%2) ? 8'h00:8'hff;
    4:begin
     case(offset%32)
      0:pixel="E";1:pixel="N";2:pixel="D";3:pixel="!";
      4:pixel="L";5:pixel="Z";6:pixel="7";7:pixel="7";
      default:pixel=(offset*13)&255;
     endcase
    end
    default:pixel=((offset%127)<123) ? (offset/127)&255:offset&255;
   endcase
  end
 endfunction
 always @(negedge clk) begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
  o_ready=(rng[3:0]!=0 && (cycles%91)<77);
 end
 always @(posedge clk) begin
  cycles=cycles+1;
  if(cycles>20000000) $fatal(1,"BLK1 watchdog");
  if(rst_n) begin
   if(stalled && (!o_valid || o_data!==held || o_keep!==held_keep || o_last!==held_last))
    $fatal(1,"output changed under backpressure");
   stalled=o_valid&&!o_ready;held=o_data;held_keep=o_keep;held_last=o_last;
   if(o_valid&&o_ready) begin
    if(!o_keep || (o_keep & (o_keep+1))!=0) $fatal(1,"noncontiguous TKEEP");
    for(integer k=0;k<16;k=k+1) if(o_keep[k]) begin
     $fwrite(fd,"%02x\n",o_data[k*8 +:8]);ep_bytes=ep_bytes+1;
    end
    if(!o_last && o_keep!=16'hffff) $fatal(1,"partial non-EOP beat");
    if(o_last) begin
     if(ep_bytes>16384) $fatal(1,"oversized EOP packet");
     ep_bytes=0;
    end
   end
  end else stalled=0;
 end
 task send_beat;
  input [127:0] data;input sof,last;input [31:0] id;
  begin
   @(negedge clk);i_valid=1;i_data=data;i_sof=sof;i_frame_last=last;i_frame_id=id;
   do @(posedge clk); while(!i_ready);
   @(negedge clk);i_valid=0;i_sof=0;i_frame_last=0;
  end
 endtask
 reg [127:0] word;
 initial begin
  if(SIZE%16!=0 || BLOCK%16!=0) $fatal(1,"geometry alignment");
  fd=$fopen("blk1_stream.hex","w");rawfd=$fopen("blk1_raw.hex","w");
  repeat(4) @(negedge clk);rst_n=1;
  // Discard a partially collected old frame through reset (RAM contents persist).
  send_beat(128'h12345678,1,0,99);
  repeat(12) @(negedge clk);rst_n=0;repeat(4) @(negedge clk);
  $fclose(fd);fd=$fopen("blk1_stream.hex","w");ep_bytes=0;rst_n=1;
  for(f=0;f<FRAMES;f=f+1) begin
   for(p=0;p<SIZE;p=p+16) begin
    for(b=0;b<16;b=b+1) begin
     word[b*8 +:8]=pixel(f,p+b);$fwrite(rawfd,"%02x\n",pixel(f,p+b));
    end
    send_beat(word,p==0,p+16==SIZE,1000+f);
    if(rng[6:4]==0) repeat(3) @(negedge clk);
   end
  end
  wait(frame_count==FRAMES);repeat(20) @(negedge clk);
  if(error_count!=0) $fatal(1,"BLK1 error_count=%0d",error_count);
  if(raw_bytes!=FRAMES*SIZE) $fatal(1,"raw counter mismatch %0d",raw_bytes);
  $fclose(fd);$fclose(rawfd);
  $display("PASS BLK1 BRAM frames=%0d bytes=%0d block=%0d cycles=%0d",FRAMES,SIZE,BLOCK,cycles);
  $finish;
 end
endmodule
