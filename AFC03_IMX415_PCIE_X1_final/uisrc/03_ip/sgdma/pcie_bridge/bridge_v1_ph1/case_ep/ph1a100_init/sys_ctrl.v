//////////////////////////////////////////////////////////////
//  Copyright(c) 2011-2024 Anlogic, Inc.
//  All Right Reserved.
//////////////////////////////////////////////////////////////
//  Company       : Anlogic
//  Filename      : sys_ctrl.v
//  Author        : bswang - bingsong.wang@anlogic.com
//  Last Modified : 2025-03-25 17:45:07
//  Create        : 2024-07-04 11:08:51
//  Description   : 
//   
///////////////////////////////////////////////////////////////

module sys_ctrl#(
	parameter 		DLY = 1
	)(/*AUTOARG*/
	input   wire    core_rst_n,
	input   wire    core_clk,	
	input   wire  	aux_clk,
	//input   wire    smlh_link_up,	
	//output  wire    lock, 
	output  wire    core_clk_pll,
	output  wire    core_rst_n_pll
 );
	
reg                 core_rst_n_d1 = 0,core_rst_n_d2= 0;
wire                core_clk_r;
wire                lock;
reg [17:0]          unlock_cnt=0;   //2^18 * 40ns by auxclk, so 10ms

reg	  [7:0]			init_cnt=0;
reg                 unlock_rst_reg=1'b1;
reg  [7:0]          unlock_rst_reg_wide=8'hff;
reg                 unlock_rst=1'b1;

reg		[9:0]		lock_cnt=0;	//2^10 *40ns by auxclk ,so 40us

reg     [2:0]       lock_reg=3'b0;
reg                 lock_fall=1'b0;
reg     [7:0]       lock_fall_cnt=8'b0;     

sys_pll u_sys_pll(
 	.refclk(core_clk),
	.reset(unlock_rst|(~core_rst_n)),
	.lock(lock),
	.clk0_out(),
	.clk1_out(core_clk_r)
);
PH1_LOGIC_BUFG u_bufg_clk(
	.i(core_clk_r),
	.o(core_clk_pll)
);


always @ ( posedge aux_clk )
begin
    lock_reg    <= #DLY { lock_reg[1:0], lock };
    lock_fall   <= #DLY ( lock_reg[2:1] == 2'b10 ) ? 1'b1 : 1'b0;
    
 	if ( lock_fall )
        lock_fall_cnt <= #DLY lock_fall_cnt + 1'b1;
end

always @ ( posedge aux_clk )
begin
 	if ( init_cnt < 8'hff )
        init_cnt <= #DLY init_cnt + 1'b1;
    else
        init_cnt <= #DLY init_cnt;
end

always @ ( posedge aux_clk or negedge core_rst_n )
begin
	if ( !core_rst_n )
    	unlock_cnt <= #DLY 'b0;
 	else if ( !lock_reg[2] )
        unlock_cnt <= #DLY unlock_cnt + 1'b1;
    else
        unlock_cnt <= #DLY 'b0;
end

always @ ( posedge aux_clk )
begin
	if ( unlock_cnt == 18'h3ffff )
        unlock_rst_reg <= #DLY 1'b1;
    else
        unlock_rst_reg <= #DLY 1'b0;
end

//shift with 8 cycles
always @ ( posedge aux_clk )
begin
    unlock_rst_reg_wide[7:0] <= #DLY { unlock_rst_reg_wide[6:0],unlock_rst_reg };
end

//widen to 8 cycles
always @ ( posedge aux_clk )
begin
	if ( init_cnt < 8'hff )
		unlock_rst <= #DLY 1'b1;
    else
		unlock_rst <= #DLY |unlock_rst_reg_wide[7:0];
end


always @(posedge aux_clk)
begin
	if(!lock_reg[2]) 
		lock_cnt <= #DLY 'b0;
	else if ( lock_cnt < 10'h3ff )
		lock_cnt <= #DLY lock_cnt + 1'b1;
	else
		lock_cnt <= #DLY lock_cnt;
end

always @(posedge aux_clk)
begin
    core_rst_n_d1 <= #DLY &lock_cnt;
    core_rst_n_d2 <= #DLY core_rst_n_d1;
end

reg		sync_rst_n_d1= 0,sync_rst_n_d2= 0;

always @(posedge core_clk_pll)
begin
    sync_rst_n_d1 <= #DLY core_rst_n_d2;
    sync_rst_n_d2 <= #DLY sync_rst_n_d1;
end

assign core_rst_n_pll = sync_rst_n_d2;

endmodule



