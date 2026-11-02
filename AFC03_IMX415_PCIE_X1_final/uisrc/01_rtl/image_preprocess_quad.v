`timescale 1ns/1ps
// MODE 0 original RGB, 1 gray, 2 gray+Gaussian, 3 gray+equalization,
// MODE 4 gray+Gaussian+equalization, 5 gray+median, 6 gray+Sobel,
// MODE 8 color lowlight, 9 color dehaze.
// RUNTIME_MODE=1 enables i_mode requests.
// Frame input must respect Gaussian drain + histogram scan blanking budget.
// All branches run continuously: histories/LUTs stay warm while not selected.
module image_preprocess_quad #(
    parameter integer IMAGE_WIDTH=1920,IMAGE_HEIGHT=1080,MODE=4,RUNTIME_MODE=0
)(
    input wire clk,rst_n,i_valid,i_sof,i_eol,
    input wire [127:0] i_rgb,
    input wire [3:0] i_mode, // already coherent in clk domain (see mode_cdc)
    output wire [3:0] active_mode,
    output wire o_valid,o_sof,o_eol,
    output wire [127:0] o_rgb,
    output wire [31:0] gaussian_errors,histogram_errors,median_errors,sobel_errors,dehaze_errors
);
    wire gv,gs,ge;wire [31:0] gd;
    wire bv,bs,be;wire [31:0] bd;
    wire hv,hs,he;wire [31:0] hd;
    wire [31:0] blur_he_errors,gray_he_errors;
    wire ghv,ghs,ghe;wire [31:0] ghd;
    wire mv,ms,me;wire [31:0] md;
    wire sv,ss,se;wire [31:0] sd;
    localparam [3:0] INIT_MODE=((MODE>=0 && MODE<=6) || MODE==8 || MODE==9) ? MODE : 4;
    reg [3:0] frame_mode;
    // Direct RGB bypass has zero latency: use the new mode on the SOF beat
    // itself, then hold it until the next SOF. Prior frame must be drained.
    wire [3:0] selected_mode=RUNTIME_MODE ?
        ((i_valid && i_sof && (i_mode<=6 || i_mode==8 || i_mode==9)) ? i_mode : frame_mode) : INIT_MODE;
    assign active_mode=frame_mode;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) frame_mode<=INIT_MODE;
        else if(RUNTIME_MODE && i_valid && i_sof && (i_mode<=6 || i_mode==8 || i_mode==9)) frame_mode<=i_mode;
    end
    gray_pixel_stream gray(.clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_sof(i_sof),.i_eol(i_eol),
        .i_rgb(i_rgb),.o_valid(gv),.o_sof(gs),.o_eol(ge),.o_gray(gd));
    gaussian_3x3_stream #(.IMAGE_WIDTH(IMAGE_WIDTH),.IMAGE_HEIGHT(IMAGE_HEIGHT)) blur(
        .clk(clk),.rst_n(rst_n),.i_valid(gv),.i_sof(gs),.i_eol(ge),.i_gray(gd),
        .o_valid(bv),.o_sof(bs),.o_eol(be),.o_gray(bd),.busy(),.protocol_error_count(gaussian_errors));
    histogram_equalization_stream #(.IMAGE_WIDTH(IMAGE_WIDTH),.IMAGE_HEIGHT(IMAGE_HEIGHT)) equalize(
        .clk(clk),.rst_n(rst_n),.i_valid(!RUNTIME_MODE && MODE==3 ? gv : bv),.i_sof(!RUNTIME_MODE && MODE==3 ? gs : bs),
        .i_eol(!RUNTIME_MODE && MODE==3 ? ge : be),.i_gray(!RUNTIME_MODE && MODE==3 ? gd : bd),
        .o_valid(hv),.o_sof(hs),.o_eol(he),.o_gray(hd),.ready(),.busy(),.lut_valid(),
        .frame_count(),.protocol_error_count(blur_he_errors));
    median_3x3_stream #(.IMAGE_WIDTH(IMAGE_WIDTH),.IMAGE_HEIGHT(IMAGE_HEIGHT)) med(
        .clk(clk),.rst_n(rst_n),.i_valid(gv),.i_sof(gs),.i_eol(ge),.i_gray(gd),
        .o_valid(mv),.o_sof(ms),.o_eol(me),.o_gray(md),.busy(),.protocol_error_count(median_errors));
    sobel_3x3_stream #(.IMAGE_WIDTH(IMAGE_WIDTH),.IMAGE_HEIGHT(IMAGE_HEIGHT)) sob(
        .clk(clk),.rst_n(rst_n),.i_valid(gv),.i_sof(gs),.i_eol(ge),.i_gray(gd),
        .o_valid(sv),.o_sof(ss),.o_eol(se),.o_gray(sd),.busy(),.protocol_error_count(sobel_errors));
    wire lv,ls,le;
    wire [127:0] lrgb;
    lowlight_enhance_stream #(.IMAGE_WIDTH(IMAGE_WIDTH),.IMAGE_HEIGHT(IMAGE_HEIGHT)) lowlight(
        .clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_sof(i_sof),.i_eol(i_eol),.i_rgb(i_rgb),
        .o_valid(lv),.o_sof(ls),.o_eol(le),.o_rgb(lrgb));
    wire dv,ds,de;
    wire [127:0] drgb;
    dehaze_stream #(.IMAGE_WIDTH(IMAGE_WIDTH),.IMAGE_HEIGHT(IMAGE_HEIGHT)) dehaze(
        .clk(clk),.rst_n(rst_n),.i_valid(i_valid),.i_sof(i_sof),.i_eol(i_eol),.i_rgb(i_rgb),
        .o_valid(dv),.o_sof(ds),.o_eol(de),.o_rgb(drgb),.busy(),.protocol_error_count(dehaze_errors));
    generate if(RUNTIME_MODE) begin: runtime_gray_he
        // Separate histogram history for mode 3; do not mix Gaussian and
        // unfiltered statistics when switching between modes 3 and 4.
        histogram_equalization_stream #(.IMAGE_WIDTH(IMAGE_WIDTH),.IMAGE_HEIGHT(IMAGE_HEIGHT)) equalize_gray(
            .clk(clk),.rst_n(rst_n),.i_valid(gv),.i_sof(gs),.i_eol(ge),.i_gray(gd),
            .o_valid(ghv),.o_sof(ghs),.o_eol(ghe),.o_gray(ghd),.ready(),.busy(),.lut_valid(),
            .frame_count(),.protocol_error_count(gray_he_errors));
    end else begin: static_gray_he
        assign ghv=hv;assign ghs=hs;assign ghe=he;assign ghd=hd;
        assign gray_he_errors=0;
    end endgenerate
    assign histogram_errors=blur_he_errors+gray_he_errors;
    wire [31:0] out_gray=selected_mode==1 ? gd : selected_mode==2 ? bd : selected_mode==3 ? ghd : selected_mode==5 ? md : selected_mode==6 ? sd : hd;
    assign o_valid=selected_mode==9 ? dv : selected_mode==8 ? lv : selected_mode==0 ? i_valid : selected_mode==1 ? gv : selected_mode==2 ? bv : selected_mode==3 ? ghv : selected_mode==5 ? mv : selected_mode==6 ? sv : hv;
    assign o_sof=selected_mode==9 ? ds : selected_mode==8 ? ls : selected_mode==0 ? i_sof : selected_mode==1 ? gs : selected_mode==2 ? bs : selected_mode==3 ? ghs : selected_mode==5 ? ms : selected_mode==6 ? ss : hs;
    assign o_eol=selected_mode==9 ? de : selected_mode==8 ? le : selected_mode==0 ? i_eol : selected_mode==1 ? ge : selected_mode==2 ? be : selected_mode==3 ? ghe : selected_mode==5 ? me : selected_mode==6 ? se : he;
    genvar n;
    generate for(n=0;n<4;n=n+1) begin: pack_gray
        assign o_rgb[n*32 +: 32]=selected_mode==9 ? drgb[n*32 +: 32] : selected_mode==8 ? lrgb[n*32 +: 32] : selected_mode==0 ? i_rgb[n*32 +: 32] : {8'd0,{3{out_gray[n*8 +: 8]}}};
    end endgenerate
endmodule
