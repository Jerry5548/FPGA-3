
/*******************************MILIANKE*******************************
*Company : MiLianKe Electronic Technology Co., Ltd.
*WebSite:https://www.milianke.com
*TechWeb:https://www.uisrc.com
*tmall-shop:https://milianke.tmall.com
*jd-shop:https://milianke.jd.com
*taobao-shop1: https://milianke.taobao.com
*Create Date: 2023/08/07
*Module Name:key
*File Name:key.v
*Description: 
*The reference demo provided by Milianke is only used for learning. 
*We cannot ensure that the demo itself is free of bugs, so users 
*should be responsible for the technical problems and consequences
*caused by the use of their own products.
*Copyright: Copyright (c) MiLianKe
*All rights reserved.
*Revision: 1.0
*Signal description
*1) I_ input
*2) O_ output
*3) IO_ input output
*4) S_ system internal signal
*5) _n activ low
*6) _dg debug signal 
*7) _r delay or register
*8) _s state mechine
*********************************************************************/
/*********ui_cfg_imx415 IIC控制模块 ***********
--版本�?1.0
*********************************************************************/

module ui_cfg_imx415#
(
parameter	 CLK_DIV  = 16'd999
)
(
input  wire             I_clk,  //系统时钟输入
input  wire             I_rst_n,  //系统复位输入
input  wire [1:0]       I_cam_mode, // �ֱ���ģʽ: 0=1080p, 1=4K, 2=720p
input  wire             I_ae_req,//摄像头AE控制
input  wire	 [7:0] 		I_ae_data,
output wire             O_cam_scl, //I2C总线，SCL时钟
inout  wire             IO_cam_sda, //I2C总线，SDA数据
output reg              O_cfg_done, //配置完成
output reg              O_ae_cfg_done,
output wire             O_bus_error          // I2C NACK ָʾ
);	

localparam CAM_ID = 8'h34;		//器件地址 

wire 		ic_busy			; 	//I2C控制器忙信号 
wire   		O_iic_bus_error	;
assign      O_bus_error = O_iic_bus_error;

wire [23:0] REG_DATA_REG	; 	//寄存器数�?
wire [7 :0] REG_SIZE_REG	;	//寄存器数�?

wire [1 :0] REG_SIZE_ST = 2'd2; //待机寄存器数�?
wire [2 :0] REG_SIZE_AE = 3'd1; //AE寄存器数�?(only GAIN_PGC_0)


reg  		O_cfg_done_r;	//待机模式寄存器配�?完成信号
reg  		iic_req		;	//请求操作I2C控制器信�?
reg  [7:0] 	rst_cnt		;	//复位延时计数
reg  [21:0] cnt			;	//待机模式寄存器延时配�?计数

reg  [31:0] wr_data		;   //写数�?寄存�?

reg  [7 :0] reg_index	;   //寄存索引            
                                             
reg [23:0] 	REG_DATA;    	//寄存器数�?
reg [7:0]  	REG_SIZE;    	//寄存器数�?

reg [23:0] 	REG_DATA_ST;  	//待机寄存器数�?
reg [23:0] 	REG_DATA_AE;  	//AE寄存器数�?

reg  [1 :0] TS_S = 2'd0; 	//状态机寄存�?

// --- mode switch detection ---
reg  [1:0]  cam_mode_r;      // ��һ�ĵ� mode�����ڱ��ؼ��
wire        mode_changed = (I_cam_mode != cam_mode_r) & rst_cnt[7]; // ģʽ�л�����



//内部计数器产生一�?延迟复位
always@(posedge I_clk or negedge I_rst_n)  
    if(I_rst_n == 1'b0) //复位初�?�化寄存�?
        rst_cnt<= 8'd0; 
    else if(rst_cnt[7] == 1'b0)
       rst_cnt <= rst_cnt + 1'b1; 
    else 
       rst_cnt <= rst_cnt; 

// --- cam_mode ���� ---
always@(posedge I_clk or negedge I_rst_n)
    if(I_rst_n == 1'b0)
        cam_mode_r <= 2'd0;
    else
        cam_mode_r <= I_cam_mode;
	   
always@(posedge I_clk or negedge I_rst_n)  begin
    if(I_rst_n == 1'b0) //复位初�?�化寄存�?
         cnt <= 0;
    else if(cnt == 1000_000)
         cnt <= 0;
    else if(O_cfg_done == 1'b1)
         cnt <= cnt + 1;
    else if(O_cfg_done_r == 1'b1)
         cnt <= cnt;
end

always@(posedge I_clk or negedge I_rst_n)begin
    if(I_rst_n == 1'b0)begin
		REG_SIZE <= 8'b0;
		REG_DATA <= 24'b0;
	end
	else if(O_cfg_done == 1'b0)begin
		REG_SIZE <= REG_SIZE_REG;
		REG_DATA <= REG_DATA_REG;
	end
	else if(O_cfg_done == 1'b1 && O_cfg_done_r == 1'b0)begin
		REG_SIZE <= REG_SIZE_ST;
		REG_DATA <= REG_DATA_ST;
	end
	else if(O_cfg_done == 1'b1 && O_cfg_done_r == 1'b1)begin
		REG_SIZE <= REG_SIZE_AE;
		REG_DATA <= REG_DATA_AE;
	end
	else begin
		REG_SIZE <= 8'b0;
		REG_DATA <= 24'b0;
	end
end

always@(posedge I_clk ) begin 
    if(rst_cnt[7] == 1'b0)begin //复位初�?�化寄存�?
        reg_index  <= 9'd0;
        iic_req    <= 1'b0;
        wr_data    <= 32'd0;
        O_cfg_done <= 1'b0;
        O_cfg_done_r <= 1'b0;
        O_ae_cfg_done <= 1'b1;
        TS_S     <= 2'd0;    
    end
    else begin
        // --- ģʽ�л�: ���������������� (STANDBY����д�Ĵ���������) ---
        if(mode_changed) begin
            reg_index    <= 9'd0;
            O_cfg_done   <= 1'b0;
            O_cfg_done_r <= 1'b0;
            O_ae_cfg_done<= 1'b1;
            iic_req      <= 1'b0;
            TS_S         <= 2'd0;
        end
        else
        case(TS_S)
        0:if(reg_index == REG_SIZE && O_cfg_done == 1'b0) begin//如果配置完成
            O_cfg_done <= 1'b1;       //设置 cfg_done标准
        end 
        else if(reg_index == REG_SIZE && O_cfg_done == 1'b1 && O_cfg_done_r == 1'b0) begin//如果配置完成
            O_cfg_done_r <= 1'b1;       //设置 cfg_done标准
        end 
        else if(cnt== 1000_000)begin
            O_cfg_done_r <= 0;
            reg_index   <= 0;
        end
		else if(reg_index == REG_SIZE && O_cfg_done == 1'b1 && O_cfg_done_r == 1'b1) begin//如果配置完成
            O_ae_cfg_done <= 1'b1;       //设置 cfg_done标准
        end 
        else if(I_ae_req && O_ae_cfg_done)begin  // ���� AE ����ʱ��Ӧ�����󣬷�ֹ����
            O_ae_cfg_done <= 0;
            reg_index   <= 0;
        end
        else if((O_cfg_done&O_cfg_done_r&O_ae_cfg_done) == 1'b0)
            TS_S <= 2'd1;           //下一�?状�?
        1:if(!iic_busy)begin        //当总线非忙，才�?以操作I2C控制�?
            iic_req  <= 1'b1;       //请求操作I2C控制�?
			wr_data[7  :0] <= CAM_ID;           //器件地址   
			wr_data[15 :8] <= REG_DATA[23:16];  //寄存器地址-�?8bit    
			wr_data[23:16] <= REG_DATA[15: 8];  //寄存器地址-�?8bit  
            wr_data[31:24] <= REG_DATA[7 : 0];  //寄存器数�?
            TS_S      <= 2'd2; //下一�?状�?
        end    
        2:if(iic_busy)begin
             iic_req  <= 1'b0;  //重置 iic_req =0
             TS_S     <= 2'd3;  //下一�?状�?
        end
        3:if(!iic_busy)begin  //当总线非忙，才�?以操作I2C控制�? 
			reg_index<= reg_index + 1'b1;//寄存器索引加1
			TS_S    <= 2'd0;//回到初�?�状�?
        end 
        endcase
   end
end

//例化I2C控制模块
ui_i2c#
(
	.WMEN_LEN	(4		),     //最大支持一次写�?4BYTE(包含器件地址)
	.RMEN_LEN	(1		),     //最大支持一次�?�出1BYTE
	.CLK_DIV	(CLK_DIV) 	   //100KHZ I2C总线时钟
)
X_ui_i2c
(
	.I_clk			(I_clk			),//系统时钟
	.I_rstn			(rst_cnt[7]		),//系统复位
	.O_iic_scl		(O_cam_scl		),//I2C SCL总线时钟
	.IO_iic_sda		(IO_cam_sda		),//I2C SDA数据总线
	.I_wr_data		(wr_data		),//写数�?寄存�?
	.I_wr_cnt		(8'd4			),//需要写的数据BYTES
	.O_rd_data		(				),//读数�?寄存�?
	.I_rd_cnt		(8'd0			),//需要�?�的数据BYTES
	.I_iic_mode		(1'b0			),//读模式�?�置
	.I_iic_req		(iic_req		),//I2C控制器�?�求
	.O_iic_busy		(iic_busy		),//I2C控制器忙
	.O_iic_bus_error(O_iic_bus_error)
);


//例化CAM的寄存器配置�?
ui_imx415reg X_ui_imx415reg
(
	.MODE		(I_cam_mode		),  //�ֱ���ģʽ
	.REG_SIZE	(REG_SIZE_REG	),  //寄存器数�?
	.REG_INDEX	(reg_index		),    //寄存索引
	.REG_DATA	(REG_DATA_REG	)   //寄存器数�?
);  

always@(*)
   case(reg_index)
		0:		REG_DATA_ST = {16'h3000, 8'h00}; 
		1:		REG_DATA_ST = {16'h3002, 8'h00}; 
		default:REG_DATA_ST = {16'h0000, 8'h00};
   endcase

always@(*)
   case(reg_index)
		0:		REG_DATA_AE = {16'h3090, I_ae_data}; // GAIN_PGC_0 only (PGC_1/2/3 for HDR, unused)
		default:REG_DATA_AE = {16'h0000, 8'h00};
   endcase

endmodule
