`timescale 1ns/1ps
// Behavioral AXI RAM with variable ready/response latency and fault injection.
// This verifies requester protocol; it is not an analog DDR PHY model.
module axi_frame_memory_model(
 input wire clk,rst_n,hold_writes,bad_write,bad_read,
 input wire [15:0] awaddr,input wire [7:0] awlen,input wire awvalid,output wire awready,
 input wire [127:0] wdata,input wire wlast,wvalid,output wire wready,
 output reg [1:0] bresp,output wire [3:0] bid,output reg bvalid,input wire bready,
 input wire [15:0] araddr,input wire [7:0] arlen,input wire arvalid,output wire arready,
 output reg [127:0] rdata,output reg [1:0] rresp,output wire [3:0] rid,
 output reg rlast,rvalid,input wire rready
);
 reg [127:0] mem[0:4095];
 reg writing,reading;
 integer wbase,rbase,wi,ri,wlength,rlength,delay_b,tick;
 assign awready=rst_n && !hold_writes && !writing && !bvalid && delay_b==0 && tick%7!=0;
 assign wready=rst_n && !hold_writes && writing && tick%5!=0;
 assign arready=rst_n && !reading && !rvalid && tick%11!=0;
 assign bid=0;assign rid=0;
 reg awheld,arheld,wheld,rheld;
 reg [23:0] old_aw,old_ar;
 reg [128:0] old_w;
 reg [130:0] old_r;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   writing<=0;reading<=0;bvalid<=0;rvalid<=0;rlast<=0;bresp<=0;rresp<=0;rdata<=0;
   wbase<=0;rbase<=0;wi<=0;ri<=0;wlength<=0;rlength<=0;delay_b<=0;tick<=0;
   awheld<=0;arheld<=0;wheld<=0;rheld<=0;
  end else begin
   tick<=tick+1;
   if(awheld && (!awvalid || {awaddr,awlen}!==old_aw)) $fatal(1,"AW changed while stalled");
   if(arheld && (!arvalid || {araddr,arlen}!==old_ar)) $fatal(1,"AR changed while stalled");
   if(wheld && (!wvalid || {wdata,wlast}!==old_w)) $fatal(1,"W changed while stalled");
   if(rheld && (!rvalid || {rdata,rresp,rlast}!==old_r)) $fatal(1,"model R stall bug");
   awheld<=awvalid&&!awready;old_aw<={awaddr,awlen};
   arheld<=arvalid&&!arready;old_ar<={araddr,arlen};
   wheld<=wvalid&&!wready;old_w<={wdata,wlast};
   rheld<=rvalid&&!rready;old_r<={rdata,rresp,rlast};
   if(awvalid&&awready) begin
    if(awaddr[3:0]!=0 || awaddr[11:0]+(awlen+1)*16>4096) $fatal(1,"AW alignment/boundary");
    writing<=1;wbase<=awaddr/16;wi<=0;wlength<=awlen+1;
   end
   if(wvalid&&wready) begin
    if(wlast !== (wi==wlength-1)) $fatal(1,"WLAST mismatch");
    mem[wbase+wi]<=wdata;
    if(wlast) begin writing<=0;delay_b<=3;bresp<=bad_write?2'b10:0;end
    else wi<=wi+1;
   end
   if(delay_b>0) begin
    delay_b<=delay_b-1;
    if(delay_b==1) bvalid<=1;
   end
   if(bvalid&&bready) bvalid<=0;
   if(arvalid&&arready) begin
    if(araddr[3:0]!=0 || araddr[11:0]+(arlen+1)*16>4096) $fatal(1,"AR alignment/boundary");
    reading<=1;rbase<=araddr/16;ri<=0;rlength<=arlen+1;
   end
   if(reading && (!rvalid || rready) && tick%3!=0) begin
    rvalid<=1;rdata<=mem[rbase+ri];rlast<=ri==rlength-1;
    rresp<=bad_read && ri==3 ? 2'b10 : 0;
    if(ri==rlength-1) reading<=0;
    else ri<=ri+1;
   end else if(rvalid&&rready) rvalid<=0;
  end
 end
endmodule
