`timescale 1ps/1ps
// Only the deserializer is stubbed. Delay behavior uses Anlogic's actual
// PH1_LOGIC_DYNAMIC_IDELAY simulation model, including enable/bypass semantics.
module PH1_LOGIC_IDDRx2 #(parameter ASYNCRST="ENABLE")(
    output wire q3,q2,q1,q0,input wire pclk,sclk,d,rst);
    assign {q3,q2,q1,q0}=4'b0;
endmodule
module tb_ph1a_delay;
    reg clk=0,rst_n=0,serial=0,load=0;
    reg [5:0] code=0;
    always #4000 clk=~clk;
    wire [7:0] data;
    wire valid;
    csi_rx_hs_data_phy #(.DEVICE("PH1A")) dut(
        .I_rxclk(clk),.I_rxclk_div_x2(clk),.I_rxclk_div_x4(clk),
        .I_reset_n(rst_n),.I_hs_data_p(serial),
        .I_delay_value(code),.I_delay_vaild(load),
        .O_rx_data(data),.O_delay_data_val(valid));
    task select(input integer value);
        begin
            @(negedge clk);code=value;load=1;
            @(negedge clk);load=0;
            #20000;
        end
    endtask
    task verify_delay(input integer expected);
        time start_time;
        begin
            serial=0;#5000;
            start_time=$time;serial=1;
            @(posedge dut.w_hs_data_dalay);
            if($time-start_time != expected)
                $fatal(1,"Rising delay %0d ps, expected %0d ps",$time-start_time,expected);
            #5000;start_time=$time;serial=0;
            @(negedge dut.w_hs_data_dalay);
            if($time-start_time != expected)
                $fatal(1,"Falling delay %0d ps, expected %0d ps",$time-start_time,expected);
        end
    endtask
    initial begin
        #20000;rst_n=1;
        select(20); verify_delay(170+20*23);
        select(3); verify_delay(170+3*23);
        code=31;#20000; verify_delay(170+3*23); // no load: keep previous tap
        rst_n=0;#20000;rst_n=1;#20000;
        verify_delay(170+16*23);
        $display("PASS PH1A vendor IDELAY: both edges delayed after load pulse, code held, reset midpoint");
        $finish;
    end
    initial begin #1000000; $fatal(1,"Delay watchdog");end
endmodule
