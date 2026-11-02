// ============================================================================
// fps_timer.v - 可配帧率定时器
//
// 功能：根据 cfg_fps 配置在 250MHz 时钟域产生 frame_pulse 脉冲。
//       cfg_fps=0 时全速，不限速。
// ============================================================================

`include "../../01_rtl/param_tpg.v"

module fps_timer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire [7:0]  cfg_fps,       // 目标帧率 (1-255, 0=全速)
    output reg         frame_pulse    // 单周期脉冲
);

    // ----------------------------------------------------------------
    // 计算计数上限：CLK_FREQ / FPS - 1
    // 250MHz / 60fps = 4,166,666 → 需 22-bit 计数器
    // 250MHz / 24fps = 10,416,666 → 24-bit 足够
    // ----------------------------------------------------------------
    reg [23:0] count_max;
    reg [23:0] counter;

    // FPS → 周期映射（运行时计算除法较贵，用 case 近似）
    always @(*) begin
        case (cfg_fps)
            8'd0:   count_max = 24'd0;             // 全速（每周期出脉冲）
            8'd24:  count_max = 24'd10_416_665;     // 250M/24 - 1
            8'd25:  count_max = 24'd9_999_999;      // 250M/25 - 1
            8'd30:  count_max = 24'd8_333_332;      // 250M/30 - 1
            8'd50:  count_max = 24'd4_999_999;      // 250M/50 - 1
            8'd60:  count_max = 24'd4_166_665;      // 250M/60 - 1
            default: count_max = 24'd4_166_665;     // 默认 60fps
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter     <= 24'd0;
            frame_pulse <= 1'b0;
        end else if (!enable) begin
            counter     <= 24'd0;
            frame_pulse <= 1'b0;
        end else if (cfg_fps == 8'd0) begin
            // 全速模式：每个时钟周期都可触发（但实际受 TPG 帧时间限制）
            // frame_pulse 持续为 1，TPG 完成一帧后立即开始下一帧
            frame_pulse <= 1'b1;
        end else if (counter >= count_max) begin
            counter     <= 24'd0;
            frame_pulse <= 1'b1;
        end else begin
            counter     <= counter + 1'b1;
            frame_pulse <= 1'b0;
        end
    end

endmodule
