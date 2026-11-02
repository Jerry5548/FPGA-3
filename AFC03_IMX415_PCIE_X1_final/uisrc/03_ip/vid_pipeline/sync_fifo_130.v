// =============================================================================
// sync_fifo_130.v ¡ª Synchronous FWFT FIFO (single clock domain)
// =============================================================================
// Width: 130 bits (128-bit data + tuser + tlast)
// Depth: 2^ADDR_WIDTH entries, inferred as BRAM
// First-Word Fall-Through: rd_data shows head of queue immediately.
// AXI-Stream compatible: tvalid = !empty, rd_en = handshake (tvalid && tready).
// =============================================================================
`timescale 1ns / 1ps

module sync_fifo_130 #(
    parameter ADDR_WIDTH = 9   // depth = 2^ADDR_WIDTH = 512
)(
    input  wire          clk,
    input  wire          rst_n,

    // Write side (from demosaic)
    input  wire [129:0]  wr_data,
    input  wire          wr_en,      // assert when data valid && !full
    output wire          full,

    // Read side (to serializer)
    output wire [129:0]  rd_data,    // head of queue (combinational)
    input  wire          rd_en,      // assert to consume current head
    output wire          empty
);

    localparam DEPTH = 1 << ADDR_WIDTH;

    // Dual-port inference: write port + read port
    (* ram_style="bram(min_area)" *) reg [129:0] mem [0:DEPTH-1];

    reg [ADDR_WIDTH:0] wr_ptr;   // extra MSB for full/empty detection
    reg [ADDR_WIDTH:0] rd_ptr;

    assign full  = (wr_ptr[ADDR_WIDTH] != rd_ptr[ADDR_WIDTH]) &&
                   (wr_ptr[ADDR_WIDTH-1:0] == rd_ptr[ADDR_WIDTH-1:0]);
    reg [129:0] ram_head,bypass_head;
    reg head_bypass;
    reg head_valid;
    wire memory_empty=(wr_ptr==rd_ptr);
    wire head_free=!head_valid || rd_en;
    wire push=wr_en && !full;
    wire bypass=push && memory_empty && head_free;
    assign empty=!head_valid;

    // Registered read (FWFT output slot) ¡ª shows data at current rd_ptr
    assign rd_data = head_bypass ? bypass_head : ram_head;

    // Write pointer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            wr_ptr <= 0;
        else if (push && !bypass)
            wr_ptr <= wr_ptr + 1'b1;
    end

    // Write data
    always @(posedge clk) begin
        if (push && !bypass)
            mem[wr_ptr[ADDR_WIDTH-1:0]] <= wr_data;
    end

    // RAM read has no asynchronous reset or data bypass, allowing ERAM.
    always @(posedge clk) begin
        if(head_free && !memory_empty)
            ram_head<=mem[rd_ptr[ADDR_WIDTH-1:0]];
        if(bypass) bypass_head<=wr_data;
    end

    // Read pointer
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr<=0;head_bypass<=0;head_valid<=0;
        end else if(head_free) begin
            if(!memory_empty) begin
                head_bypass<=0;
                rd_ptr<=rd_ptr+1'b1;head_valid<=1;
            end else if(bypass) begin
                head_bypass<=1;head_valid<=1;
            end else head_valid<=0;
        end
    end

endmodule
