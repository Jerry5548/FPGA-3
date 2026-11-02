`timescale 1ns/1ps
module tb_packer_boundary;
 reg clk=0,rst_n=0,iv=0,last=0,ready=1; reg [31:0] data=0; reg [2:0] keep=0; wire ir,ov,ol; wire [127:0] od; wire [15:0] ok;
 always #5 clk=~clk;
 lz77_c2h_word_packer #(.PACKET_BEATS(64)) dut(.clk(clk),.rst_n(rst_n),.i_valid(iv),.i_ready(ir),.i_data(data),.i_keep(keep),.i_last(last),.o_valid(ov),.o_ready(ready),.o_data(od),.o_keep(ok),.o_last(ol));
 integer n=0;
 always @(posedge clk) if(rst_n && ov && ready) begin
   n=n+1;
   if(n==1 && (ok!==16'hffff || ol!==0)) $fatal(1,"crossing beat must be full");
   if(n==2 && (ok!==16'h0003 || ol!==1)) $fatal(1,"carry must end packet");
   $display("OUT %0d keep=%h last=%b",n,ok,ol);
 end
 task send(input [2:0] k,input bit l); begin @(negedge clk); iv=1;keep=k;last=l;data=n; @(posedge clk);while(!ir) @(posedge clk); @(negedge clk); iv=0;last=0; end endtask
 initial begin repeat(2) @(negedge clk); rst_n=1; repeat(7) send(3'd2,0); send(3'd4,1); repeat(10) @(posedge clk); if(n!=2) $fatal(1,"expected 2 beats, got %0d",n); $display("PASS boundary flush"); $finish; end
endmodule
