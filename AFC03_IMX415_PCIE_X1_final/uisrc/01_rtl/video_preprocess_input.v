`timescale 1ns/1ps
// Shared real preprocessing path; host credit includes line-buffer latency.
module video_preprocess_input #(
 parameter integer IMAGE_WIDTH=1920,IMAGE_HEIGHT=1080,
 parameter integer PREPROCESS_MODE=4,RUNTIME_PREPROCESS=1,HOST_INPUT_ENABLE=0
)(
 input wire user_clk,user_rst_n,enable,preprocess_enable,
 input wire [127:0] camera_rgb,
 input wire camera_valid,camera_sof,camera_eol,
 output wire camera_ready,
 input wire host_select,host_valid,host_sof,host_eol,
 input wire [127:0] host_rgb,output wire host_ready,
 input wire [3:0] cfg_preprocess_mode,output wire [3:0] preprocess_mode_active,
 output wire [31:0] median_error_count,sobel_error_count,dehaze_error_count,
 output reg [31:0] fifo_overflow_count,
 output wire [127:0] m_tdata,
 output wire m_tvalid,m_tlast,m_frame_last,sof,eof,input wire m_tready,
 output wire [31:0] frame_count_out
);
    wire fifo_full,fifo_empty,fifo_tready;
    wire [127:0] pre_tdata_128;
    wire pre_tvalid, pre_tlast, pre_tuser;
    wire [31:0] pre_gaussian_errors, pre_histogram_errors;
    wire host_selected = HOST_INPUT_ENABLE ? host_select : 1'b0;
    reg [10:0] host_outstanding;
    wire host_fire=host_valid && host_ready;
    wire processed_pop=fifo_tready && !fifo_empty;
    // Credit includes ALL accepted groups still in line buffers/pipeline/FIFO.
    // 1000 < 1024 FIFO entries; > two 480-word rows, avoiding startup deadlock.
    assign host_ready=host_selected && enable && host_outstanding<1000;
    always @(posedge user_clk or negedge user_rst_n) begin
        if(!user_rst_n) host_outstanding<=0;
        else if(!enable || !host_selected) host_outstanding<=0;
        else case({host_fire,processed_pop})
            2'b10: host_outstanding<=host_outstanding+1'b1;
            2'b01: host_outstanding<=host_outstanding-1'b1;
            default: host_outstanding<=host_outstanding;
        endcase
    end
    wire preprocess_stream_valid = preprocess_enable ? pre_tvalid : camera_valid;
    wire preprocess_stream_sof = preprocess_enable ? pre_tuser : camera_sof;
    wire preprocess_stream_last = preprocess_enable ? pre_tlast : camera_eol;
    wire [127:0] preprocess_stream_data = preprocess_enable ? pre_tdata_128 : camera_rgb;     // Saturation 96b ¡ú 128b (restore padding)

    // FIFO output ¡ú pack4_rgb24_to_512
    wire [127:0] fifo_tdata;
    wire         fifo_tvalid;
    wire         fifo_tlast;
    wire         fifo_tuser;

    // Register the input mux/control before the non-stallable processing tree.
    // Host credit is charged on acceptance, so this stage is included in bounds.
    reg input_valid,input_sof,input_eol;
    reg [127:0] input_rgb;
    always @(posedge user_clk or negedge user_rst_n) begin
        if(!user_rst_n) begin
            input_valid<=0;input_sof<=0;input_eol<=0;input_rgb<=0;
        end else begin
            input_valid<=enable && (host_selected ? host_fire : (camera_valid && camera_ready));
            input_sof<=host_selected ? (host_sof && host_fire) : (camera_sof && camera_ready);
            input_eol<=host_selected ? (host_eol && host_fire) : (camera_eol && camera_ready);
            if(host_selected ? host_fire : camera_valid) input_rgb<=host_selected ? host_rgb : camera_rgb;
        end
    end

    // Project-owned four-pixel preprocessing pipeline.
    image_preprocess_quad #(
        .IMAGE_WIDTH(IMAGE_WIDTH), .IMAGE_HEIGHT(IMAGE_HEIGHT),
        .MODE(PREPROCESS_MODE), .RUNTIME_MODE(RUNTIME_PREPROCESS)
    ) u_project_preprocess (
        .clk(user_clk), .rst_n(user_rst_n),
        .i_valid(input_valid),.i_sof(input_sof),.i_eol(input_eol),
        .i_rgb(input_rgb),.i_mode(cfg_preprocess_mode),
        .active_mode(preprocess_mode_active),
        .o_valid(pre_tvalid), .o_sof(pre_tuser), .o_eol(pre_tlast),
        .o_rgb(pre_tdata_128),
        .gaussian_errors(pre_gaussian_errors),
        .histogram_errors(pre_histogram_errors),
        .median_errors(median_error_count),.sobel_errors(sobel_error_count),.dehaze_errors(dehaze_error_count)
    );

    // ================================================================
    // 4b. Rate-decoupling FIFO (AWB ¡ú pack4)
    //     Demosaic outputs 480 beats/line at 1 beat/clk.
    //     pack4 processes 4 pixels/clk (same as demosaic output rate).
    //     FIFO absorbs bursts when downstream stalls (DMA descriptor).
    // ================================================================
    wire [129:0] fifo_rd_data;
    reg capture_armed;
    wire fifo_run=user_rst_n && enable;
    always @(posedge user_clk or negedge user_rst_n) begin
        if(!user_rst_n) capture_armed<=0;
        else if(!enable) capture_armed<=0;
        else if(preprocess_stream_valid && preprocess_stream_sof) capture_armed<=1;
    end

    // Count processed camera beats lost under downstream backpressure.
    always @(posedge user_clk or negedge user_rst_n) begin
        if(!user_rst_n) fifo_overflow_count<=0;
        else if(enable && preprocess_stream_valid && fifo_full)
            fifo_overflow_count<=fifo_overflow_count+1'b1;
    end

    assign camera_ready   = 1'b1; // Non-stallable ISP: DDR path drains at camera rate
    assign fifo_tdata   = fifo_rd_data[127:0];
    assign fifo_tlast   = fifo_rd_data[128];
    assign fifo_tuser   = fifo_rd_data[129];
    assign fifo_tvalid  = ~fifo_empty;

    sync_fifo_130 #(
        .ADDR_WIDTH (10)       // 1024 entries, enough for 960-beat 4K line burst
    ) u_demo_fifo (
        .clk      (user_clk),
        .rst_n    (fifo_run),
        .wr_data  ({preprocess_stream_sof, preprocess_stream_last, preprocess_stream_data}),
        .wr_en    (enable && (capture_armed || preprocess_stream_sof) && preprocess_stream_valid && !fifo_full),
        .full     (fifo_full),
        .rd_data  (fifo_rd_data),
        .rd_en    (fifo_tready & ~fifo_empty),
        .empty    (fifo_empty)
    );

    // ================================================================
    // 5. pack4_rgb24_to_128 ¡ª 4-pixel parallel RGB24 packer (128b¡ú128b)
    //    Strips per-pixel padding and tight-packs RGB24 for 128b DMA.
    //    4 inputs (48B) ¡ú 3 outputs (48B), LCM(12,16)=48.
    // ================================================================
    pack4_rgb24_to_128 #(.IMAGE_HEIGHT(IMAGE_HEIGHT)) u_pack4 (
        .clk            (user_clk),
        .rst_n          (user_rst_n),
        .enable         (enable),
        // Input from FIFO (128b AXI-Stream)
        .s_tdata        (fifo_tdata),
        .s_tvalid       (fifo_tvalid),
        .s_tready       (fifo_tready),
        .s_tlast        (fifo_tlast),
        .s_tuser        (fifo_tuser),
        // 512-bit AXI-Stream output
        .m_tdata        (m_tdata),
        .m_tvalid       (m_tvalid),
        .m_tready       (m_tready),
        .m_tlast        (m_tlast),
        .m_frame_last   (m_frame_last),
        .sof            (sof),
        .eof            (eof),
        .frame_count_out(frame_count_out)
    );

endmodule
