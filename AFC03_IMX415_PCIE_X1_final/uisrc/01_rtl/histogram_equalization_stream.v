`timescale 1ns/1ps
// Previous-frame global equalization: LUT[g]=floor(255*CDF[g]/(W*H)).
// Four independent lane histograms avoid same-bin write collisions (including
// four identical pixels). CDF/normalization is calculated over vertical blank.
// No CDF-min subtraction. First frame passes through with an identity LUT.
// LUT updates use a 3:1 temporal blend with the active LUT.
// Configuration: W multiple of 4, H>=1, W*H<=16777215. No AXIS tready.
// A scan uses 35 clocks/bin (8960 clocks/frame), including exact 32-bit
// restoring division. The input must provide this many idle clocks after EOF.
module histogram_equalization_stream #(
    parameter integer IMAGE_WIDTH=1920,IMAGE_HEIGHT=1080,
    parameter integer LUT_SMOOTH_SHIFT=2
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
    localparam [24:0] PIXELS_25=PIXELS;
    localparam [1:0] SCAN_BANKS=2'd0,SCAN_CDF=2'd1,
                     SCAN_SCALE=2'd2,SCAN_DIVIDE=2'd3;
    reg [23:0] h0[0:255],h1[0:255],h2[0:255],h3[0:255];
    reg [7:0] lut0[0:255],lut1[0:255];
    reg init_scan,scan,active_lut,pending_lut,collecting;
    reg scan_publish,bad_frame;
    reg [1:0] scan_phase;
    reg [7:0] bin;
    reg [5:0] div_step;
    reg [23:0] cdf,samples,bank_sum_q,total_q,remainder_q;
    reg [31:0] dividend_q;
    reg [7:0] quotient_q;
    reg [15:0] x,y;

    wire [15:0] ix=i_sof ? 16'd0 : x;
    wire [15:0] iy=i_sof ? 16'd0 : y;
    wire [23:0] bank_sum=(h0[bin]+h1[bin])+(h2[bin]+h3[bin]);
    wire [23:0] cdf_next=cdf+bank_sum_q;
    wire [31:0] total_q_ext={8'd0,total_q};
    wire [31:0] scaled_cdf=(total_q_ext<<8)-total_q_ext;
    wire [24:0] div_trial={remainder_q,dividend_q[31]};
    wire div_subtract=(div_trial>=PIXELS_25);
    wire [24:0] div_remainder_next=div_subtract ? (div_trial-PIXELS_25) : div_trial;
    wire [7:0] mapped_next={quotient_q[6:0],div_subtract};
    wire scan_clear_bin=scan && scan_phase==SCAN_BANKS;
    wire scan_write_lut=scan && scan_phase==SCAN_DIVIDE && div_step==6'd31;
    wire [7:0] active_lut_value=active_lut ? lut1[bin] : lut0[bin];
    wire [9:0] smoothed_sum=
        (active_lut_value*((1<<LUT_SMOOTH_SHIFT)-1))+mapped_next;
    wire [7:0] smoothed_mapped=(LUT_SMOOTH_SHIFT==0) ? mapped_next :
                               (smoothed_sum>>LUT_SMOOTH_SHIFT);
    wire switch_lut=i_valid && i_sof && pending_lut;
    wire read_lut=active_lut ^ switch_lut;

    assign ready=!init_scan;
    assign busy=init_scan || scan;

    // Histogram RAM writes and LUT updates. Reset RAM contents by scanning,
    // rather than asynchronous reset on thousands of memory bits.
    integer k;
    always @(posedge clk) begin
        if(init_scan) begin
            h0[bin]<=0;h1[bin]<=0;h2[bin]<=0;h3[bin]<=0;
            lut0[bin]<=bin;lut1[bin]<=bin;
        end else if(scan_clear_bin) begin
            h0[bin]<=0;h1[bin]<=0;h2[bin]<=0;h3[bin]<=0;
        end else if(scan_write_lut && scan_publish) begin
            if(active_lut) lut0[bin]<=smoothed_mapped;
            else lut1[bin]<=smoothed_mapped;
        end else if(!scan && i_valid && (collecting || i_sof)) begin
            h0[i_gray[7:0]]<=h0[i_gray[7:0]]+1'b1;
            h1[i_gray[15:8]]<=h1[i_gray[15:8]]+1'b1;
            h2[i_gray[23:16]]<=h2[i_gray[23:16]]+1'b1;
            h3[i_gray[31:24]]<=h3[i_gray[31:24]]+1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            init_scan<=1;scan<=0;active_lut<=0;pending_lut<=0;collecting<=0;
            scan_publish<=0;bad_frame<=0;scan_phase<=SCAN_BANKS;
            bin<=0;div_step<=0;cdf<=0;samples<=0;bank_sum_q<=0;total_q<=0;
            dividend_q<=0;remainder_q<=0;quotient_q<=0;x<=0;y<=0;
            o_valid<=0;o_sof<=0;o_eol<=0;o_gray<=0;lut_valid<=0;
            frame_count<=0;protocol_error_count<=0;
        end else begin
            o_valid<=i_valid && !init_scan;
            o_sof<=i_valid && i_sof && !init_scan;
            o_eol<=i_valid && i_eol && !init_scan;
            if(i_valid) for(k=0;k<4;k=k+1)
                o_gray[k*8 +: 8]<=read_lut ? lut1[i_gray[k*8 +: 8]] : lut0[i_gray[k*8 +: 8]];

            if(init_scan) begin
                scan_phase<=SCAN_BANKS;
                if(i_valid) protocol_error_count<=protocol_error_count+1'b1;
                if(bin==8'd255) begin
                    init_scan<=0;bin<=0;cdf<=0;samples<=0;
                end else bin<=bin+1'b1;
            end else if(scan) begin
                if(i_valid) protocol_error_count<=protocol_error_count+1'b1;
                case(scan_phase)
                    SCAN_BANKS: begin
                        bank_sum_q<=bank_sum;
                        scan_phase<=SCAN_CDF;
                    end
                    SCAN_CDF: begin
                        total_q<=cdf_next;
                        cdf<=cdf_next;
                        scan_phase<=SCAN_SCALE;
                    end
                    SCAN_SCALE: begin
                        dividend_q<=scaled_cdf;
                        remainder_q<=0;quotient_q<=0;div_step<=0;
                        scan_phase<=SCAN_DIVIDE;
                    end
                    SCAN_DIVIDE: begin
                        dividend_q<={dividend_q[30:0],1'b0};
                        remainder_q<=div_remainder_next[23:0];
                        quotient_q<=mapped_next;
                        if(div_step==6'd31) begin
                            div_step<=0;
                            if(bin==8'd255) begin
                                scan<=0;scan_phase<=SCAN_BANKS;bin<=0;cdf<=0;samples<=0;
                                if(scan_publish) pending_lut<=1;
                            end else begin
                                bin<=bin+1'b1;scan_phase<=SCAN_BANKS;
                            end
                        end else div_step<=div_step+1'b1;
                    end
                    default: scan_phase<=SCAN_BANKS;
                endcase
            end else if(i_valid && i_sof && collecting) begin
                // Truncated frame: clear all bins and skip this new frame.
                protocol_error_count<=protocol_error_count+1'b1;
                scan<=1;scan_phase<=SCAN_BANKS;div_step<=0;scan_publish<=0;
                bin<=0;cdf<=0;collecting<=0;bad_frame<=0;pending_lut<=0;
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
                        collecting<=0;scan<=1;scan_phase<=SCAN_BANKS;
                        div_step<=0;bin<=0;cdf<=0;
                        scan_publish<=!bad_frame && i_eol && samples+4==PIXELS;
                        frame_count<=frame_count+1'b1;
                    end
                end else begin x<=ix+1'b1;y<=iy;end
            end
        end
    end
endmodule
