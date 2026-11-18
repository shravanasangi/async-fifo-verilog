`timescale 1ns/1ps

// ============================================================================
// Asynchronous FIFO (dual clock)
//
//  - Gray-code read/write pointers cross clock domains
//  - Two-flop synchronizers on each crossing pointer
//  - full  is registered in the write domain
//  - empty is registered in the read domain
//  - Per-domain reset synchronizers: async assert, synchronous release
//  - Registered read data (1 read-clock cycle of latency)
//
//  Requirements: ADDR_WIDTH >= 2  (full-detect logic inverts the top 2 bits)
//  Usage note  : do not drive wr_en / rd_en while rst is asserted, and wait a
//                few clock cycles after rst is released before starting traffic
//                (the internal reset releases 2 clock edges after rst).
// ============================================================================
module async_fifo #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 3                 // depth = 2**ADDR_WIDTH
)(
    input  wire                  wr_clk,
    input  wire                  rd_clk,
    input  wire                  rst,        // active-high, asynchronous

    input  wire                  wr_en,
    input  wire                  rd_en,

    input  wire [DATA_WIDTH-1:0] wr_data,
    output reg  [DATA_WIDTH-1:0] rd_data,

    output reg                   full,
    output reg                   empty
);

    // ------------------------------------------------------------------
    // Configuration (DEPTH is derived, so it can never disagree with
    // ADDR_WIDTH)
    // ------------------------------------------------------------------
    localparam DEPTH     = 1 << ADDR_WIDTH;
    localparam PTR_WIDTH = ADDR_WIDTH + 1;

    // ------------------------------------------------------------------
    // Memory
    // ------------------------------------------------------------------
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    // ------------------------------------------------------------------
    // Pointers
    // ------------------------------------------------------------------
    reg [PTR_WIDTH-1:0] wr_bin,  wr_gray;
    reg [PTR_WIDTH-1:0] rd_bin,  rd_gray;

    // Synchronized Gray pointers
    reg [PTR_WIDTH-1:0] rd_gray_sync1, rd_gray_sync2;   // rd -> wr domain
    reg [PTR_WIDTH-1:0] wr_gray_sync1, wr_gray_sync2;   // wr -> rd domain

    wire [PTR_WIDTH-1:0] wr_bin_next, wr_gray_next;
    wire [PTR_WIDTH-1:0] rd_bin_next, rd_gray_next;

    // ------------------------------------------------------------------
    // Reset synchronizers (one per clock domain)
    //   assert  : asynchronous, immediately when rst goes high
    //   release : synchronous, 2 clock edges after rst goes low
    // ------------------------------------------------------------------
    reg [1:0] wr_rst_sync;
    reg [1:0] rd_rst_sync;

    wire wr_rst = wr_rst_sync[1];
    wire rd_rst = rd_rst_sync[1];

    always @(posedge wr_clk or posedge rst) begin
        if (rst) wr_rst_sync <= 2'b11;
        else     wr_rst_sync <= {wr_rst_sync[0], 1'b0};
    end

    always @(posedge rd_clk or posedge rst) begin
        if (rst) rd_rst_sync <= 2'b11;
        else     rd_rst_sync <= {rd_rst_sync[0], 1'b0};
    end

    // ------------------------------------------------------------------
    // Accepted operations
    //   !wr_rst gates the memory write too, so nothing is stored while the
    //   write domain is still in reset.
    // ------------------------------------------------------------------
    wire wr_accept = wr_en && !full  && !wr_rst;
    wire rd_accept = rd_en && !empty && !rd_rst;

    // Binary increment and binary -> Gray conversion
    assign wr_bin_next  = wr_bin + wr_accept;
    assign rd_bin_next  = rd_bin + rd_accept;

    assign wr_gray_next = (wr_bin_next >> 1) ^ wr_bin_next;
    assign rd_gray_next = (rd_bin_next >> 1) ^ rd_bin_next;

    // ==================================================================
    // WRITE DOMAIN
    // ==================================================================
    always @(posedge wr_clk or posedge wr_rst) begin
        if (wr_rst) begin
            wr_bin  <= 0;
            wr_gray <= 0;
            full    <= 1'b0;
        end
        else begin
            wr_bin  <= wr_bin_next;
            wr_gray <= wr_gray_next;

            // Full: next write Gray pointer equals the synchronized read
            // Gray pointer with its two MSBs inverted
            full <= (wr_gray_next ==
                     {~rd_gray_sync2[PTR_WIDTH-1:PTR_WIDTH-2],
                       rd_gray_sync2[PTR_WIDTH-3:0]});
        end
    end

    // Memory write (no reset, so FPGA tools can infer RAM)
    always @(posedge wr_clk) begin
        if (wr_accept)
            mem[wr_bin[ADDR_WIDTH-1:0]] <= wr_data;
    end

    // rd_gray -> wr_clk domain
    always @(posedge wr_clk or posedge wr_rst) begin
        if (wr_rst) begin
            rd_gray_sync1 <= 0;
            rd_gray_sync2 <= 0;
        end
        else begin
            rd_gray_sync1 <= rd_gray;
            rd_gray_sync2 <= rd_gray_sync1;
        end
    end

    // ==================================================================
    // READ DOMAIN
    // ==================================================================
    always @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst) begin
            rd_bin  <= 0;
            rd_gray <= 0;
            empty   <= 1'b1;
            rd_data <= 0;
        end
        else begin
            rd_bin  <= rd_bin_next;
            rd_gray <= rd_gray_next;

            // Empty: next read Gray pointer equals synchronized write Gray
            // pointer
            empty <= (rd_gray_next == wr_gray_sync2);

            if (rd_accept)
                rd_data <= mem[rd_bin[ADDR_WIDTH-1:0]];
        end
    end

    // wr_gray -> rd_clk domain
    always @(posedge rd_clk or posedge rd_rst) begin
        if (rd_rst) begin
            wr_gray_sync1 <= 0;
            wr_gray_sync2 <= 0;
        end
        else begin
            wr_gray_sync1 <= wr_gray;
            wr_gray_sync2 <= wr_gray_sync1;
        end
    end

endmodule
