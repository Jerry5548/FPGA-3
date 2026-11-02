`timescale 1ns/1ps
// Dehazing via Dark Channel Prior (He et al. 2009), single-pass streaming (mode 9):
//   1. per-pixel dark channel Dp = min(R,G,B)
//   2. 3x3 min filter on Dp -> D  (replicated borders, same control flow as
//      gaussian_3x3_stream.v, but min instead of weighted sum)
//   3. transmission  t = 1 - omega*D/A, clamped >= t0
//   4. recover       Jc = A + (Ic - A) * (255/max(t,t0))   (Q8.8 LUT)
// Color-preserving RGBX8888 x4 -> RGBX8888 x4.
// Input must leave W/4+12 idle clocks after the final beat for bottom-row drain.
// Byte layout per 32-bit pixel: [31:24]=X unused, [23:16]=R, [15:8]=G, [7:0]=B.
module dehaze_stream #(
    parameter integer IMAGE_WIDTH  = 1920,
    parameter integer IMAGE_HEIGHT = 1080,
    parameter [7:0]  ATM_LIGHT = 220,  // atmospheric light A
    parameter [7:0]  T0        = 40,   // v32 brighter floor: 0.157
    parameter integer OMEGA_PCT = 85,  // v32 gentler haze removal: omega=0.85
    parameter [7:0]  BRIGHTNESS_BIAS = 8 // v32 final RGB lift, saturating at 255
)(
    input  wire        clk, rst_n, i_valid, i_sof, i_eol,
    input  wire [127:0] i_rgb,
    output reg         o_valid, o_sof, o_eol,
    output reg  [127:0] o_rgb,
    output wire        busy,
    output reg  [31:0]  protocol_error_count
);
    localparam integer WORDS = IMAGE_WIDTH/4;

    // Fold transmission and reciprocal into one constant ROM. Clamp while
    // signed, before narrowing: unsigned T0 otherwise makes negative t wrap.
    reg [15:0] dark_scale_lut[0:255];
    integer li,transmission;
    initial begin
        for(li=0;li<256;li=li+1) begin
            transmission=255-(OMEGA_PCT*255*li)/(100*ATM_LIGHT);
            if(transmission < $signed({1'b0,T0})) transmission=T0;
            dark_scale_lut[li]=(255*256)/transmission;
        end
    end

    // ---- line buffers store full RGB (center row needed for recovery) ----
    (* ram_style="bram(min_area)" *) reg [127:0] line1 [0:WORDS-1], line2 [0:WORDS-1];
    reg [15:0]  x, y, flush_x;
    reg         flushing, armed;
    localparam integer AW=(WORDS>1) ? $clog2(WORDS) : 1;
    wire [15:0] ix = i_sof ? 16'd0 : x;
    wire [15:0] iy = i_sof ? 16'd0 : y;
    wire [AW-1:0] read_address=flushing ? flush_x[AW-1:0] : ix[AW-1:0];
    wire input_fire=!flushing && i_valid && (armed || i_sof);
    reg [127:0] bank0_q,bank1_q,input_d;
    reg bank_d,flush_d;
    wire [127:0] top_d=bank_d ? bank1_q:bank0_q;
    wire [127:0] mid_d=bank_d ? bank0_q:bank1_q;
    wire [127:0] bot_d=flush_d ? mid_d:input_d;
    reg         v_d, sof_d, eol_d, first_d, top_edge_d, bottom_d;
    reg [31:0] row_top,row_mid,row_bot;
    reg [127:0] rgb_dark;
    reg dark_valid,dark_sof,dark_eol,dark_first;
    reg [31:0]  vertical;      // 4 x 8-bit vertical min of dark channel
    reg [127:0] mid_d1, pending_rgb; // held with the pending dark-channel word
    reg         v_s, sof_s, eol_s, first_s;
    reg         pending, p_sof, p_eol;
    reg [31:0]  p;
    reg [7:0]   left;
    integer     k;

    function [7:0] darkch;          // min(R,G,B) of one 32-bit pixel
        input [31:0] px;
        reg [7:0] m;
        begin
            m = (px[7:0] < px[15:8]) ? px[7:0] : px[15:8];
            darkch = (m < px[23:16]) ? m : px[23:16];
        end
    endfunction

    function [7:0] hmin3;           // 3-input min
        input [7:0] a, b, c;
        reg [7:0] m;
        begin
            m = (a < b) ? a : b;
            hmin3 = (m < c) ? m : c;
        end
    endfunction

    reg qv,qs,qe,rv,rs,re,dv,ds,de,pv,ps,pe;
    reg [31:0] dark_q,pad_d,pad_p;
    reg [127:0] rgb_q,rgb_r;
    reg [63:0] scale_r,scale_d;
    reg signed [8:0] differences[0:11];
    reg signed [25:0] products[0:11];
    integer lane,channel;
    function [7:0] clamp_product;
        input signed [25:0] product;
        reg signed [26:0] recovered;
        begin
            recovered=(product >>> 8)+$signed({1'b0,ATM_LIGHT})+$signed({1'b0,BRIGHTNESS_BIAS});
            if(recovered<0) clamp_product=0;
            else if(recovered>255) clamp_product=255;
            else clamp_product=recovered[7:0];
        end
    endfunction

    assign busy = flushing || (v_d && bottom_d) || (dark_valid && dark_eol) || (v_s && eol_s) || (pending && p_eol) ||
                  (qv && qe) || (rv && re) || (dv && de) || (pv && pe);

    // Alternating row banks. One read and one write per bank, read-first.
    // No reset/enable on RAM output registers; control marks stale data invalid.
    // Unlike a cascaded line2<=line1 read, every memory has a single read port.
    always @(posedge clk) begin
        bank0_q<=line1[read_address];
        bank1_q<=line2[read_address];
        if(input_fire && !iy[0]) line1[ix[AW-1:0]]<=i_rgb;
        if(input_fire &&  iy[0]) line2[ix[AW-1:0]]<=i_rgb;
        input_d<=i_rgb;
        bank_d<=flushing ? y[0]:iy[0];
        flush_d<=flushing;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x <= 0; y <= 0; flush_x <= 0; flushing <= 0; armed <= 0;
            v_d <= 0; sof_d <= 0; eol_d <= 0; first_d <= 0; top_edge_d <= 0; bottom_d <= 0;
            vertical <= 0; mid_d1 <= 0; pending_rgb <= 0;
            row_top<=0;row_mid<=0;row_bot<=0;rgb_dark<=0;
            dark_valid<=0;dark_sof<=0;dark_eol<=0;dark_first<=0;
            qv<=0;qs<=0;qe<=0;rv<=0;rs<=0;re<=0;dv<=0;ds<=0;de<=0;pv<=0;ps<=0;pe<=0;
            dark_q<=0;rgb_q<=0;rgb_r<=0;scale_r<=0;scale_d<=0;pad_d<=0;pad_p<=0;
            for(lane=0;lane<12;lane=lane+1) begin differences[lane]<=0;products[lane]<=0;end
            v_s <= 0; sof_s <= 0; eol_s <= 0; first_s <= 0;
            pending <= 0; p_sof <= 0; p_eol <= 0; p <= 0; left <= 0;
            o_valid <= 0; o_sof <= 0; o_eol <= 0; o_rgb <= 0; protocol_error_count <= 0;
        end else begin
            v_d <= 0; sof_d <= 0; eol_d <= 0; first_d <= 0; bottom_d <= 0;
            if (flushing) begin
                v_d <= 1; first_d <= (flush_x == 0); eol_d <= (flush_x == WORDS-1);
                top_edge_d <= 0; bottom_d <= 1;
                if (i_valid) protocol_error_count <= protocol_error_count + 1'b1;
                if (flush_x == WORDS-1) begin flushing <= 0; flush_x <= 0; armed <= 0; end
                else flush_x <= flush_x + 1'b1;
            end else if (i_valid && (armed || i_sof)) begin
                armed <= 1;
                v_d <= (iy != 0); sof_d <= (iy == 1 && ix == 0); first_d <= (ix == 0);
                eol_d <= (ix == WORDS-1); top_edge_d <= (iy == 1);
                if (i_eol != (ix == WORDS-1)) protocol_error_count <= protocol_error_count + 1'b1;
                if (ix == WORDS-1) begin
                    x <= 0; y <= iy + 1'b1;
                    if (iy == IMAGE_HEIGHT-1) begin flushing <= 1; flush_x <= 0; end
                end else begin x <= ix + 1'b1; y <= iy; end
            end

            dark_valid<=v_d;dark_sof<=v_d && sof_d;
            dark_eol<=v_d && eol_d;dark_first<=first_d;
            if(v_d) begin
                rgb_dark<=mid_d;
                for(k=0;k<4;k=k+1) begin
                    row_top[k*8 +:8]<=darkch(top_edge_d ? mid_d[k*32 +:32]:top_d[k*32 +:32]);
                    row_mid[k*8 +:8]<=darkch(mid_d[k*32 +:32]);
                    row_bot[k*8 +:8]<=darkch(bot_d[k*32 +:32]);
                end
            end
            v_s<=dark_valid;sof_s<=dark_valid && dark_sof;
            eol_s<=dark_valid && dark_eol;first_s<=dark_first;
            if(dark_valid) begin
                mid_d1<=rgb_dark;
                for(k=0;k<4;k=k+1)
                    vertical[k*8 +:8]<=hmin3(row_top[k*8 +:8],row_mid[k*8 +:8],row_bot[k*8 +:8]);
            end

            // Spatial min -> reciprocal ROM -> signed differences -> products
            // -> clamp. RGB, X, SOF and EOL advance only with their valid item.
            qv<=0;qs<=0;qe<=0;
            rv<=qv;rs<=qv && qs;re<=qv && qe;
            dv<=rv;ds<=rv && rs;de<=rv && re;
            pv<=dv;ps<=dv && ds;pe<=dv && de;
            o_valid<=pv;o_sof<=pv && ps;o_eol<=pv && pe;
            if(qv) begin
                rgb_r<=rgb_q;
                for(lane=0;lane<4;lane=lane+1)
                    scale_r[lane*16 +:16]<=dark_scale_lut[dark_q[lane*8 +:8]];
            end
            if(rv) begin
                scale_d<=scale_r;
                for(lane=0;lane<4;lane=lane+1) begin
                    pad_d[lane*8 +:8]<=rgb_r[lane*32+24 +:8];
                    for(channel=0;channel<3;channel=channel+1)
                        differences[lane*3+channel]<=
                            $signed({1'b0,rgb_r[lane*32+channel*8 +:8]})-$signed({1'b0,ATM_LIGHT});
                end
            end
            if(dv) begin
                pad_p<=pad_d;
                for(lane=0;lane<4;lane=lane+1)
                    for(channel=0;channel<3;channel=channel+1)
                        products[lane*3+channel]<=differences[lane*3+channel]*$signed({1'b0,scale_d[lane*16 +:16]});
            end
            if(pv) for(lane=0;lane<4;lane=lane+1) begin
                o_rgb[lane*32+24 +:8]<=pad_p[lane*8 +:8];
                for(channel=0;channel<3;channel=channel+1)
                    o_rgb[lane*32+channel*8 +:8]<=clamp_product(products[lane*3+channel]);
            end
            if (pending && (p_eol || v_s)) begin
                qv<=1;qs<=p_sof;qe<=p_eol;rgb_q<=pending_rgb;
                dark_q[7:0]<=hmin3(left,p[7:0],p[15:8]);
                dark_q[15:8]<=hmin3(p[7:0],p[15:8],p[23:16]);
                dark_q[23:16]<=hmin3(p[15:8],p[23:16],p[31:24]);
                dark_q[31:24]<=hmin3(p[23:16],p[31:24],p_eol ? p[31:24]:vertical[7:0]);
                pending <= 0;
            end
            if (v_s) begin
                pending_rgb <= mid_d1;
                p <= vertical; p_sof <= sof_s; p_eol <= eol_s; pending <= 1;
                left <= first_s ? vertical[7:0] : p[31:24];
            end
        end
    end
endmodule
