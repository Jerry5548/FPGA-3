`timescale 1ns/1ps
// LZ77 streaming encoder, phase 1.
//
// This core implements the distance=1 greedy match subset. A run of at least
// MIN_MATCH equal bytes becomes a two-byte LZ77 match token; all other bytes
// become two-byte literal tokens. It is a real LZ77 token stream and gives a
// small, deterministic hardware baseline before adding a general dictionary.
//
// Token format (little-endian on o_token[15:0]):
//   literal: o_match=0, o_bytes=1, o_token[7:0]=literal byte
//   match:   o_match=1, o_bytes=2, bits[14:8]=length (3..127), bits[7:0]=distance (1)
// o_last marks the final token of a
// frame; o_sof marks its first token. Input may stall through i_ready.
module lz77_repeat_encoder #(
    parameter integer MIN_MATCH=3,
    parameter integer MAX_MATCH=127
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_valid,
    output wire        i_ready,
    input  wire [7:0]  i_data,
    input  wire        i_sof,
    input  wire        i_last,

    output reg         o_valid,
    input  wire        o_ready,
    output reg  [15:0] o_token,
    output reg         o_match,
    output reg         o_sof,
    output reg         o_last,
    output reg  [1:0]  o_bytes,

    output reg  [31:0] raw_byte_count,
    output reg  [31:0] compressed_byte_count,
    output reg  [31:0] token_count,
    output reg  [31:0] frame_count,
    output reg  [31:0] error_count
);
    localparam [1:0] ST_IDLE=2'd0, ST_COLLECT=2'd1, ST_FLUSH=2'd2;
    reg [1:0] state;
    reg [7:0] pending_byte, next_byte;
    reg [6:0] pending_len, emit_index;
    reg pending_sof, pending_seed, pending_last, have_next, next_last;
    reg [7:0] min_match_limited;
    wire flushing = state==ST_FLUSH;
    // A literal seed normally needed a separate COLLECT cycle before the
    // next byte could be accepted.  That made incompressible RGB data take
    // two user-clock cycles per byte.  While the seed is being
    // emitted, accept the next source byte in the same cycle and promote it
    // directly to the pending run.  This keeps the existing two-byte token
    // protocol and CRC unchanged while removing one bubble per literal.
    wire fast_seed_slot = (state==ST_FLUSH) && pending_seed &&
                          (pending_len==7'd1) && !pending_last && o_ready &&
                          (!have_next || !next_last);
    wire emit_match = (pending_len >= MIN_MATCH) && !pending_seed;
    wire last_literal = pending_last && !emit_match && (emit_index+1'b1 >= pending_len);
    wire emit_last = pending_last && (emit_match || last_literal);
    assign i_ready = (state==ST_IDLE) || (state==ST_COLLECT) || fast_seed_slot;

    always @(*) begin
        o_valid = flushing;
        o_sof   = flushing && pending_sof;
        o_last  = flushing && emit_last;
        o_match = emit_match;
        o_bytes = emit_match ? 2'd2 : 2'd1;
        if (emit_match)
            o_token = {1'b1,pending_len,8'd1};
        else
            o_token = {8'd0,pending_byte};
    end

    task begin_next_or_idle;
    begin
        if (have_next) begin
            pending_byte <= next_byte;
            pending_len  <= 7'd1;
            pending_sof  <= 1'b0;
            pending_seed <= 1'b1;
            pending_last <= next_last;
            have_next    <= 1'b0;
            emit_index   <= 7'd0;
            // The lookahead byte has not been compared with its successor
            // yet. Return to COLLECT so a run that starts at this byte can
            // still reach MIN_MATCH before it is emitted.
            state        <= next_last ? ST_FLUSH : ST_COLLECT;
        end else if (pending_last) begin
            state <= ST_IDLE;
        end else begin
            pending_len <= 7'd0;
            state <= ST_COLLECT;
        end
    end
    endtask

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= ST_IDLE;
            pending_byte <= 0; next_byte <= 0;
            pending_len <= 0; emit_index <= 0;
            pending_sof <= 0; pending_seed <= 0; pending_last <= 0;
            have_next <= 0; next_last <= 0;
            raw_byte_count <= 0; compressed_byte_count <= 0;
            token_count <= 0; frame_count <= 0; error_count <= 0;
        end else begin
            if (state==ST_IDLE) begin
                if (i_valid && i_ready) begin
                    if (!i_sof) error_count <= error_count + 1'b1;
                    pending_byte <= i_data;
                    pending_len  <= 7'd1;
                    pending_sof  <= 1'b1;
                    pending_seed <= 1'b1;
                    pending_last <= i_last;
                    raw_byte_count <= raw_byte_count + 1'b1;
                    if (i_last) frame_count <= frame_count + 1'b1;
                    if (i_last) state <= ST_FLUSH;
                    else state <= ST_COLLECT;
                end
            end else if (state==ST_COLLECT) begin
                if (i_valid && i_ready) begin
                    raw_byte_count <= raw_byte_count + 1'b1;
                    if (pending_len==0) begin
                        pending_byte <= i_data;
                        pending_len  <= 7'd1;
                        pending_sof  <= 1'b0;
                        pending_seed <= 1'b1;
                        pending_last <= i_last;
                        if (i_last) begin frame_count<=frame_count+1'b1; state <= ST_FLUSH; end
                    end else if (i_data==pending_byte && pending_len<MAX_MATCH) begin
                        pending_len <= pending_len + 1'b1;
                        if (i_last) begin
                            pending_last <= 1'b1;
                            frame_count <= frame_count + 1'b1;
                            state <= ST_FLUSH;
                        end
                    end else begin
                        next_byte <= i_data;
                        next_last <= i_last;
                        if (i_last) frame_count <= frame_count + 1'b1;
                        have_next <= 1'b1;
                        state <= ST_FLUSH;
                    end
                end
            end else if (state==ST_FLUSH) begin
                if (o_valid && o_ready) begin
                    compressed_byte_count <= compressed_byte_count + (emit_match ? 2 : 1);
                    token_count <= token_count + 1'b1;
                    pending_sof <= 1'b0;
                    if (pending_seed && pending_len==7'd1 && !pending_last &&
                        i_valid && i_ready) begin
                        // The seed token is leaving now.  Consume one source
                        // byte in the same cycle.  If a lookahead byte is
                        // already held, compare against it first; otherwise
                        // compare against the seed itself.  A two-byte run is
                        // held for extension by the normal COLLECT path.
                        raw_byte_count <= raw_byte_count + 1'b1;
                        if (i_last) frame_count <= frame_count + 1'b1;
                        emit_index <= 7'd0;
                        if (have_next) begin
                            if (i_data == next_byte) begin
                                pending_byte <= next_byte;
                                pending_len <= 7'd2;
                                pending_seed <= 1'b1;
                                pending_last <= i_last;
                                have_next <= 1'b0;
                                state <= i_last ? ST_FLUSH : ST_COLLECT;
                            end else begin
                                pending_byte <= next_byte;
                                pending_len <= 7'd1;
                                pending_seed <= 1'b1;
                                pending_last <= 1'b0;
                                next_byte <= i_data;
                                next_last <= i_last;
                                have_next <= 1'b1;
                                state <= ST_FLUSH;
                            end
                        end else begin
                            pending_byte <= i_data;
                            pending_len <= 7'd1;
                            // The departing token already seeds distance=1
                            // when the new byte equals it. Preserve that run
                            // instead of emitting equal bytes as literals.
                            pending_seed <= (i_data != pending_byte);
                            pending_last <= i_last;
                            have_next <= 1'b0;
                            state <= i_last ? ST_FLUSH : ST_COLLECT;
                        end
                    end else if (pending_seed) begin
                        // A distance=1 match needs a literal seed for every
                        // new run. The remaining run can then match itself.
                        pending_seed <= 1'b0;
                        if (pending_len>1) begin
                            pending_len <= pending_len-1'b1;
                            emit_index <= 7'd0;
                        end else begin
                            pending_len <= 0;
                            if (pending_last) begin
                                state<=ST_IDLE;
                            end else if (have_next) begin
                                // The byte that ended the previous run was
                                // saved in next_byte.  Promote it now; the
                                // old code left have_next set and discarded
                                // this byte on the following COLLECT cycle,
                                // preventing a reliable final token/frame.
                                begin_next_or_idle();
                            end else begin
                                state<=ST_COLLECT;
                            end
                        end
                    end else if (emit_match) begin
                        begin_next_or_idle();
                    end else if (emit_index+1'b1 >= pending_len) begin
                        begin_next_or_idle();
                    end else begin
                        emit_index <= emit_index + 1'b1;
                    end
                end
            end
        end
    end
endmodule
