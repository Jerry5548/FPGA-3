`timescale 1ns/1ps
// Existing AFC03 DDR3 controller is clocked on dfi_clk internally. The
// only crossings to PCIe user_clk are the frame FIFOs and status mailbox.
module pcie_ddr_camera(
    input wire ref_clk,user_clk,reset_n,enable,
    input wire i_valid,input wire [127:0] i_data,input wire i_sof,i_eol,i_last,
    output wire o_valid,input wire o_ready,output wire [127:0] o_data,
    output wire o_sof,o_last,output wire [31:0] o_frame_id,
    output wire ready,output wire [31:0] ddr_status,
    output wire [31:0] capture_fifo_drops,output wire [223:0] counters,
    output wire [31:0] startup_skipped_frames,
    output wire [255:0] first_fault,
    output wire [13:0] ddr_addr,output wire [2:0] ddr_ba,
    output wire ddr_cke,ddr_odt,ddr_cs_n,ddr_ras_n,ddr_cas_n,ddr_we_n,
    output wire ddr_ck_p,ddr_ck_n,ddr_reset_n,
    inout wire [1:0] ddr_dm,inout wire [15:0] ddr_dq,
    inout wire [1:0] ddr_dqs_p,ddr_dqs_n
);
    // Stretch asynchronous application/PERST reset for DDR PHY and MC.
    // Both controller and AXI requester reset together, including soft reset.
    reg [7:0] release_count;
    reg controller_rst_n;
    always @(posedge ref_clk or negedge reset_n) begin
        if(!reset_n) begin release_count<=0;controller_rst_n<=0;end
        else if(!controller_rst_n) begin
            if(&release_count) controller_rst_n<=1;
            else release_count<=release_count+1'b1;
        end
    end
    wire ddr_clk,cal_done,pll_locked,phy_rst_n;
    wire [7:0] cal_error,cal_step;
    (* ASYNC_REG="TRUE" *) reg [1:0] cal_sync,lock_sync,phy_sync,controller_rst_sync;
    (* ASYNC_REG="TRUE" *) reg [7:0] error_sync1,error_sync2,step_sync1,step_sync2;
    always @(posedge user_clk or negedge reset_n) begin
        if(!reset_n) begin
            cal_sync<=0;lock_sync<=0;phy_sync<=0;controller_rst_sync<=0;
            error_sync1<=0;error_sync2<=0;step_sync1<=0;step_sync2<=0;
        end
        else begin
            cal_sync<={cal_sync[0],cal_done};lock_sync<={lock_sync[0],pll_locked};
            phy_sync<={phy_sync[0],phy_rst_n};
            controller_rst_sync<={controller_rst_sync[0],controller_rst_n};
            error_sync1<=cal_error;error_sync2<=error_sync1;
            step_sync1<=cal_step;step_sync2<=step_sync1;
        end
    end
    assign ready=cal_sync[1] && lock_sync[1] && phy_sync[1];
    // Status values cross from the DDR reference domain to PCIe user_clk.
    // Calibration fields are stable after calibration, while reset release is
    // explicitly synchronized before it is exposed in the AXI status register.
    assign ddr_status={error_sync2,step_sync2,12'd0,controller_rst_sync[1],
                       phy_sync[1],lock_sync[1],cal_sync[1]};
    wire [27:0] awaddr,araddr;wire [7:0] awlen,arlen;
    wire awvalid,awready,wvalid,wready,wlast,bvalid,bready;
    wire arvalid,arready,rvalid,rready,rlast;
    wire [127:0] wdata,rdata;wire [1:0] bresp,rresp;wire [3:0] bid,rid;
    // Four 8 MiB slots occupy [0,32 MiB), within the 28-bit DDR address space.
    ddr_camera_frame_path #(.SKIP_STARTUP_FRAME(1),.SLOT_COUNT(4)) path(
        .user_clk(user_clk),.ddr_clk(ddr_clk),
        .arst_n(reset_n && controller_rst_n && phy_rst_n && cal_done),
        .capture_enable(enable && ready),
        .i_valid(i_valid),.i_data(i_data),.i_sof(i_sof),.i_eol(i_eol),.i_last(i_last),
        .o_valid(o_valid),.o_ready(o_ready),.o_data(o_data),
        .o_sof(o_sof),.o_last(o_last),.o_frame_id(o_frame_id),
        .capture_fifo_drops(capture_fifo_drops),.counters(counters),
        .startup_skipped_frames(startup_skipped_frames),
        .first_fault(first_fault),
        .awaddr(awaddr),.awlen(awlen),.awvalid(awvalid),.awready(awready),
        .wdata(wdata),.wlast(wlast),.wvalid(wvalid),.wready(wready),
        .bresp(bresp),.bid(bid),.bvalid(bvalid),.bready(bready),
        .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
        .rdata(rdata),.rresp(rresp),.rid(rid),.rlast(rlast),.rvalid(rvalid),.rready(rready));
    ui_ddr u_ddr(
        .sys_rst_n(controller_rst_n),.sys_clk(ref_clk),
        .ddr_ck_p(ddr_ck_p),.ddr_ck_n(ddr_ck_n),.ddr_reset_n(ddr_reset_n),
        .ddr_cke(ddr_cke),.ddr_odt(ddr_odt),.ddr_cs_n(ddr_cs_n),
        .ddr_ras_n(ddr_ras_n),.ddr_cas_n(ddr_cas_n),.ddr_we_n(ddr_we_n),
        .ddr_ba(ddr_ba),.ddr_addr(ddr_addr),.ddr_dqs_p(ddr_dqs_p),
        .ddr_dqs_n(ddr_dqs_n),.ddr_dq(ddr_dq),.ddr_dm(ddr_dm),
        .dfi_clk(ddr_clk),.pll_locked(pll_locked),.ddrphy_rst_n(phy_rst_n),
        .ddr_init_cal_done(cal_done),.ddr_init_cal_err(cal_error),.ddr_init_cal_step(cal_step),
        .axi_aclk(ddr_clk),.axi_aresetn(phy_rst_n),
        .axi_awid(4'd0),.axi_awaddr(awaddr),.axi_awlen(awlen),.axi_awsize(3'd4),
        .axi_awburst(2'b01),.axi_awlock(1'b0),.axi_awcache(4'd0),
        .axi_awprot(3'd0),.axi_awqos(4'd0),.axi_awvalid(awvalid),.axi_awready(awready),
        .axi_wdata(wdata),.axi_wstrb(16'hffff),.axi_wlast(wlast),
        .axi_wvalid(wvalid),.axi_wready(wready),.axi_bid(bid),.axi_bresp(bresp),
        .axi_bvalid(bvalid),.axi_bready(bready),
        .axi_arid(4'd0),.axi_araddr(araddr),.axi_arlen(arlen),.axi_arsize(3'd4),
        .axi_arburst(2'b01),.axi_arlock(1'b0),.axi_arcache(4'd0),
        .axi_arprot(3'd0),.axi_arqos(4'd0),.axi_arvalid(arvalid),.axi_arready(arready),
        .axi_rid(rid),.axi_rdata(rdata),.axi_rresp(rresp),.axi_rlast(rlast),
        .axi_rvalid(rvalid),.axi_rready(rready),
        .pzq_cal_done_i(1'b0),
        .user_update(1'b0),.user_ram_addr(8'd0),.user_ram_wr_en(1'b0),
        .user_ram_rd_en(1'b0),.user_ram_wr_data(32'd0),.uart_rxd(1'b1));
endmodule
