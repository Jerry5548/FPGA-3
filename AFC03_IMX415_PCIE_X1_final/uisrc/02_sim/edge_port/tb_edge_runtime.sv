`timescale 1ns/1ps
module tb_edge_runtime;
    parameter W=8,H=4,FRAMES=99;
    localparam WORDS=W*H/4,N=WORDS*FRAMES;
    reg clk=0,src_clk=0,rst_n=0,v=0,s=0,e=0;
    reg [127:0] rgb=0;
    reg [2:0] requested=4;
    wire [2:0] pending,active;
    wire ov,os,oe;wire [127:0] od;wire [31:0] gerr,herr;
    assign pending=requested; // PCIe configuration shares the processing clock
    image_preprocess_quad #(.IMAGE_WIDTH(W),.IMAGE_HEIGHT(H),.MODE(4),.RUNTIME_MODE(1)) dut(
        .clk(clk),.rst_n(rst_n),.i_valid(v),.i_sof(s),.i_eol(e),.i_rgb(rgb),.i_mode(pending),
        .active_mode(active),.o_valid(ov),.o_sof(os),.o_eol(oe),.o_rgb(od),
        .gaussian_errors(gerr),.histogram_errors(herr),.median_errors(),.sobel_errors());
    always #5 clk=~clk;
    always #13 src_clk=~src_clk; // unrelated clocks for mailbox test
    reg [127:0] src[0:N-1];
    reg [31:0] gr[0:N-1],bl[0:N-1],he[0:N-1],hegray[0:N-1],med[0:N-1],sob[0:N-1];
    integer modes[0:FRAMES-1];
    integer n=0,f,i,k,m;
    reg [31:0] expected;
    string dir;
    // Visit every ordered pair: 0,0,0,1,0,2,...,4,4,4. Include all bypass
    // latency transitions, mid-frame requests, repeated modes and warm LUTs.
    function integer mode_for(input integer frame);
        if(W>=1920) mode_for=frame%7;
        else if(frame==0) mode_for=0;
        else if(frame%2==1) mode_for=((frame-1)/2)/7;
        else mode_for=((frame-1)/2)%7;
    endfunction
    always @(negedge clk) if(rst_n && ov) begin
        if(n>=N) $fatal(1,"Extra beat");
        m=modes[n/WORDS];
        if(os!==(n%WORDS==0) || oe!==(n%(W/4)==W/4-1)) $fatal(1,"Output marker mismatch %0d",n);
        if(m==0) begin if(od!==src[n]) $fatal(1,"Color bypass lost first/last beat %0d",n);end
        else begin
            case(m) 1:expected=gr[n];2:expected=bl[n];3:expected=hegray[n];4:expected=he[n];5:expected=med[n];6:expected=sob[n];default:expected=he[n];endcase
            for(k=0;k<4;k=k+1) if(od[k*32 +: 32]!=={8'd0,{3{expected[k*8 +: 8]}}})
                $fatal(1,"Runtime pixel mismatch frame=%0d mode=%0d beat=%0d",n/WORDS,m,n%WORDS);
        end
        n=n+1;
    end
    initial begin
        if(!$value$plusargs("VECTORS=%s",dir)) dir="vectors_runtime";
        $readmemh({dir,"/rgb.hex"},src);$readmemh({dir,"/gray.hex"},gr);
        $readmemh({dir,"/blur.hex"},bl);$readmemh({dir,"/he.hex"},he);$readmemh({dir,"/he_gray.hex"},hegray);
        $readmemh({dir,"/median.hex"},med);$readmemh({dir,"/sobel.hex"},sob);
        for(f=0;f<FRAMES;f=f+1) modes[f]=mode_for(f);
        repeat(4) @(posedge clk);#1 rst_n=1;
        repeat(260) @(posedge clk);
        for(f=0;f<FRAMES;f=f+1) begin
            @(negedge src_clk); requested=(f==FRAMES-1)?7:modes[f];
            repeat(20) @(posedge clk);
            if(pending!==((f==FRAMES-1)?7:modes[f])) $fatal(1,"CDC did not settle");
            for(i=0;i<WORDS;i=i+1) begin
                @(posedge clk);#1;v=1;s=(i==0);e=(i%(W/4)==W/4-1);rgb=src[f*WORDS+i];
                if(i==WORDS/2) requested=(modes[f]+2)%7; // must NOT affect current output frame
            end
            @(posedge clk);#1;v=0;s=0;e=0;
            repeat(W/4+300) @(posedge clk);
            #1;if(active!==modes[f]) $fatal(1,"Mid-frame mode change leaked to active mode");
            if(n!=(f+1)*WORDS) $fatal(1,"Wrong frame length after switch frame=%0d count=%0d",f,n);
        end
        requested=7;repeat(50) @(posedge clk);
        if(active>6) $fatal(1,"Invalid mode accepted");
        if(gerr || herr || dut.median_errors || dut.sobel_errors || n!=N) $fatal(1,"Errors or frame loss");
        $display("PASS runtime mode %0dx%0d %0d frames; pixels, SOF/EOL, same-clock control, mid-frame mode hold, invalid mode 7 at SOF rejected",W,H,FRAMES);
        $finish;
    end
    initial begin #200000000; $fatal(1,"Runtime test timeout");end
endmodule
