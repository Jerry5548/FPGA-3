`timescale 1ns/1ps
module tb_quad_modes;
    parameter W=8,H=4,FRAMES=5,MODE=4,GAPS=1;
    localparam N=W*H/4*FRAMES;
    reg clk=0,rst_n=0,valid=0,sof=0,eol=0;
    reg [127:0] rgb=0;
    wire ov,os,oe;wire [127:0] od;wire [3:0] am;
    image_preprocess_quad #(.IMAGE_WIDTH(W),.IMAGE_HEIGHT(H),.MODE(MODE),.RUNTIME_MODE(1)) dut(
        .clk(clk),.rst_n(rst_n),.i_valid(valid),.i_sof(sof),.i_eol(eol),.i_rgb(rgb),
        .i_mode(4'(MODE)),.active_mode(am),
        .o_valid(ov),.o_sof(os),.o_eol(oe),.o_rgb(od),
        .gaussian_errors(),.histogram_errors());
    reg [127:0] src[0:N-1];
    reg [31:0] exp[0:N-1];
    integer ng=0,i,f,k;
    reg [255:0] dir;
    always #5 clk=~clk;
    task check_flags(input integer index,input s,input e);
        if(s !== (index%(W*H/4)==0) || e !== (index%(W/4)==W/4-1))
            $fatal(1,"Marker mismatch at %0d sof=%b eol=%b",index,s,e);
    endtask
    always @(negedge clk) if(rst_n) begin
        if(ov) begin
            if(ng>=N) $fatal(1,"Extra output beat");
            if(MODE==0) begin
                if(od!==src[ng]) $fatal(1,"Color bypass mismatch");
            end else for(k=0;k<4;k=k+1) begin
                if(od[k*32 +: 32]!=={8'd0,{3{exp[ng][k*8 +: 8]}}})
                    $fatal(1,"Mode %0d mismatch beat=%0d pixel=%0d got=%h expected=%h",MODE,ng,k,od[k*32 +: 32],exp[ng][k*8 +: 8]);
            end
            check_flags(ng,os,oe);ng=ng+1;
        end
    end
    initial begin
        if(!$value$plusargs("VECTORS=%s",dir)) dir="vectors_quad";
        $readmemh({dir,"/rgb.hex"},src);
        case(MODE)
            1: $readmemh({dir,"/gray.hex"},exp);
            2: $readmemh({dir,"/blur.hex"},exp);
            3: $readmemh({dir,"/he_gray.hex"},exp);
            4: $readmemh({dir,"/he.hex"},exp);
            5: $readmemh({dir,"/median.hex"},exp);
            6: $readmemh({dir,"/sobel.hex"},exp);
        endcase
        repeat(4) @(posedge clk);#1 rst_n=1;
        repeat(260) @(posedge clk);
        for(f=0;f<FRAMES;f=f+1) begin
            for(i=0;i<W*H/4;i=i+1) begin
                @(posedge clk);#1 valid=1;sof=(i==0);eol=(i%(W/4)==W/4-1);rgb=src[f*W*H/4+i];
                if(GAPS && i%7==3) begin @(posedge clk);#1 valid=0;sof=0;eol=0;end
            end
            @(posedge clk);#1 valid=0;sof=0;eol=0;
            // The pipelined HE LUT builder scans all 256 bins and performs a
            // 32-cycle exact divide per bin during vertical blanking.
            // Keep simulated blanking longer than its documented 8960 cycles.
            repeat(10000) @(posedge clk);
        end
        #2;
        if(dut.median_errors!=0 || dut.sobel_errors!=0) $fatal(1,"filter protocol error");
        if(ng!=N) $fatal(1,"Counts out=%0d expected=%0d",ng,N);
        $display("PASS %0dx%0d frames=%0d mode=%0d gaps=%0d, checked pixels and markers",W,H,FRAMES,MODE,GAPS);
        $finish;
    end
    initial begin #200000000; $fatal(1,"Watchdog timeout");end
endmodule
