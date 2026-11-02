`timescale 1ns/1ps
module tb_histogram_1080p;
    localparam integer W=1920,H=1080,PIXELS=W*H,WORDS=W/4,FRAMES=3;
    reg clk=0,rst_n=0,valid=0,sof=0,eol=0;
    reg [31:0] gray=0;
    wire ov,os,oe,ready,busy,lut_valid;
    wire [31:0] out_gray,frame_count,error_count;
    integer frame_out=0,beat_out=0,pixel_out=0,k,f,i;
    reg [7:0] expected;
    reg [7:0] lut_frame0[0:255];
    reg [7:0] lut_frame1[0:255];
    always #5 clk=~clk;

    histogram_equalization_stream #(.IMAGE_WIDTH(W),.IMAGE_HEIGHT(H)) dut(
        .clk(clk),.rst_n(rst_n),.i_valid(valid),.i_sof(sof),.i_eol(eol),.i_gray(gray),
        .o_valid(ov),.o_sof(os),.o_eol(oe),.o_gray(out_gray),
        .ready(ready),.busy(busy),.lut_valid(lut_valid),
        .frame_count(frame_count),.protocol_error_count(error_count));

    function automatic [7:0] target(input integer b);
        target=(255*(b+1))/256;
    endfunction

    always @(negedge clk) begin
        if(rst_n && ov) begin
            if(os !== (beat_out==0)) $fatal(1,"1080p SOF mismatch frame=%0d beat=%0d",frame_out,beat_out);
            if(oe !== ((beat_out%WORDS)==WORDS-1))
                $fatal(1,"1080p EOL mismatch frame=%0d beat=%0d",frame_out,beat_out);
            for(k=0;k<4;k=k+1) begin
                case(frame_out)
                    0: expected=pixel_out[7:0];
                    1: expected=lut_frame0[pixel_out%256];
                    default: expected=lut_frame1[pixel_out%256];
                endcase
                if(out_gray[k*8 +: 8] !== expected)
                    $fatal(1,"1080p pixel mismatch frame=%0d pixel=%0d got=%0d expected=%0d",
                           frame_out,pixel_out,out_gray[k*8 +: 8],expected);
                pixel_out=pixel_out+1;
            end
            beat_out=beat_out+1;
            if(beat_out==WORDS*H) begin
                beat_out=0;pixel_out=0;frame_out=frame_out+1;
            end
        end
    end

    initial begin
        for(i=0;i<256;i=i+1) begin
            lut_frame0[i]=(3*i+target(i))/4;
            lut_frame1[i]=(3*lut_frame0[i]+target(i))/4;
        end
        repeat(4) @(posedge clk); #1 rst_n=1;
        wait(ready);
        for(f=0;f<FRAMES;f=f+1) begin
            for(i=0;i<WORDS*H;i=i+1) begin
                @(posedge clk); #1;
                valid=1;sof=(i==0);eol=((i%WORDS)==WORDS-1);
                gray={8'((i*4+3)&255),8'((i*4+2)&255),
                      8'((i*4+1)&255),8'((i*4)&255)};
            end
            @(posedge clk); #1 valid=0;sof=0;eol=0;
            // Allow histogram scan/reset and exact divider to finish.
            repeat(10000) @(posedge clk);
            #1;
            if(error_count!=0) $fatal(1,"protocol errors=%0d after frame %0d",error_count,f);
        end
        repeat(8) @(negedge clk);
        if(frame_out!=FRAMES || frame_count!=FRAMES || !lut_valid)
            $fatal(1,"frames out=%0d internal=%0d lut_valid=%0d",frame_out,frame_count,lut_valid);
        $display("PASS histogram 1080p: %0d frames, exact prior-frame LUT pixels, protocol errors=%0d",
                 frame_out,error_count);
        $finish;
    end
    initial begin #100000000; $fatal(1,"1080p HE watchdog"); end
endmodule
