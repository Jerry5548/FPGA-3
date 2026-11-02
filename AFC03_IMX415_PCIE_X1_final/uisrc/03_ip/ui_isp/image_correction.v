/*****************************************************************
Company : MiLianKe Electronic Technology Co., Ltd.
WebSite:https://www.milianke.com
TechWeb:https://www.uisrc.com
tmall-shop:https://milianke.tmall.com
jd-shop:https://milianke.jd.com
taobao-shop: https://milianke.taobao.com
Description: 
The reference demo provided by Milianke is only used for learning. 
We cannot ensure that the demo itself is free of bugs, so users 
should be responsible for the technical problems and consequences
caused by the use of their own products.
@Author      :   XiaoQingquan 
@Time        :   2024/12 
version:     :   1.0
@Description :   æ¶ˆå‡å›¾åƒçš„å?šä½™çš„ï???
*****************************************************************/

module image_correction #(
    parameter DATA_WIDTH   = 40,
    parameter TDEST_WIDTH  = 10
)(
    input                          I_clk   ,
    input                          I_rst_n ,

    // Runtime crop parameters (from top-level registers)
    input   [14:0]                 I_v_start,   // first valid line (exclusive, v_cnt > I_v_start)
    input   [14:0]                 I_v_end  ,   // last  valid line (exclusive, v_cnt < I_v_end)
    input   [14:0]                 I_h_end  ,   // horizontal beats per line (exclusive, h_cnt < I_h_end)
    // Resolution table:
    //   1920¡Á1080: v_start=19, v_end=1100, h_end=481
    //   3840¡Á2160: v_start=36, v_end=2197, h_end=961
    //   1280¡Á720:  v_start=35, v_end=756,  h_end=321

    input   [DATA_WIDTH - 1:0]     I_raw_tdata ,
    input   [TDEST_WIDTH - 1:0]    I_raw_tdest ,
    input                          I_raw_tlast ,
    input                          I_raw_tvalid,
    input                          I_raw_tuser ,
    output                         I_raw_tready,

    // Êä³öRAW10Êı¾İ
    output     [DATA_WIDTH - 1:0]     O_raw_tdata ,
    output                            O_raw_tlast ,
    output reg [TDEST_WIDTH - 1:0]    O_raw_tdest ,
    output                            O_raw_tvalid,
    output                            O_raw_tuser ,
    input                             O_raw_tready
);

    reg                        I_raw_tvalid_d; 
    reg                        I_raw_tlast_d ; 
    reg    [DATA_WIDTH - 1:0]  I_raw_tdata_r;
    reg    [14:0]              h_cnt,v_cnt;
    wire                       V_valid,H_valid;
    wire                       tuser;

    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n )begin
            I_raw_tvalid_d <= 0;
            I_raw_tlast_d  <= 0;
            I_raw_tdata_r  <= 0;
            O_raw_tdest    <= 0;
        end
        else begin
            I_raw_tvalid_d <= I_raw_tvalid;
            I_raw_tlast_d  <= I_raw_tlast; 
            I_raw_tdata_r  <= I_raw_tdata;
            O_raw_tdest    <= I_raw_tdest;
        end
    end

    // Line counter
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n || I_raw_tuser)
            v_cnt <= 0;
        else if(I_raw_tlast_d)
            v_cnt <= v_cnt + 1;
    end

    assign V_valid = (v_cnt > I_v_start) && (v_cnt < I_v_end);

    // Pixel beat counter
    always @(posedge I_clk or negedge I_rst_n) begin
        if(!I_rst_n || I_raw_tuser)
            h_cnt <= 0;
        else
            h_cnt <= I_raw_tvalid_d ? (I_raw_tlast_d ? 0 : h_cnt + 1) : h_cnt;
    end

    assign H_valid = (h_cnt < I_h_end) && (h_cnt > 0);

    assign tuser = (h_cnt == 1) && (v_cnt == I_v_start + 15'd1) && I_raw_tvalid_d;

    assign O_raw_tdata  = V_valid && H_valid ? I_raw_tdata_r : {DATA_WIDTH{1'b0}};
    assign I_raw_tready = O_raw_tready;
    assign O_raw_tvalid = H_valid && V_valid && I_raw_tvalid_d;
    assign O_raw_tlast  = V_valid && (h_cnt == I_h_end - 15'd1) && I_raw_tvalid_d;
    assign O_raw_tuser  = tuser;

endmodule