`timescale 1ns/1ps
module tb_mode8_quad;
    localparam W=64,H=40,N=640,WORDS=16;
    reg clk=0,rst_n=0,v=0,sof=0,eol=0;
    reg [127:0] rgb=0; reg [3:0] mode=8;
    wire ov,os,oe; wire [3:0] active; wire [127:0] out_rgb;
    wire [31:0] ge,he,me,se;
    reg [127:0] in_mem[0:N-1],exp_mem[0:N-1]; integer i,n=0,mism=0;
    always #5 clk=~clk;
    image_preprocess_quad #(.IMAGE_WIDTH(W),.IMAGE_HEIGHT(H),.RUNTIME_MODE(1)) dut(
        .clk(clk),.rst_n(rst_n),.i_valid(v),.i_sof(sof),.i_eol(eol),.i_rgb(rgb),.i_mode(mode),
        .active_mode(active),.o_valid(ov),.o_sof(os),.o_eol(oe),.o_rgb(out_rgb),
        .gaussian_errors(ge),.histogram_errors(he),.median_errors(me),.sobel_errors(se));
    always @(posedge clk) if(ov) begin
        if(out_rgb!==exp_mem[n]) begin mism=mism+1; if(mism<5)$display("MISMATCH %0d",n); end
        if(os !== (n==0) || oe !== ((n%WORDS)==WORDS-1)) $fatal(1,"marker %0d",n);
        n=n+1;
    end
    initial begin
        $readmemh("lowlight_in.hex",in_mem);$readmemh("lowlight_exp.hex",exp_mem);
        repeat(5) @(posedge clk); rst_n=1;
        for(i=0;i<N;i=i+1) begin @(negedge clk);v=1;sof=(i==0);eol=((i%WORDS)==WORDS-1);rgb=in_mem[i]; end
        @(negedge clk);v=0;sof=0;eol=0;rgb=0;repeat(8) @(posedge clk);
        if(n!=N || mism!=0 || active!==8 || ge!=0 || me!=0 || se!=0)$fatal(1,"mode8 quad failed out=%0d mism=%0d active=%0d errors=%0d/%0d/%0d",n,mism,active,ge,me,se);
        $display("PASS mode8 integrated quad: words=%0d pixels=%0d",N,N*4);$finish;
    end
endmodule
