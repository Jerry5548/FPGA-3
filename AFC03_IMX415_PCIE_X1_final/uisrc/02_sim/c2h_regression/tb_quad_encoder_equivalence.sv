`timescale 1ns/1ps
// Reference is extracted from the preserved pre-pipeline source by the runner.
module tb_quad_encoder_equivalence;
 localparam N=12000;
 reg clk=0,rst_n=0,ready=0;
 always #4 clk=~clk;
 integer sent[0:1],got[0:1],compared=0,cycle=0;
 reg consumed[0:1];
 reg valid[0:1];wire ir[0:1],ov[0:1],os[0:1],ol[0:1];
 reg [31:0] data[0:1];reg sof[0:1],last[0:1];
 wire [95:0] tokens[0:1];wire [3:0] bytes_n[0:1];wire [2:0] token_n[0:1];
 wire [15:0] raw_n[0:1];wire [31:0] raw_data[0:1],id[0:1],raws[0:1],comps[0:1],counts[0:1],errs[0:1];
 reg [240:0] received[0:1][0:N-1];
 reg [240:0] held[0:1];reg stall[0:1];
 reg [31:0] rng=32'h35762928;
 function [7:0] source_byte;
  input integer index;
  begin
   if(index%5==0) source_byte=(index*73)&255;
   else if(index<16000) source_byte=(index/127)&255;
   else if(index<32000) source_byte=(index/259)&255;
   else source_byte=((index*13)^(index>>3))&255;
  end
 endfunction
 lz77_quad_encoder dut(.clk(clk),.rst_n(rst_n),.i_valid(valid[0]),.i_ready(ir[0]),
  .i_data(data[0]),.i_sof(sof[0]),.i_last(last[0]),.i_frame_id(32'd19),
  .o_valid(ov[0]),.o_ready(ready),.o_data(tokens[0]),.o_bytes(bytes_n[0]),.o_tokens(token_n[0]),
  .o_raw(raw_n[0]),.o_raw_data(raw_data[0]),.o_sof(os[0]),.o_last(ol[0]),.o_frame_id(id[0]),
  .raw_byte_count(raws[0]),.compressed_byte_count(comps[0]),.token_count(counts[0]),.error_count(errs[0]));
 lz77_quad_encoder_reference reference(.clk(clk),.rst_n(rst_n),.i_valid(valid[1]),.i_ready(ir[1]),
  .i_data(data[1]),.i_sof(sof[1]),.i_last(last[1]),.i_frame_id(32'd19),
  .o_valid(ov[1]),.o_ready(ready),.o_data(tokens[1]),.o_bytes(bytes_n[1]),.o_tokens(token_n[1]),
  .o_raw(raw_n[1]),.o_raw_data(raw_data[1]),.o_sof(os[1]),.o_last(ol[1]),.o_frame_id(id[1]),
  .raw_byte_count(raws[1]),.compressed_byte_count(comps[1]),.token_count(counts[1]),.error_count(errs[1]));
 integer i,b;
 always @(posedge clk) if(rst_n) begin
  cycle=cycle+1;
  for(integer n=0;n<2;n=n+1) begin
   consumed[n]=valid[n]&&ir[n];
   if(consumed[n]) sent[n]=sent[n]+1;
   if(stall[n] && (!ov[n] || held[n]!=={tokens[n],bytes_n[n],token_n[n],raw_n[n],raw_data[n],os[n],ol[n],id[n]}))
    $fatal(1,"encoder output changed under stall lane=%0d",n);
   held[n]={tokens[n],bytes_n[n],token_n[n],raw_n[n],raw_data[n],os[n],ol[n],id[n]};stall[n]=ov[n]&&!ready;
   if(ov[n]&&ready) begin
    if(got[n]>=N) $fatal(1,"extra batch");
    received[n][got[n]]={tokens[n],bytes_n[n],token_n[n],raw_n[n],raw_data[n],os[n],ol[n],id[n]};
    got[n]=got[n]+1;
   end
  end
  if(cycle>100000) $fatal(1,"equivalence watchdog");
 end
 always @(negedge clk) if(rst_n) begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
  ready=rng[4:0]!=0 && cycle%97<71;
  for(integer n=0;n<2;n=n+1) if(!valid[n] || consumed[n]) begin
   valid[n]=sent[n]<N && rng[n+2]!=0;
   sof[n]=sent[n]%200==0;last[n]=sent[n]%200==199;
   for(integer j=0;j<4;j=j+1) data[n][j*8 +:8]=source_byte(sent[n]*4+j);
  end
  while(compared<got[0] && compared<got[1]) begin
   if(received[0][compared]!==received[1][compared])
    $fatal(1,"batch mismatch %0d got=%h reference=%h",compared,received[0][compared],received[1][compared]);
   compared=compared+1;
  end
 end
 initial begin
  for(i=0;i<2;i=i+1) begin
   sent[i]=0;got[i]=0;consumed[i]=0;valid[i]=0;sof[i]=0;last[i]=0;data[i]=0;stall[i]=0;held[i]=0;
  end
  repeat(4) @(negedge clk);rst_n=1;
  wait(compared==N);repeat(5) @(negedge clk);
  if(raws[0]!==raws[1] || comps[0]!==comps[1] || counts[0]!==counts[1] || errs[0] || errs[1])
   $fatal(1,"diagnostic counter mismatch");
  $display("PASS pipelined encoder exact batch equivalence: %0d groups, tokens/raw passthrough/markers/counters, gaps, stalls, consecutive frames",N);
  $finish;
 end
endmodule
