// =============================================================================
// output_buffer.sv — Synchronous FIFO for RK45 Trajectory Output
// =============================================================================
// Stores accepted integration step results as (x, y, err) triples.
// Each entry is 192 bits: {x[63:0], y[63:0], err[63:0]}.
//
// Parameters:
//   DEPTH  — number of entries (default 1024, must be power of 2)
//
// Write port (from RK45 step controller):
//   write_en   — write one entry when HIGH (ignored if full)
//   x_in       — accepted x value
//   y_in       — accepted y value
//   err_in     — error estimate at accepted step
//
// Read port (to testbench / host interface):
//   read_en    — advance read pointer and present next entry
//   x_out      — current read entry x
//   y_out      — current read entry y
//   err_out    — current read entry err
//   valid_out  — HIGH when read data is valid (not empty)
//
// Status:
//   full       — FIFO is full  (writes are dropped when full)
//   empty      — FIFO is empty
//   count      — number of valid entries currently stored
// =============================================================================

`timescale 1ns / 1ps

module output_buffer #(
    parameter int DEPTH = 256          // must be a power of 2
) (
    input  logic        clk,
    input  logic        rst_n,

    // Write port
    input  logic        write_en,
    input  logic [63:0] x_in,
    input  logic [63:0] y_in,
    input  logic [63:0] err_in,
    output logic        full,

    // Read port
    input  logic        read_en,
    output logic [63:0] x_out,
    output logic [63:0] y_out,
    output logic [63:0] err_out,
    output logic        valid_out,      // HIGH when output data is valid

    // Status
    output logic        empty,
    output logic [$clog2(DEPTH):0] count
);

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------
    localparam int PTR_W = $clog2(DEPTH);

    (* ram_style = "block" *) logic [191:0] mem [0:DEPTH-1]; // 192 = 3 × 64 bits

    logic [PTR_W-1:0] wr_ptr, rd_ptr;
    logic [PTR_W:0]   count_r;          // one extra bit for full/empty detect

    assign count = count_r;
    assign full  = (count_r == DEPTH[PTR_W:0]);
    assign empty = (count_r == '0);

    // -------------------------------------------------------------------------
    // Write logic
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= '0;
        end else if (write_en && !full) begin
            mem[wr_ptr] <= {x_in, y_in, err_in};
            wr_ptr      <= wr_ptr + 1'b1;
        end
    end

    // -------------------------------------------------------------------------
    // Read logic
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ptr    <= '0;
            valid_out <= 1'b0;
        end else begin
            valid_out <= 1'b0;
            if (read_en && !empty) begin
                {x_out, y_out, err_out} <= mem[rd_ptr];
                rd_ptr                  <= rd_ptr + 1'b1;
                valid_out               <= 1'b1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Entry counter
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count_r <= '0;
        end else begin
            case ({write_en && !full, read_en && !empty})
                2'b10: count_r <= count_r + 1'b1;  // write only
                2'b01: count_r <= count_r - 1'b1;  // read only
                default: ;                          // both or neither: unchanged
            endcase
        end
    end

endmodule
