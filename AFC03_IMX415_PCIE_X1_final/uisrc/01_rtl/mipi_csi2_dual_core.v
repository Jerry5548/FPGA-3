`timescale 1ns/1ps
// Packet-layer fanout for two independently clocked camera links.
// Physical D-PHY wrappers remain outside; instantiate this once both PHY
// byte-streams have been constrained in the TD top-level.
module mipi_csi2_dual_core #(
    parameter integer HEADER_STANDARD_LAYOUT = 0,
    parameter [7:0] RAW10_DT = 8'h2b,
    parameter integer CHECK_ECC = 0,
    parameter integer CHECK_CRC = 0
)(
    input wire clk0,rst0_n,enable0,hs0_valid,
    input wire [31:0] hs0_data,
    output wire frame0_start,frame0_end,line0_start,line0_end,
    output wire payload0_valid,output wire [31:0] payload0_data,
    output wire [2:0] payload0_bytes,output wire packet0_done,packet0_error,
    output wire [31:0] frame0_count,line0_count,packet0_count,error0_count,
    input wire clk1,rst1_n,enable1,hs1_valid,
    input wire [31:0] hs1_data,
    output wire frame1_start,frame1_end,line1_start,line1_end,
    output wire payload1_valid,output wire [31:0] payload1_data,
    output wire [2:0] payload1_bytes,output wire packet1_done,packet1_error,
    output wire [31:0] frame1_count,line1_count,packet1_count,error1_count
);
    wire [31:0] unused_ecc0,unused_crc0,unused_len0;
    wire [31:0] unused_ecc1,unused_crc1,unused_len1;
    mipi_csi2_rx_core #(.HEADER_STANDARD_LAYOUT(HEADER_STANDARD_LAYOUT),.RAW10_DT(RAW10_DT),.CHECK_ECC(CHECK_ECC),.CHECK_CRC(CHECK_CRC))
    u_rx0(
      .clk(clk0),.rst_n(rst0_n),.enable(enable0),.hs_valid(hs0_valid),.hs_data(hs0_data),
      .frame_start(frame0_start),.frame_end(frame0_end),.line_start(line0_start),.line_end(line0_end),
      .payload_valid(payload0_valid),.payload_data(payload0_data),.payload_bytes(payload0_bytes),
      .packet_done(packet0_done),.packet_error(packet0_error),.frame_count(frame0_count),
      .line_count(line0_count),.packet_count(packet0_count),.error_count(error0_count),
      .ecc_error_count(unused_ecc0),.crc_error_count(unused_crc0),.length_error_count(unused_len0),
      .last_word_count(),.last_data_type());
    mipi_csi2_rx_core #(.HEADER_STANDARD_LAYOUT(HEADER_STANDARD_LAYOUT),.RAW10_DT(RAW10_DT),.CHECK_ECC(CHECK_ECC),.CHECK_CRC(CHECK_CRC))
    u_rx1(
      .clk(clk1),.rst_n(rst1_n),.enable(enable1),.hs_valid(hs1_valid),.hs_data(hs1_data),
      .frame_start(frame1_start),.frame_end(frame1_end),.line_start(line1_start),.line_end(line1_end),
      .payload_valid(payload1_valid),.payload_data(payload1_data),.payload_bytes(payload1_bytes),
      .packet_done(packet1_done),.packet_error(packet1_error),.frame_count(frame1_count),
      .line_count(line1_count),.packet_count(packet1_count),.error_count(error1_count),
      .ecc_error_count(unused_ecc1),.crc_error_count(unused_crc1),.length_error_count(unused_len1),
      .last_word_count(),.last_data_type());
endmodule
