`timescale 1ns/1ps
module tb_modes;
    parameter W=64,H=40,FRAMES=8,GAPS=1,BLANK=1100;
    localparam N=W*H/4,WORDS=W/4;
    reg clk=0,rst_n=0,iv=0,isof=0,ieol=0;
    reg [127:0] rgb=0;
    reg [3:0] mode=4,request;
    wire ov,os,oe;
    wire [127:0] out_rgb;
    wire [3:0] active;
    wire [31:0] ge,he,me,se,de;
    image_preprocess_quad #(.IMAGE_WIDTH(W),.IMAGE_HEIGHT(H),.RUNTIME_MODE(1)) dut(
        .clk(clk),.rst_n(rst_n),.i_valid(iv),.i_sof(isof),.i_eol(ieol),.i_rgb(rgb),
        .i_mode(mode),.active_mode(active),.o_valid(ov),.o_sof(os),.o_eol(oe),.o_rgb(out_rgb),
        .gaussian_errors(ge),.histogram_errors(he),.median_errors(me),.sobel_errors(se),.dehaze_errors(de));
    reg [127:0] inputs[0:N*FRAMES-1],expected[0:N*FRAMES-1];
    integer fd,frame,j,gap,got=0,limit=0,total=0;
    reg [31:0] prng=32'h1234abcd;
    reg [3:0] wanted=4;
    always #4 clk=~clk;
    // Sample before NBA: mode0 is combinational; all other valid/data are
    // registered and stable from the preceding edge.
    always @(posedge clk) if(rst_n && ov) begin
        if(got>=limit) $fatal(1,"unexpected/extra output got=%0d limit=%0d",got,limit);
        if(out_rgb!==expected[got]) $fatal(1,"pixels word=%0d got=%h expected=%h",got,out_rgb,expected[got]);
        if(os !== ((got%N)==0)) $fatal(1,"SOF word=%0d",got);
        if(oe !== ((got%WORDS)==WORDS-1)) $fatal(1,"EOL word=%0d",got);
        got=got+1;
    end
    initial begin
        fd=$fopen("input.hex","r");if(!fd)$fatal(1,"missing input.hex");$fclose(fd);
        fd=$fopen("expected.hex","r");if(!fd)$fatal(1,"missing expected.hex");$fclose(fd);
        $readmemh("input.hex",inputs);$readmemh("expected.hex",expected);
        repeat(6) @(negedge clk);rst_n=1;
        for(frame=0;frame<FRAMES;frame=frame+1) begin
            case(frame%8) 0,5:request=0;1,3:request=8;2,4,7:request=9;6:request=7;endcase
            if(request!=7)wanted=request;
            limit=(frame+1)*N;
            for(j=0;j<N;j=j+1) begin
                @(negedge clk);
                prng={prng[30:0],prng[31]^prng[21]^prng[1]^prng[0]};
                if(GAPS && prng[2:0]==0) begin
                    iv=0;isof=0;ieol=0;
                    repeat(3) @(negedge clk);
                end
                iv=1;isof=(j==0);ieol=(j%WORDS==WORDS-1);rgb=inputs[frame*N+j];
                // A mid-frame request must not change the selected branch.
                mode=(j==0) ? request : (wanted==8 ? 9:8);
            end
            @(negedge clk);iv=0;isof=0;ieol=0;
            repeat(WORDS+BLANK) @(negedge clk);
            if(got!=limit)$fatal(1,"missing frame=%0d got=%0d expected=%0d",frame,got,limit);
            if(active!==wanted)$fatal(1,"mode not latched frame=%0d active=%0d expected=%0d",frame,active,wanted);
            if(de!==0 || ge!==0 || me!==0 || se!==0)$fatal(1,"protocol errors de=%0d ge=%0d me=%0d se=%0d",de,ge,me,se);
        end
        $display("PASS mode8/9 real quad pipeline %0dx%0d frames=%0d gaps=%0d RGB/X/SOF/EOL/clamp/frame-mode",W,H,FRAMES,GAPS);
        $finish;
    end
    initial begin #1000000000; $fatal(1,"timeout");end
endmodule
