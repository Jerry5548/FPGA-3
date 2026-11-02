`timescale 1ns/1ps
module tb_quad_runs;
 reg clk=0,rst_n=0,iv=0,sof=0,last=0,ready=0;
 reg [31:0] data=0;
 wire ir,ov,os,ol;wire [95:0] encoded;
 wire [3:0] bytes_n;wire [2:0] tokens_n;wire [15:0] raw_n;
 wire [31:0] raw,compressed,tokens,errors,fid;
 reg [7:0] expected[0:39999];
 integer size,sent,decoded,outs,cycles,ends,pattern,seed=1771;
 integer j,k,n,raw_batch;
 reg [7:0] control,value;
 reg stalled=0;reg [156:0] held;
 reg consumed=0;
 always #4 clk=~clk;
 lz77_quad_encoder dut(.clk(clk),.rst_n(rst_n),.i_valid(iv),.i_ready(ir),
  .i_data(data),.i_sof(sof),.i_last(last),.i_frame_id(32'd73),
  .o_valid(ov),.o_ready(ready),.o_data(encoded),.o_bytes(bytes_n),.o_tokens(tokens_n),
  .o_raw(raw_n),.o_raw_data(),.o_sof(os),.o_last(ol),.o_frame_id(fid),
  .raw_byte_count(raw),.compressed_byte_count(compressed),.token_count(tokens),.error_count(errors));
 always @(posedge clk) if(rst_n) begin
  if(stalled && (!ov || {encoded,bytes_n,tokens_n,raw_n,os,ol,fid}!==held))
   $fatal(1,"quad batch changed under backpressure");
  held={encoded,bytes_n,tokens_n,raw_n,os,ol,fid};stalled=ov&&!ready;
  consumed=iv&&ir;
  if(consumed) sent=sent+4;
  if(ov&&ready) begin
   if(bytes_n!=tokens_n*2 || tokens_n>6 || fid!=73) $fatal(1,"invalid batch");
   raw_batch=0;
   for(k=0;k<tokens_n;k=k+1) begin
    control=encoded[k*16 +:8];value=encoded[k*16+8 +:8];
    n=control==0 ? 1 : control&127;
    if(control!=0 && (!control[7] || n<3 || value!=1 || decoded==0))
     $fatal(1,"invalid quad match");
    for(j=0;j<n;j=j+1) begin
     if(decoded>=size || expected[decoded] !== (control==0 ? value : expected[decoded-1]))
      $fatal(1,"quad pixel mismatch offset=%0d pattern=%0d",decoded,pattern);
     decoded=decoded+1;raw_batch=raw_batch+1;
    end
    outs=outs+1;
   end
   if(raw_batch!=raw_n) $fatal(1,"raw delta mismatch");
   if(ol) begin ends=ends+1;if(decoded!=size) $fatal(1,"wrong LAST");end
  end
 end
 initial begin
  for(pattern=0;pattern<3;pattern=pattern+1) begin
   rst_n=0;iv=0;sent=0;decoded=0;size=0;outs=0;ends=0;stalled=0;consumed=0;
   for(j=1;j<=260;j=j+1)
    repeat(j) begin expected[size]=j%251;size=size+1;end
   while(size%4!=0) begin expected[size]=8'hbb;size=size+1;end
   repeat(4) @(negedge clk);rst_n=1;cycles=0;
   while(ends==0) begin
    @(negedge clk);cycles=cycles+1;
    if(!iv || consumed) begin
     iv=(sent<size) && (pattern==0 || ($random(seed)&7)!=0);
     sof=(sent==0);last=(sent==size-4);
     for(k=0;k<4;k=k+1) data[k*8 +:8]=expected[sent+k];
    end
    ready=pattern<2 || ($random(seed)&3)!=0;
    if(cycles>size*8) $fatal(1,"quad watchdog");
   end
   @(negedge clk);iv=0;repeat(3) @(negedge clk);
   if(raw!=size || errors!=0 || ends!=1 || tokens!=outs) $fatal(1,"quad counters");
  end
  $display("PASS quad runs: lengths 1..260 across four-byte lanes, source gaps, output stalls, exact bytes");
  $finish;
 end
endmodule
