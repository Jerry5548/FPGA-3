`timescale 1ns/1ps
module tb_lowlight_only;
    localparam N=640;
    reg clk=0,rst_n=0,v=0,sof=0,eol=0;
    reg [127:0] rgb=0;
    wire ov,os,oe; wire [127:0] out_rgb;
    lowlight_enhance_stream dut(.clk(clk),.rst_n(rst_n),.i_valid(v),.i_sof(sof),.i_eol(eol),
        .i_rgb(rgb),.o_valid(ov),.o_sof(os),.o_eol(oe),.o_rgb(out_rgb));
    reg [127:0] in_mem[0:N-1],exp_mem[0:N-1];
    integer i,n=0,mism=0;
    always #5 clk=~clk;
    always @(posedge clk) if(ov) begin
        if(out_rgb!==exp_mem[n]) begin
            mism=mism+1; if(mism<5)$display("MISMATCH %0d got=%h exp=%h",n,out_rgb,exp_mem[n]);
        end
        if(os !== (n==0) || oe !== ((n%16)==15)) $fatal(1,"marker mismatch %0d",n);
        n=n+1;
    end
    initial begin
        $readmemh("lowlight_in.hex",in_mem);$readmemh("lowlight_exp.hex",exp_mem);
        repeat(5) @(posedge clk); rst_n=1;
        for(i=0;i<N;i=i+1) begin
            @(negedge clk);v=1;sof=(i==0);eol=((i%16)==15);rgb=in_mem[i];
        end
        @(negedge clk);v=0;sof=0;eol=0;rgb=0;
        repeat(5) @(posedge clk);
        if(n!=N || mism!=0)$fatal(1,"mode8 only failed out=%0d mism=%0d",n,mism);
        $display("PASS mode8 standalone: words=%0d pixels=%0d",N,N*4);$finish;
    end
endmodule
