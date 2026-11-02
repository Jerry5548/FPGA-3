`timescale 1ns / 1ns

`include "../../01_rtl/param_tpg.v"

module ui_tpg (
    input  wire        I_tpg_clk,
    input  wire        I_tpg_rstn,
    input  wire        I_tpg_vs,
    input  wire        I_tpg_hs,
    input  wire        I_tpg_de,
    input  wire [15:0] I_tpg_width,
    input  wire [3:0]  I_tpg_mode,
    input  wire [23:0] I_tpg_solid_color,
    output wire        O_tpg_vs,
    output wire        O_tpg_hs,
    output wire        O_tpg_de,
    output reg  [23:0] O_tpg_data
);

    reg        tpg_vs_r;
    reg        tpg_hs_r;
    reg [11:0] h_cnt;
    reg [11:0] v_cnt;
    reg [31:0] frame_cnt;
    reg [15:0] shift_px;

    wire [15:0] safe_width = (I_tpg_width < 16'd64) ? 16'd64 : I_tpg_width;

    function [2:0] find_bar;
        input [15:0] px;
        input [15:0] width;
        reg   [15:0] bar_w;
        reg   [15:0] b0, b1, b2, b3, b4, b5, b6;
        begin
            bar_w = (width[15:3] == 13'd0) ? 16'd1 : {3'd0, width[15:3]};
            b0 = bar_w;
            b1 = {bar_w[14:0], 1'b0};
            b2 = bar_w + {bar_w[14:0], 1'b0};
            b3 = {bar_w[13:0], 2'b0};
            b4 = {bar_w[13:0], 2'b0} + bar_w;
            b5 = {bar_w[13:0], 2'b0} + {bar_w[14:0], 1'b0};
            b6 = {bar_w[13:0], 2'b0} + {bar_w[14:0], 1'b0} + bar_w;

            if      (px < b0) find_bar = 3'd0;
            else if (px < b1) find_bar = 3'd1;
            else if (px < b2) find_bar = 3'd2;
            else if (px < b3) find_bar = 3'd3;
            else if (px < b4) find_bar = 3'd4;
            else if (px < b5) find_bar = 3'd5;
            else if (px < b6) find_bar = 3'd6;
            else              find_bar = 3'd7;
        end
    endfunction

    function [23:0] bar_color;
        input [2:0] idx;
        begin
            case (idx)
                3'd0: bar_color = 24'hFFFFFF;
                3'd1: bar_color = 24'hFFFF00;
                3'd2: bar_color = 24'h00FFFF;
                3'd3: bar_color = 24'h00FF00;
                3'd4: bar_color = 24'hFF00FF;
                3'd5: bar_color = 24'hFF0000;
                3'd6: bar_color = 24'h0000FF;
                default: bar_color = 24'h000000;
            endcase
        end
    endfunction

    reg [15:0] shifted_px;
    reg [7:0]  mix_byte;

    always @(posedge I_tpg_clk or negedge I_tpg_rstn) begin
        if (!I_tpg_rstn) begin
            tpg_vs_r   <= 1'b0;
            tpg_hs_r   <= 1'b0;
            h_cnt      <= 12'd0;
            v_cnt      <= 12'd0;
            frame_cnt  <= 32'd0;
            shift_px   <= 16'd0;
            O_tpg_data <= 24'd0;
        end else begin
            tpg_vs_r <= I_tpg_vs;
            tpg_hs_r <= I_tpg_hs;

            if (I_tpg_de)
                h_cnt <= h_cnt + 1'b1;
            else
                h_cnt <= 12'd0;

            if (!tpg_vs_r && I_tpg_vs) begin
                v_cnt     <= 12'd0;
                frame_cnt <= frame_cnt + 1'b1;
                if (shift_px + 16'd8 >= safe_width)
                    shift_px <= shift_px + 16'd8 - safe_width;
                else
                    shift_px <= shift_px + 16'd8;
            end else if (!tpg_hs_r && I_tpg_hs) begin
                v_cnt <= v_cnt + 1'b1;
            end

            if (I_tpg_de) begin
                case (I_tpg_mode)
                    `PATTERN_COLORBAR: begin
                        O_tpg_data <= bar_color(find_bar({4'd0, h_cnt}, safe_width));
                    end

                    `PATTERN_COUNTER: begin
                        mix_byte   = h_cnt[7:0] + v_cnt[7:0];
                        O_tpg_data <= {v_cnt[7:0], h_cnt[7:0], mix_byte};
                    end

                    `PATTERN_MOVING_BAR: begin
                        shifted_px = {4'd0, h_cnt} + shift_px;
                        if (shifted_px >= safe_width)
                            shifted_px = shifted_px - safe_width;
                        O_tpg_data <= bar_color(find_bar(shifted_px, safe_width));
                    end

                    `PATTERN_SOLID: begin
                        O_tpg_data <= I_tpg_solid_color;
                    end

                    default: begin
                        O_tpg_data <= 24'd0;
                    end
                endcase
            end else begin
                O_tpg_data <= 24'd0;
            end
        end
    end

    assign O_tpg_vs = I_tpg_vs;
    assign O_tpg_hs = I_tpg_hs;
    assign O_tpg_de = I_tpg_de;

endmodule
