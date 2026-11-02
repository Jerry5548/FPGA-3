`timescale 1ns/1ps
// Bundled-data mailbox: source holds mode until synchronized ACK returns.
// Only handshake toggles cross through synchronizers; the data is held stable
// for two destination clocks before capture. Latest requested mode wins after
// an outstanding transfer completes. Both domains share the reset assertion.
module preprocess_mode_cdc #(
    parameter integer DEFAULT_MODE=4
)(
    input wire src_clk,dst_clk,rst_n,
    input wire [2:0] requested_mode,
    output reg [2:0] pending_mode
);
    localparam [2:0] INIT_MODE=(DEFAULT_MODE>=0 && DEFAULT_MODE<=4) ? DEFAULT_MODE : 4;
    reg [2:0] held_mode;
    reg request_toggle,ack_toggle;
    (* async_reg = "true" *) reg [1:0] ack_sync,req_sync;
    always @(posedge src_clk or negedge rst_n) begin
        if(!rst_n) begin
            held_mode<=INIT_MODE;request_toggle<=0;ack_sync<=0;
        end else begin
            ack_sync<={ack_sync[0],ack_toggle};
            if(request_toggle==ack_sync[1] && requested_mode<=4 && requested_mode!=held_mode) begin
                held_mode<=requested_mode;
                request_toggle<=!request_toggle;
            end
        end
    end
    always @(posedge dst_clk or negedge rst_n) begin
        if(!rst_n) begin req_sync<=0;ack_toggle<=0;pending_mode<=INIT_MODE;end
        else begin
            req_sync<={req_sync[0],request_toggle};
            if(req_sync[1]!=ack_toggle) begin
                pending_mode<=held_mode;
                ack_toggle<=req_sync[1];
            end
        end
    end
endmodule
