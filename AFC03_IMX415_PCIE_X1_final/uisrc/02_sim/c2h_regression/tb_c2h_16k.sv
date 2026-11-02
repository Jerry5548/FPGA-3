`timescale 1ns/1ps
// A complete incompressible frame crosses ten 16 KiB EOP boundaries before
// its short final packet. Randomized sink stalls exercise carry/EOP handling.
module tb_c2h_16k;
    localparam integer W=192,H=144,BEATS=W*H*3/16;
    reg clk=0,rst_n=0,iv=0,sof=0,last=0,ready=0;
    reg [127:0] data=0;
    reg [31:0] fid=32'd77;
    wire ir,ov,ol;
    wire [127:0] od;
    wire [15:0] ok;
    wire [31:0] frames,errors;
    integer tick=0,fd,rawfd,j,k,packets=0,accepted=0;
    integer seed=32'h35762026;
    reg stalled=0;
    reg [144:0] held;

    always #4 clk=~clk;
    lz77_rgb_c2h_path #(.IMAGE_WIDTH(W),.IMAGE_HEIGHT(H),
        .PACKET_WORDS(4096),.USE_INPUT_FRAME_ID(1)) dut(
        .clk(clk),.rst_n(rst_n),.i_valid(iv),.i_ready(ir),.i_data(data),
        .i_sof(sof),.i_frame_last(last),.i_frame_id(fid),
        .o_valid(ov),.o_ready(ready),.o_data(od),.o_keep(ok),.o_last(ol),
        .raw_bytes(),.compressed_bytes(),.token_count(),
        .frame_count(frames),.error_count(errors));

    always @(negedge clk) begin
        tick=tick+1;
        ready=((tick*17+tick/13)%11)<7;
        if(tick>2000000) $fatal(1,"16 KiB C2H watchdog");
    end

    always @(posedge clk) if(rst_n) begin
        if(stalled && (!ov || {od,ok,ol}!==held))
            $fatal(1,"C2H output changed while stalled");
        stalled=ov&&!ready;held={od,ok,ol};
        if(iv&&ir) accepted=accepted+1;
        if(ov&&ready) begin
            if(ok==0 || (({1'b0,ok}+1)&{1'b0,ok})!=0)
                $fatal(1,"noncontiguous KEEP %h",ok);
            if(!ol && ok!=16'hffff) $fatal(1,"partial non-final beat");
            for(k=0;k<16;k=k+1) if(ok[k]) $fwrite(fd,"%02x\n",od[k*8+:8]);
            if(ol) packets=packets+1;
        end
    end

    initial begin
        fd=$fopen("c2h_16k.hex","w");
        rawfd=$fopen("c2h_16k_raw.hex","w");
        repeat(5) @(negedge clk);rst_n=1;
        for(j=0;j<BEATS;j=j+1) begin
            @(negedge clk);iv=1;sof=(j==0);last=(j==BEATS-1);
            for(k=0;k<16;k=k+1) begin
                data[k*8+:8]=$random(seed);
                $fwrite(rawfd,"%02x\n",data[k*8+:8]);
            end
            @(posedge clk);while(!ir) @(posedge clk);
        end
        @(negedge clk);iv=0;sof=0;last=0;
        $fclose(rawfd);
        wait(frames==1);
        repeat(16) @(posedge clk);
        if(accepted!=BEATS || errors!=0 || packets!=11)
            $fatal(1,"counts beats=%0d/%0d frames=%0d errors=%0d packets=%0d",accepted,BEATS,frames,errors,packets);
        $display("# PASS C2H 16 KiB: %0d RGB24 beats, 11 EOP packets including short tail, randomized stalls",BEATS);
        $finish;
    end
endmodule
