`timescale 1ns/1ps
module tb_c2h;
    reg clk=0, rst_n=0;
    always #4 clk=~clk;
    reg iv=0, sof=0, last=0, ready=0;
    reg [127:0] data=0;
    reg [31:0] fid=0;
    wire ir,ov,ol;
    wire [127:0] od;
    wire [15:0] ok;
    wire [31:0] errors;
    integer ticks=0, frames=0, packets=0, fd, rawfd, j, k, f, seed=3576;
    reg stalled=0;
    reg [144:0] held;
    lz77_rgb_c2h_path #(.IMAGE_WIDTH(16),.IMAGE_HEIGHT(16),.PACKET_WORDS(8)) dut(
      .clk(clk),.rst_n(rst_n),.i_valid(iv),.i_ready(ir),.i_data(data),
      .i_sof(sof),.i_frame_last(last),.i_frame_id(fid),
      .o_valid(ov),.o_ready(ready),.o_data(od),.o_keep(ok),.o_last(ol),
      .raw_bytes(),.compressed_bytes(),.token_count(),.frame_count(),.error_count(errors));
    always @(negedge clk) begin
      ticks=ticks+1;
      ready=(ticks>80) && ((ticks%41)<29);
      if(ticks>2000000) $fatal(1,"watchdog");
    end
    always @(posedge clk) if(rst_n) begin
      if(stalled && (!ov || {od,ok,ol} !== held)) $fatal(1,"output changed while stalled");
      stalled=ov && !ready; held={od,ok,ol};
      if(ov && ready) begin
        if(ok==0 || (({1'b0,ok}+1) & {1'b0,ok})!=0) $fatal(1,"noncontiguous keep: %h",ok);
        if(!ol && ok!=16'hffff) $fatal(1,"partial keep without TLAST: %h",ok);
        for(k=0;k<16;k=k+1) if(ok[k]) $fwrite(fd,"%02x\n",od[k*8+:8]);
        if(ol) packets=packets+1;
      end
    end
    initial begin
      fd=$fopen("rtl_0.hex","w");
      repeat(5) @(negedge clk); rst_n=1;
      for(f=0;f<100;f=f+1) begin
        rawfd=$fopen($sformatf("raw_%0d.hex",f),"w");
        for(j=0;j<48;j=j+1) begin
          @(negedge clk); iv=1; sof=(j==0); last=(j==47); fid=f;
          for(k=0;k<16;k=k+1) begin
            case(f)
              0: data[k*8+:8]=(j*16+k)&255;
              1: data[k*8+:8]=8'h41;
              2: data[k*8+:8]=((j*16+k)/3)&255;
              3: data[k*8+:8]=((j*16+k)/4)&255;
              default: data[k*8+:8]=$random(seed);
            endcase
            $fwrite(rawfd,"%02x\n",data[k*8+:8]);
          end
          @(posedge clk); while(!ir) @(posedge clk);
        end
        $fclose(rawfd);
      end
      @(negedge clk); iv=0;sof=0;last=0;
      repeat(20000) @(posedge clk);
      if(errors!=0) $fatal(1,"errors=%d",errors);
      if(dut.frame_count!=100) $fatal(1,"frames=%d",dut.frame_count);
      $display("PASS C2H: 100 frames, fragmented packets=%0d, backpressure stability, packed TKEEP/TLAST", packets); $finish;
    end
endmodule
