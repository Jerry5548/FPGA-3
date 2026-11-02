`timescale 1ns/1ps
// Previous-frame global equalization: LUT[g]=floor(255*CDF[g]/(W*H)).
// Four independent lane histograms avoid same-bin write collisions (including
// four identical pixels). Banks are summed during a 256-clock vertical-blank
// scan. No CDF-min subtraction. First frame passes through with identity LUT.
// Need >=257 idle clocks after frame EOF and 256 startup clocks before first SOF.
// Incomplete frames / insufficient blanking are flagged; video still streams.
// Configuration: W multiple of 4, H>=1, W*H<=16777215. No AXIS tready.
module histogram_equalization_stream #(
    parameter integer IMAGE_WIDTH=1920,IMAGE_HEIGHT=1080
)(
    input wire clk,rst_n,i_valid,i_sof,i_eol,
    input wire [31:0] i_gray,
    output reg o_valid,o_sof,o_eol,
    output reg [31:0] o_gray,
    output wire ready, busy,
    output reg lut_valid,
    output reg [31:0] frame_count,protocol_error_count
);
    localparam integer PIXELS=IMAGE_WIDTH*IMAGE_HEIGHT;
    localparam integer WORDS=IMAGE_WIDTH/4;
    reg [23:0] h0[0:255],h1[0:255],h2[0:255],h3[0:255];
    reg [7:0] lut0[0:255],lut1[0:255];
    reg init_scan,scan,active_lut,pending_lut,collecting;
    reg scan_publish,bad_frame;
    reg [7:0] bin;
    reg [23:0] cdf, samples;
    reg [15:0] x,y;
    wire [15:0] ix=i_sof ? 16'd0 : x;
    wire [15:0] iy=i_sof ? 16'd0 : y;
    wire [23:0] total=cdf+h0[bin]+h1[bin]+h2[bin]+h3[bin];
    wire [31:0] scaled=total*32'd255;
    wire [31:0] mapped=scaled/PIXELS;
    wire switch_lut=i_valid && i_sof && pending_lut;
    wire read_lut=active_lut ^ switch_lut;
    assign ready=!init_scan;
    assign busy=init_scan || scan;
    integer k;
    // Scan resets histograms rather than asynchronous resetting RAM bits.
    always @(posedge clk) begin
        if(init_scan || scan) begin
            h0[bin]<=0;h1[bin]<=0;h2[bin]<=0;h3[bin]<=0;
            if(init_scan) begin lut0[bin]<=bin;lut1[bin]<=bin;end
            else if(scan_publish) begin
                if(active_lut) lut0[bin]<=mapped[7:0];
                else lut1[bin]<=mapped[7:0];
            end
        end else if(i_valid && (collecting || i_sof)) begin
            h0[i_gray[7:0]]<=h0[i_gray[7:0]]+1'b1;
            h1[i_gray[15:8]]<=h1[i_gray[15:8]]+1'b1;
            h2[i_gray[23:16]]<=h2[i_gray[23:16]]+1'b1;
            h3[i_gray[31:24]]<=h3[i_gray[31:24]]+1'b1;
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            init_scan<=1;scan<=0;active_lut<=0;pending_lut<=0;collecting<=0;
            scan_publish<=0;bad_frame<=0;
            bin<=0;cdf<=0;samples<=0;x<=0;y<=0;
            o_valid<=0;o_sof<=0;o_eol<=0;o_gray<=0;lut_valid<=0;
            frame_count<=0;protocol_error_count<=0;
        end else begin
            o_valid<=i_valid && !init_scan;
            o_sof<=i_valid && i_sof && !init_scan;o_eol<=i_valid && i_eol && !init_scan;
            if(i_valid) for(k=0;k<4;k=k+1)
                o_gray[k*8 +: 8]<=read_lut ? lut1[i_gray[k*8 +: 8]] : lut0[i_gray[k*8 +: 8]];
            if(init_scan || scan) begin
                if(i_valid) protocol_error_count<=protocol_error_count+1'b1;
                if(scan) cdf<=total;
                if(bin==255) begin
                    init_scan<=0;scan<=0;bin<=0;cdf<=0;samples<=0;
                    if(scan && scan_publish) pending_lut<=1;
                end else bin<=bin+1'b1;
            end else if(i_valid && i_sof && collecting) begin
                // Truncated frame: clear all bins and skip this new frame.
                // Never publish a LUT built from two mixed frames.
                protocol_error_count<=protocol_error_count+1'b1;
                scan<=1;scan_publish<=0;bin<=0;cdf<=0;collecting<=0;
                bad_frame<=0;pending_lut<=0;
            end else if(i_valid && (collecting || i_sof)) begin
                collecting<=1;
                if(i_sof) bad_frame<=0;
                samples<=samples+4;
                if(switch_lut) begin active_lut<=!active_lut;pending_lut<=0;lut_valid<=1;end
                if(i_eol!=(ix==WORDS-1)) begin
                    protocol_error_count<=protocol_error_count+1'b1;
                    bad_frame<=1;
                end
                if(ix==WORDS-1) begin
                    x<=0;y<=iy+1'b1;
                    if(iy==IMAGE_HEIGHT-1) begin
                        collecting<=0;scan<=1;bin<=0;cdf<=0;
                        scan_publish<=!bad_frame && i_eol && samples+4==PIXELS;
                        frame_count<=frame_count+1'b1;
                    end
                end else begin x<=ix+1'b1;y<=iy;end
            end
        end
    end
endmodule
