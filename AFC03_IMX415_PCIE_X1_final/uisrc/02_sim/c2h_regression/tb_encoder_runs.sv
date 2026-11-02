`timescale 1ns/1ps
// Byte scoreboard covers long/short runs, input bubbles and output stalls.
module tb_encoder_runs;
    reg clk=0,rst_n=0,iv=0,sof=0,last=0,ready=0;
    reg [7:0] data=0;
    wire ir,ov,om,os,ol;
    wire [15:0] token;
    wire [1:0] count;
    wire [31:0] raw,compressed,tokens,frames,errors;
    reg [7:0] expected[0:39999];
    integer size=0,sent=0,decoded=0,outs=0,ticks=0,j,n,pattern,seed=519;
    integer cycles,lasts=0;
    reg [20:0] held;
    reg stalled=0;
    always #4 clk=~clk;
    lz77_repeat_encoder dut(.clk(clk),.rst_n(rst_n),
        .i_valid(iv),.i_ready(ir),.i_data(data),.i_sof(sof),.i_last(last),
        .o_valid(ov),.o_ready(ready),.o_token(token),.o_match(om),
        .o_sof(os),.o_last(ol),.o_bytes(count),.raw_byte_count(raw),
        .compressed_byte_count(compressed),.token_count(tokens),
        .frame_count(frames),.error_count(errors));
    always @(posedge clk) if(rst_n) begin
        if(stalled && (!ov || {token,om,os,ol,count}!==held))
            $fatal(1,"token changed while stalled");
        held={token,om,os,ol,count};stalled=ov&&!ready;
        if(iv&&ir) sent=sent+1;
        if(ov&&ready) begin
            if(os !== (decoded==0)) $fatal(1,"wrong SOF");
            n=om ? token[14:8] : 1;
            if(om && (n<3 || token[7:0]!=1 || decoded==0))
                $fatal(1,"invalid distance=1 token");
            for(j=0;j<n;j=j+1) begin
                if(decoded>=size || expected[decoded] !==
                   (om ? expected[decoded-1] : token[7:0]))
                    $fatal(1,"byte mismatch pattern=%0d offset=%0d",pattern,decoded);
                decoded=decoded+1;
            end
            outs=outs+1;
            if(ol) begin
                lasts=lasts+1;
                if(decoded!=size) $fatal(1,"early LAST decoded=%0d size=%0d",decoded,size);
            end
        end
    end
    initial begin
        // Runs around both MIN_MATCH and MAX_MATCH, followed by varying RGB.
        for(pattern=0;pattern<3;pattern=pattern+1) begin
            rst_n=0;iv=0;sent=0;decoded=0;size=0;outs=0;lasts=0;stalled=0;
            for(j=1;j<=260;j=j+1) begin
                repeat(j) begin expected[size]=j%251;size=size+1;end
            end
            repeat(4) @(negedge clk);
            rst_n=1;cycles=0;
            while(lasts==0) begin
                @(negedge clk);
                cycles=cycles+1;
                // Never retract a valid source beat while the DUT stalls.
                if(!iv || ir) begin
                    iv=(sent<size) && (pattern==0 || (($random(seed)&7)!=0));
                    data=expected[sent];sof=(sent==0);last=(sent==size-1);
                end
                ready=(pattern<2) || (($random(seed)&3)!=0);
                if(cycles>size*8) $fatal(1,"watchdog");
            end
            @(negedge clk);iv=0;
            repeat(3) @(negedge clk);
            if(raw!=size || errors!=0 || frames!=1 || lasts!=1 || tokens!=outs)
                $fatal(1,"wrong end counters");
        end
        $display("PASS encoder runs: lengths 1..260, source gaps, sink stalls, exact bytes and frame counters");
        $finish;
    end
endmodule
