`timescale 1ns/1ps
// Four-lane Anlogic PHY adapter: one packet per continuous hs_valid burst.
// Layout 0: {DI, WC_LOW, WC_HIGH, ECC}; layout 1: {ECC,WC_HIGH,WC_LOW,DI}.
// Payload output is ALWAYS earliest byte in [31:24]. No backpressure.
// ECC detects (does not correct) header errors. CRC reports errors after pixels
// have streamed out: consumers must invalidate the frame on packet_error.
// Unsupported DT/VC are ignored, never interpreted as RAW10. Classic 2-bit VC.
module mipi_csi2_rx_core #(
    parameter integer HEADER_STANDARD_LAYOUT = 0,
    parameter [7:0] RAW10_DT = 8'h2b,
    parameter [1:0] VC_ID = 0,
    // Keep disabled for the AFC03 production stream until byte orientation is
    // confirmed on the selected D-PHY build; enable for strict qualification.
    parameter integer CHECK_ECC = 0,
    parameter integer CHECK_CRC = 0
)(
    input wire clk, rst_n, enable,
    input wire hs_valid,
    input wire [31:0] hs_data,
    output reg frame_start, frame_end, line_start, line_end,
    output reg payload_valid,
    output reg [31:0] payload_data,
    output reg [2:0] payload_bytes,
    output reg packet_done, packet_error,
    output reg [31:0] frame_count, line_count, packet_count, error_count,
    output reg [31:0] ecc_error_count, crc_error_count, length_error_count,
    output reg [15:0] last_word_count,
    output reg [7:0] last_data_type
);
    wire [31:0] word_be = HEADER_STANDARD_LAYOUT ?
        {hs_data[7:0],hs_data[15:8],hs_data[23:16],hs_data[31:24]} : hs_data;
    wire [7:0] di = word_be[31:24];
    wire [15:0] wc = {word_be[15:8],word_be[23:16]};
    // csi2_frame_tx and the IMX415 packetizer use d24={DI,WC_L,WC_H}.
    wire [23:0] header_bits = {di,word_be[23:16],word_be[15:8]};
    function [7:0] ecc;
        input [23:0] d;
        begin
            ecc[0]=d[0]^d[1]^d[2]^d[4]^d[5]^d[7]^d[10]^d[11]^d[13]^d[16]^d[20]^d[21]^d[22]^d[23];
            ecc[1]=d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[12]^d[14]^d[17]^d[20]^d[21]^d[22]^d[23];
            ecc[2]=d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[11]^d[12]^d[15]^d[18]^d[20]^d[21]^d[22];
            ecc[3]=d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[13]^d[14]^d[15]^d[19]^d[20]^d[21]^d[23];
            ecc[4]=d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[16]^d[17]^d[18]^d[19]^d[20]^d[22]^d[23];
            ecc[5]=d[10]^d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^d[21]^d[22]^d[23];
            ecc[7:6]=0;
        end
    endfunction
    function [15:0] crc_byte;
        input [15:0] c;
        input [7:0] b;
        reg [15:0] x;
        integer k;
        begin
            x=c;
            for(k=0;k<8;k=k+1)
                x=(x>>1) ^ ((x[0]^b[k]) ? 16'h8408 : 16'h0000);
            crc_byte=x;
        end
    endfunction
    reg valid_d, active, selected, first_word;
    reg [15:0] remaining, crc, footer;
    reg [1:0] footer_left;
    reg [15:0] rem_next, crc_next, footer_next;
    reg [1:0] foot_next;
    reg [7:0] byte_value;
    integer i;
    always @* begin
        rem_next=remaining; crc_next=crc; footer_next=footer; foot_next=footer_left;
        byte_value=0;
        for(i=0;i<4;i=i+1) begin
            byte_value=word_be[31-i*8 -: 8];
            if(rem_next!=0) begin
                crc_next=crc_byte(crc_next,byte_value);
                rem_next=rem_next-1'b1;
            end else if(foot_next!=0) begin
                if(foot_next==2) footer_next[7:0]=byte_value;
                else footer_next[15:8]=byte_value;
                foot_next=foot_next-1'b1;
            end
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            valid_d<=0; active<=0; selected<=0; first_word<=0;
            remaining<=0; crc<=16'hffff; footer<=0; footer_left<=0;
            frame_start<=0; frame_end<=0; line_start<=0; line_end<=0;
            payload_valid<=0; payload_data<=0; payload_bytes<=0;
            packet_done<=0; packet_error<=0;
            frame_count<=0; line_count<=0; packet_count<=0; error_count<=0;
            ecc_error_count<=0; crc_error_count<=0; length_error_count<=0;
            last_word_count<=0; last_data_type<=0;
        end else begin
            valid_d<=hs_valid;
            frame_start<=0; frame_end<=0; line_start<=0; line_end<=0;
            payload_valid<=0; payload_bytes<=0; packet_done<=0; packet_error<=0;
            if(!enable) begin
                active<=0; selected<=0;
                // valid_d still tracks input: enabling mid-burst waits for next burst.
            end else if(!hs_valid) begin
                if(active) begin
                    error_count<=error_count+1'b1;
                    length_error_count<=length_error_count+1'b1;
                    packet_error<=1;
                end
                active<=0; selected<=0;
            end else if(!valid_d) begin
                packet_count<=packet_count+1'b1;
                last_data_type<=di; last_word_count<=wc;
                active<=0; selected<=0; first_word<=1;
                if(CHECK_ECC && ecc(header_bits)!=word_be[7:0]) begin
                    error_count<=error_count+1'b1;
                    ecc_error_count<=ecc_error_count+1'b1;
                    packet_error<=1;
                end else if(di[7:6]==VC_ID) begin
                    if(di[5:0]==0) begin
                        frame_start<=1; frame_count<=frame_count+1'b1; line_count<=0;
                        packet_done<=1;
                    end else if(di[5:0]==1) begin
                        frame_end<=1; packet_done<=1;
                    end else if(di[5:0]>15) begin
                        if(di[5:0]==RAW10_DT[5:0] && (wc==0 || wc%5!=0)) begin
                            error_count<=error_count+1'b1;
                            length_error_count<=length_error_count+1'b1;
                            packet_error<=1;
                        end else begin
                            active<=1; selected<=(di[5:0]==RAW10_DT[5:0]);
                            remaining<=wc; crc<=16'hffff; footer<=0; footer_left<=2;
                        end
                    end else packet_done<=1;
                end
            end else if(active) begin
                remaining<=rem_next; crc<=crc_next; footer<=footer_next; footer_left<=foot_next;
                if(selected && remaining!=0) begin
                    payload_valid<=1; payload_data<=word_be;
                    payload_bytes<= remaining>=4 ? 3'd4 : remaining[2:0];
                    line_start<=first_word; first_word<=0;
                    if(rem_next==0) line_end<=1;
                end
                if(foot_next==0) begin
                    active<=0; packet_done<=1;
                    // CSI-2 transmits CRC-16 low byte first on the payload
                    // stream; footer_next therefore stores {CRC_H,CRC_L}.
                    if(CHECK_CRC && crc_next!={footer_next[7:0],footer_next[15:8]}) begin
                        error_count<=error_count+1'b1; crc_error_count<=crc_error_count+1'b1;
                        packet_error<=1;
                    end else if(selected) line_count<=line_count+1'b1;
                end
            end
        end
    end
endmodule
