// ============================================================================
// tb_vid_frame_gate.v ¡ª Self-checking testbench for vid_frame_gate
//
// Tests:
//   T1: Normal frame passes when FIFO empty (fill=0)
//   T2: Frame dropped when FIFO full (fill >= threshold)
//   T3: After drop, next frame passes normally (no cascade)
//   T4: Consecutive drops when FIFO stays full
//   T5: Mixed sequence: pass-drop-pass-drop
//   T6: SOF at first beat; frame_last at last beat
//   T7: FIFO fill exactly at threshold boundary
//   T8: s_tready always high (gate never blocks upstream)
//   T9: fill_level change mid-frame (gate locked at SOF)
//  T10: Upstream stalls (s_tvalid gaps) within frame
//
// Usage:
//   iverilog -o tb_frame_gate.vvp tb_vid_frame_gate.v ../vid_frame_gate.v
//   vvp tb_frame_gate.vvp
// ============================================================================
`timescale 1ns / 1ps

module tb_vid_frame_gate;

    // ©¤©¤ Parameters ©¤©¤
    localparam DATA_WIDTH     = 128;    // match project width
    localparam FILL_BITS      = 12;
    localparam GATE_THRESHOLD = 100;    // low for fast sim
    localparam CLK_PERIOD     = 4;      // 250 MHz
    localparam BEATS_PER_FRAME = 20;    // small frames for sim

    // ©¤©¤ DUT signals ©¤©¤
    reg                     clk;
    reg                     rst_n;
    reg  [DATA_WIDTH-1:0]   s_tdata;
    reg                     s_tvalid;
    wire                    s_tready;
    reg                     s_tlast;
    reg                     s_frame_last;
    reg                     s_sof;

    wire [DATA_WIDTH-1:0]   m_tdata;
    wire                    m_tvalid;
    wire                    m_frame_last_out;

    reg  [FILL_BITS-1:0]    fifo_fill_level;
    wire [31:0]             gate_drop_count;
    wire [31:0]             gate_pass_count;

    // ©¤©¤ DUT ©¤©¤
    vid_frame_gate #(
        .DATA_WIDTH     (DATA_WIDTH),
        .FILL_BITS      (FILL_BITS),
        .GATE_THRESHOLD (GATE_THRESHOLD)
    ) dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .s_tdata          (s_tdata),
        .s_tvalid         (s_tvalid),
        .s_tready         (s_tready),
        .s_tlast          (s_tlast),
        .s_frame_last     (s_frame_last),
        .s_sof            (s_sof),
        .m_tdata          (m_tdata),
        .m_tvalid         (m_tvalid),
        .m_frame_last     (m_frame_last_out),
        .fifo_fill_level  (fifo_fill_level),
        .gate_drop_count  (gate_drop_count),
        .gate_pass_count  (gate_pass_count)
    );

    // ©¤©¤ Clock ©¤©¤
    initial clk = 0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ©¤©¤ Monitor: capture downstream beats ©¤©¤
    integer mon_beats;
    integer mon_frame_lasts;

    task reset_monitor;
    begin
        mon_beats       = 0;
        mon_frame_lasts = 0;
    end
    endtask

    always @(posedge clk) begin
        if (m_tvalid) begin
            mon_beats = mon_beats + 1;
            if (m_frame_last_out)
                mon_frame_lasts = mon_frame_lasts + 1;
        end
    end

    // ©¤©¤ Test counters ©¤©¤
    integer pass_cnt, fail_cnt;

    task check(input integer cond, input [80*8-1:0] msg);
    begin
        if (cond) begin
            pass_cnt = pass_cnt + 1;
            $display("  [PASS] %0s", msg);
        end else begin
            fail_cnt = fail_cnt + 1;
            $display("  [FAIL] %0s", msg);
        end
    end
    endtask

    // ©¤©¤ Helper: send one frame ©¤©¤
    task send_frame(input [DATA_WIDTH-1:0] base_data);
        integer i;
    begin
        for (i = 0; i < BEATS_PER_FRAME; i = i + 1) begin
            @(posedge clk);
            s_tdata      <= base_data + i[DATA_WIDTH-1:0];
            s_tvalid     <= 1'b1;
            s_sof        <= (i == 0) ? 1'b1 : 1'b0;
            s_tlast      <= (i == BEATS_PER_FRAME - 1) ? 1'b1 : 1'b0;
            s_frame_last <= (i == BEATS_PER_FRAME - 1) ? 1'b1 : 1'b0;
        end
        @(posedge clk);
        s_tvalid     <= 1'b0;
        s_sof        <= 1'b0;
        s_tlast      <= 1'b0;
        s_frame_last <= 1'b0;
    end
    endtask

    task idle_gap(input integer cycles);
        integer ig;
    begin
        s_tvalid     <= 1'b0;
        s_sof        <= 1'b0;
        s_tlast      <= 1'b0;
        s_frame_last <= 1'b0;
        for (ig = 0; ig < cycles; ig = ig + 1)
            @(posedge clk);
    end
    endtask

    // Send frame while changing fill_level at beat change_at
    task send_frame_with_fill_change(
        input [DATA_WIDTH-1:0]   base_data,
        input [FILL_BITS-1:0]    fill_start,
        input [FILL_BITS-1:0]    fill_after,
        input integer            change_at
    );
        integer i;
    begin
        fifo_fill_level = fill_start;
        for (i = 0; i < BEATS_PER_FRAME; i = i + 1) begin
            @(posedge clk);
            s_tdata      <= base_data + i[DATA_WIDTH-1:0];
            s_tvalid     <= 1'b1;
            s_sof        <= (i == 0) ? 1'b1 : 1'b0;
            s_tlast      <= (i == BEATS_PER_FRAME - 1) ? 1'b1 : 1'b0;
            s_frame_last <= (i == BEATS_PER_FRAME - 1) ? 1'b1 : 1'b0;
            if (i == change_at)
                fifo_fill_level = fill_after;
        end
        @(posedge clk);
        s_tvalid <= 1'b0; s_sof <= 1'b0; s_tlast <= 1'b0; s_frame_last <= 1'b0;
    end
    endtask

    // Send frame with s_tvalid gaps between beats
    task send_frame_with_gaps(
        input [DATA_WIDTH-1:0] base_data,
        input integer          gap_cycles
    );
        integer i, g;
    begin
        for (i = 0; i < BEATS_PER_FRAME; i = i + 1) begin
            @(posedge clk);
            s_tdata      <= base_data + i[DATA_WIDTH-1:0];
            s_tvalid     <= 1'b1;
            s_sof        <= (i == 0) ? 1'b1 : 1'b0;
            s_tlast      <= (i == BEATS_PER_FRAME - 1) ? 1'b1 : 1'b0;
            s_frame_last <= (i == BEATS_PER_FRAME - 1) ? 1'b1 : 1'b0;
            // Insert gap after each beat except last
            if (i < BEATS_PER_FRAME - 1) begin
                @(posedge clk);
                s_tvalid <= 1'b0; s_sof <= 1'b0;
                for (g = 1; g < gap_cycles; g = g + 1)
                    @(posedge clk);
            end
        end
        @(posedge clk);
        s_tvalid <= 1'b0; s_sof <= 1'b0; s_tlast <= 1'b0; s_frame_last <= 1'b0;
    end
    endtask

    // ©¤©¤ Main ©¤©¤
    initial begin
        $dumpfile("tb_vid_frame_gate.vcd");
        $dumpvars(0, tb_vid_frame_gate);

        pass_cnt = 0;
        fail_cnt = 0;

        // Reset
        rst_n            = 0;
        s_tdata          = 0;
        s_tvalid         = 0;
        s_tlast          = 0;
        s_frame_last     = 0;
        s_sof            = 0;
        fifo_fill_level  = 0;
        repeat(4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ================================================================
        // T1: Normal frame passes when FIFO empty
        // ================================================================
        $display("\n=== T1: Normal frame pass (FIFO empty) ===");
        reset_monitor;
        fifo_fill_level = 0;
        send_frame(64'hA000);
        idle_gap(4);
        check(mon_beats == BEATS_PER_FRAME,  "T1: all beats passed");
        check(mon_frame_lasts == 1,          "T1: frame_last seen");
        check(gate_pass_count == 1,          "T1: pass_count = 1");
        check(gate_drop_count == 0,          "T1: drop_count = 0");

        // ================================================================
        // T2: Frame dropped when FIFO full
        // ================================================================
        $display("\n=== T2: Frame drop (FIFO full) ===");
        reset_monitor;
        fifo_fill_level = GATE_THRESHOLD;  // exactly at threshold
        send_frame(64'hB000);
        idle_gap(4);
        check(mon_beats == 0,               "T2: zero beats downstream");
        check(mon_frame_lasts == 0,          "T2: no frame_last");
        check(gate_drop_count == 1,          "T2: drop_count = 1");
        check(gate_pass_count == 1,          "T2: pass_count still 1");

        // ================================================================
        // T3: After drop, next frame passes (no cascade)
        // ================================================================
        $display("\n=== T3: Recovery after drop ===");
        reset_monitor;
        fifo_fill_level = 0;  // FIFO drained
        send_frame(64'hC000);
        idle_gap(4);
        check(mon_beats == BEATS_PER_FRAME,  "T3: all beats passed");
        check(mon_frame_lasts == 1,          "T3: frame_last seen");
        check(gate_pass_count == 2,          "T3: pass_count = 2");

        // ================================================================
        // T4: Consecutive drops
        // ================================================================
        $display("\n=== T4: Consecutive drops ===");
        reset_monitor;
        fifo_fill_level = GATE_THRESHOLD + 50;
        send_frame(64'hD000);
        idle_gap(2);
        send_frame(64'hD100);
        idle_gap(2);
        send_frame(64'hD200);
        idle_gap(4);
        check(mon_beats == 0,               "T4: zero beats for 3 drops");
        check(gate_drop_count == 4,          "T4: drop_count = 4 (1+3)");

        // ================================================================
        // T5: Mixed sequence: pass-drop-pass-drop
        // ================================================================
        $display("\n=== T5: Mixed pass/drop sequence ===");
        reset_monitor;

        fifo_fill_level = 0;
        send_frame(64'hE000);  // pass
        idle_gap(2);

        fifo_fill_level = GATE_THRESHOLD + 10;
        send_frame(64'hE100);  // drop
        idle_gap(2);

        fifo_fill_level = 50;
        send_frame(64'hE200);  // pass
        idle_gap(2);

        fifo_fill_level = GATE_THRESHOLD;
        send_frame(64'hE300);  // drop
        idle_gap(4);

        check(mon_beats == 2 * BEATS_PER_FRAME, "T5: 2 frames passed");
        check(mon_frame_lasts == 2,              "T5: 2 frame_lasts");
        check(gate_pass_count == 4,              "T5: total pass = 4");
        check(gate_drop_count == 6,              "T5: total drop = 6");

        // ================================================================
        // T6: Data integrity ¡ª passed frame data matches input
        // ================================================================
        $display("\n=== T6: Data integrity check ===");
        reset_monitor;
        fifo_fill_level = 0;
        // Send frame with known data, verify first beat appears
        @(posedge clk);
        s_tdata      <= {DATA_WIDTH{1'b1}};
        s_tvalid     <= 1'b1;
        s_sof        <= 1'b1;
        s_frame_last <= 1'b0;
        s_tlast      <= 1'b0;
        @(posedge clk);
        // Check output on this cycle
        check(m_tvalid == 1'b1,                         "T6: first beat valid");
        check(m_tdata == {DATA_WIDTH{1'b1}},             "T6: data matches");
        // Send remaining beats
        s_sof <= 1'b0;
        begin : t6_loop
            integer t6i;
            for (t6i = 1; t6i < BEATS_PER_FRAME - 1; t6i = t6i + 1) begin
                s_tdata <= {DATA_WIDTH{1'b1}} - t6i[DATA_WIDTH-1:0];
                @(posedge clk);
            end
        end
        s_frame_last <= 1'b1;
        s_tlast      <= 1'b1;
        s_tdata      <= {DATA_WIDTH{1'b0}};
        @(posedge clk);
        s_tvalid <= 1'b0;
        s_frame_last <= 1'b0;
        s_tlast <= 1'b0;
        idle_gap(4);

        // ================================================================
        // T7: Threshold boundary ¡ª fill = threshold-1 passes
        // ================================================================
        $display("\n=== T7: Boundary: fill = threshold-1 ===");
        reset_monitor;
        fifo_fill_level = GATE_THRESHOLD - 1;
        send_frame(64'hF000);
        idle_gap(4);
        check(mon_beats == BEATS_PER_FRAME,  "T7: passes at threshold-1");

        // ================================================================
        // T8: s_tready always high (gate never blocks upstream)
        // ================================================================
        $display("\n=== T8: s_tready always high ===");
        // During drop, s_tready should still be 1
        fifo_fill_level = GATE_THRESHOLD + 200;
        @(posedge clk);
        s_tdata  <= 64'h1234;
        s_tvalid <= 1'b1;
        s_sof    <= 1'b1;
        @(posedge clk);
        check(s_tready == 1'b1, "T8: s_tready=1 during drop");
        s_sof    <= 1'b0;
        @(posedge clk);
        check(s_tready == 1'b1, "T8: s_tready=1 mid-drop-frame");
        // Complete the frame with frame_last to return DUT to ST_IDLE
        s_frame_last <= 1'b1;
        s_tlast      <= 1'b1;
        @(posedge clk);
        s_tvalid     <= 1'b0;
        s_frame_last <= 1'b0;
        s_tlast      <= 1'b0;
        idle_gap(4);

        // ================================================================
        // T9: fill_level change mid-frame (gate locked at SOF)
        // ================================================================
        $display("\n=== T9: fill changes mid-frame (gate locked at SOF) ===");
        reset_monitor;
        fifo_fill_level = 0;   // low at SOF ¡ú PASS decision
        send_frame_with_fill_change({DATA_WIDTH/8{8'hAA}}, 0, GATE_THRESHOLD + 50, BEATS_PER_FRAME / 2);
        idle_gap(4);
        check(mon_beats == BEATS_PER_FRAME,  "T9a: pass despite fill rising mid-frame");
        check(mon_frame_lasts == 1,          "T9a: frame_last seen");

        // Opposite: high at SOF ¡ú DROP, then fill drops mid-frame
        reset_monitor;
        fifo_fill_level = GATE_THRESHOLD;
        send_frame_with_fill_change({DATA_WIDTH/8{8'hBB}}, GATE_THRESHOLD, 0, BEATS_PER_FRAME / 2);
        idle_gap(4);
        check(mon_beats == 0,                "T9b: drop despite fill dropping mid-frame");

        // ================================================================
        // T10: Upstream stalls (s_tvalid gaps) within frame
        // ================================================================
        $display("\n=== T10: Upstream stalls within frame ===");
        reset_monitor;
        fifo_fill_level = 0;
        send_frame_with_gaps({DATA_WIDTH/8{8'hCC}}, 3);  // 3-cycle gaps
        idle_gap(4);
        check(mon_beats == BEATS_PER_FRAME,  "T10: all beats passed with gaps");
        check(mon_frame_lasts == 1,          "T10: frame_last seen");

        // ================================================================
        // Summary
        // ================================================================
        $display("\n########################################");
        if (fail_cnt == 0) begin
            $display("#  ALL %0d CHECKS PASSED", pass_cnt);
            $display("#  SIMULATION SUFFICIENCY: PASS");
        end else begin
            $display("#  %0d PASSED, %0d FAILED", pass_cnt, fail_cnt);
            $display("#  SIMULATION SUFFICIENCY: FAIL");
        end
        $display("########################################");

        $finish;
    end

endmodule
