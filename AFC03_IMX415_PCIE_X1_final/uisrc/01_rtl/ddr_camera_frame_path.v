`timescale 1ns/1ps
// Non-stallable camera -> CDC FIFO -> complete DDR slots -> CDC -> encoder.
module ddr_camera_frame_path #(
    parameter integer IMAGE_WIDTH=1920,IMAGE_HEIGHT=1080,
    parameter integer FIFO_BITS=12,ADDR_WIDTH=28,BURST_WORDS=16,
    parameter integer SKIP_STARTUP_FRAME=0,SLOT_COUNT=2,
    parameter [ADDR_WIDTH-1:0] SLOT_STRIDE=28'h0800000
)(
    input wire user_clk,ddr_clk,arst_n,
    input wire capture_enable,
    input wire i_valid,input wire [127:0] i_data,input wire i_sof,i_eol,i_last,
    output wire o_valid,input wire o_ready,output wire [127:0] o_data,
    output wire o_sof,o_last,output wire [31:0] o_frame_id,
    output reg [31:0] capture_fifo_drops,output wire [223:0] counters,
    output reg [31:0] startup_skipped_frames,
    output wire [255:0] first_fault,
    output wire [ADDR_WIDTH-1:0] awaddr,output wire [7:0] awlen,
    output wire awvalid,input wire awready,
    output wire [127:0] wdata,output wire wlast,wvalid,input wire wready,
    input wire [1:0] bresp,input wire [3:0] bid,input wire bvalid,output wire bready,
    output wire [ADDR_WIDTH-1:0] araddr,output wire [7:0] arlen,
    output wire arvalid,input wire arready,
    input wire [127:0] rdata,input wire [1:0] rresp,input wire [3:0] rid,
    input wire rlast,rvalid,output wire rready
);
    wire urst_n,drst_n;
    frame_reset_sync ur(.clk(user_clk),.arst_n(arst_n),.rst_n(urst_n));
    frame_reset_sync dr(.clk(ddr_clk),.arst_n(arst_n),.rst_n(drst_n));
    reg [31:0] next_id,active_id;
    reg frame_bad;
    reg startup_seen,capture_active;
    wire in_ready;
    wire source_valid=i_valid && capture_enable && urst_n;
    // Select on the SOF beat itself, then hold through the entire frame.
    // Keep capture IDs for skipped exposures too. Unmarked startup data is
    // ignored, not counted as a FIFO loss or an invalid stored frame.
    wire admit=SKIP_STARTUP_FRAME ?
        (i_sof ? startup_seen : capture_active) : 1'b1;
    wire in_valid=source_valid && admit;
    wire [31:0] input_id=i_sof?next_id:active_id;
    wire [163:0] capture_word={input_id,(i_sof?1'b0:frame_bad),i_sof,i_eol,i_last,i_data};
    wire cv,cr;wire [163:0] cd;
    always @(posedge user_clk or negedge urst_n) begin
        if(!urst_n) begin
            next_id<=0;active_id<=0;frame_bad<=0;capture_fifo_drops<=0;
            startup_seen<=0;capture_active<=0;startup_skipped_frames<=0;
        end else if(!capture_enable) begin
            startup_seen<=0;capture_active<=0;frame_bad<=0;
        end else if(source_valid) begin
            if(i_sof) begin
                next_id<=next_id+1'b1;active_id<=next_id;
                startup_seen<=1;capture_active<=!SKIP_STARTUP_FRAME || startup_seen;
                frame_bad<=admit && !in_ready;
                if(SKIP_STARTUP_FRAME && !startup_seen)
                    startup_skipped_frames<=startup_skipped_frames+1'b1;
            end else if(in_valid && !in_ready) frame_bad<=1;
            if(in_valid && !in_ready) capture_fifo_drops<=capture_fifo_drops+1'b1;
        end
    end
    frame_async_fifo #(.WIDTH(164),.ADDR_BITS(FIFO_BITS)) capture_fifo(
        .wclk(user_clk),.wrst_n(urst_n),.wvalid(in_valid),.wready(in_ready),.wdata(capture_word),
        .rclk(ddr_clk),.rrst_n(drst_n),.rvalid(cv),.rready(cr),.rdata(cd));
    wire rv,rr,rs,rl;wire [127:0] rd;wire [31:0] rf;
    wire [31:0] pubs,drops,invalids,we,re,frames,status;
    wire [255:0] first_fault_ddr;
    ddr_frame_store_axi #(.IMAGE_WIDTH(IMAGE_WIDTH),.IMAGE_HEIGHT(IMAGE_HEIGHT),
        .ADDR_WIDTH(ADDR_WIDTH),.BURST_WORDS(BURST_WORDS),.SLOT_COUNT(SLOT_COUNT),.SLOT_STRIDE(SLOT_STRIDE)) store(
        .clk(ddr_clk),.rst_n(drst_n),.s_valid(cv),.s_ready(cr),.s_data(cd[127:0]),
        .s_sof(cd[130]),.s_eol(cd[129]),.s_last(cd[128]),.s_bad(cd[131]),.s_frame_id(cd[163:132]),
        .o_valid(rv),.o_ready(rr),.o_data(rd),.o_sof(rs),.o_last(rl),.o_frame_id(rf),
        .published_frames(pubs),.dropped_frames(drops),.invalid_frames(invalids),
        .write_errors(we),.read_errors(re),.replayed_frames(frames),.status(status),
        .first_fault(first_fault_ddr),
        .awaddr(awaddr),.awlen(awlen),.awvalid(awvalid),.awready(awready),
        .wdata(wdata),.wlast(wlast),.wvalid(wvalid),.wready(wready),
        .bresp(bresp),.bid(bid),.bvalid(bvalid),.bready(bready),
        .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
        .rdata(rdata),.rresp(rresp),.rid(rid),.rlast(rlast),.rvalid(rvalid),.rready(rready));
    wire [161:0] replay_word;
    frame_async_fifo #(.WIDTH(162),.ADDR_BITS(FIFO_BITS)) replay_fifo(
        .wclk(ddr_clk),.wrst_n(drst_n),.wvalid(rv),.wready(rr),.wdata({rf,rs,rl,rd}),
        .rclk(user_clk),.rrst_n(urst_n),.rvalid(o_valid),.rready(o_ready),.rdata(replay_word));
    assign o_data=replay_word[127:0];assign o_last=replay_word[128];
    assign o_sof=replay_word[129];assign o_frame_id=replay_word[161:130];
    frame_status_cdc sc(.sclk(ddr_clk),.srst_n(drst_n),
        .status({frames,re,we,invalids,drops,pubs,status}),
        .dclk(user_clk),.drst_n(urst_n),.sampled(counters));
    frame_status_cdc #(.WIDTH(256)) fault_cdc(.sclk(ddr_clk),.srst_n(drst_n),
        .status(first_fault_ddr),.dclk(user_clk),.drst_n(urst_n),.sampled(first_fault));
endmodule
