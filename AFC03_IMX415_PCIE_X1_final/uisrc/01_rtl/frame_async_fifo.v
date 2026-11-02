`timescale 1ns/1ps
// Dual-clock FIFO, Gray-pointer CDC, synchronous ERAM read with held head.
// Both resets must assert together; deassert each reset in its own clock.
module frame_async_fifo #(
    parameter integer WIDTH=163, ADDR_BITS=12
)(
    input wire wclk,wrst_n,input wire wvalid,output wire wready,
    input wire [WIDTH-1:0] wdata,
    input wire rclk,rrst_n,output reg rvalid,input wire rready,
    output wire [WIDTH-1:0] rdata
);
    localparam integer DEPTH=1<<ADDR_BITS;
    (* ram_style="bram(min_area)" *) reg [WIDTH-1:0] mem[0:DEPTH-1];
    reg [ADDR_BITS:0] wbin,wgray,rbin,rgray;
    (* ASYNC_REG="TRUE" *) reg [ADDR_BITS:0] rg1,rg2,wg1,wg2;
    reg full;
    reg [WIDTH-1:0] head;
    wire write_fire=wvalid && wready;
    wire [ADDR_BITS:0] wn=wbin+write_fire;
    wire [ADDR_BITS:0] wgray_toggle;
    assign wgray_toggle[0]=write_fire && !wbin[0];
    genvar wi;
    generate for(wi=1;wi<ADDR_BITS;wi=wi+1) begin: gen_wgray_toggle
        assign wgray_toggle[wi]=write_fire && !wbin[wi] && (&wbin[wi-1:0]);
    end endgenerate
    // On binary increment, Gray code changes exactly one bit: the position
    // following the least-significant zero. Express the toggle directly to
    // avoid a full binary increment followed by a Gray XOR on the CDC pointer.
    assign wgray_toggle[ADDR_BITS]=write_fire && (&wbin[ADDR_BITS-1:0]);
    wire [ADDR_BITS:0] wgn=wgray^wgray_toggle;
    wire pointer_empty=(rgray==wg2);
    wire fetch=(!rvalid || rready) && !pointer_empty;
    wire [ADDR_BITS:0] rn=rbin+fetch;
    wire [ADDR_BITS:0] rgray_toggle;
    assign rgray_toggle[0]=fetch && !rbin[0];
    genvar ri;
    generate for(ri=1;ri<ADDR_BITS;ri=ri+1) begin: gen_rgray_toggle
        assign rgray_toggle[ri]=fetch && !rbin[ri] && (&rbin[ri-1:0]);
    end endgenerate
    assign rgray_toggle[ADDR_BITS]=fetch && (&rbin[ADDR_BITS-1:0]);
    wire [ADDR_BITS:0] rgn=rgray^rgray_toggle;
    assign wready=!full;
    assign rdata=head;
    always @(posedge wclk) if(write_fire) mem[wbin[ADDR_BITS-1:0]]<=wdata;
    always @(posedge rclk) if(fetch) head<=mem[rbin[ADDR_BITS-1:0]];
    always @(posedge wclk or negedge wrst_n) begin
        if(!wrst_n) begin wbin<=0;wgray<=0;full<=0;rg1<=0;rg2<=0;end
        else begin
            rg1<=rgray;rg2<=rg1;wbin<=wn;wgray<=wgn;
            full<=(wgn=={~rg2[ADDR_BITS:ADDR_BITS-1],rg2[ADDR_BITS-2:0]});
        end
    end
    always @(posedge rclk or negedge rrst_n) begin
        if(!rrst_n) begin rbin<=0;rgray<=0;rvalid<=0;wg1<=0;wg2<=0;end
        else begin
            wg1<=wgray;wg2<=wg1;
            rbin<=rn;rgray<=rgn;
            if(fetch) rvalid<=1;
            else if(rready) rvalid<=0;
        end
    end
endmodule

module frame_reset_sync(
    input wire clk,arst_n,output wire rst_n
);
    (* ASYNC_REG="TRUE" *) reg [3:0] sync;
    always @(posedge clk or negedge arst_n)
        if(!arst_n) sync<=0;
        else sync<={sync[2:0],1'b1};
    assign rst_n=sync[3];
endmodule

// Handshaken multi-bit status mailbox. Payload remains stable until ACK.
module frame_status_cdc #(parameter integer WIDTH=224)(
    input wire sclk,srst_n,input wire [WIDTH-1:0] status,
    input wire dclk,drst_n,output reg [WIDTH-1:0] sampled
);
    reg [WIDTH-1:0] held;
    reg req,ack;
    (* ASYNC_REG="TRUE" *) reg [1:0] ack_sync,req_sync;
    always @(posedge sclk or negedge srst_n) begin
        if(!srst_n) begin held<=0;req<=0;ack_sync<=0;end
        else begin
            ack_sync<={ack_sync[0],ack};
            if(ack_sync[1]==req) begin held<=status;req<=!req;end
        end
    end
    always @(posedge dclk or negedge drst_n) begin
        if(!drst_n) begin req_sync<=0;ack<=0;sampled<=0;end
        else begin
            req_sync<={req_sync[0],req};
            if(req_sync[1]!=ack) begin sampled<=held;ack<=req_sync[1];end
        end
    end
endmodule
