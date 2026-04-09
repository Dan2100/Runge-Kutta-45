// =============================================================================
// rk45_top.sv — Top-Level Adaptive RK45 ODE Solver
// =============================================================================
// Solves dy/dx = -50*(y-x)+1 over [x_start, x_end] using the Dormand-Prince
// RK45 method with adaptive step-size control.
//
// Main FSM:
//   IDLE → INIT → STEP → STEP_WAIT → CHECK →
//     ├─(accept, x < x_end)→ WRITE_OUT → STEP
//     ├─(accept, x >= x_end)→ WRITE_OUT → DONE
//     └─(reject)──────────────────────→ STEP
//
// Outputs accepted (x, y, err) triples into an output FIFO, readable via
// the result_valid/result_read handshake.
//
// Interface:
//   Inputs:
//     clk, rst_n          — clock and active-low synchronous reset
//     start                — pulse HIGH for 1 cycle to begin integration
//     x_start, x_end      — integration interval [x_start, x_end]
//     y0                   — initial condition y(x_start)
//     h0                   — initial step size
//     rtol, atol           — relative and absolute tolerances
//   Outputs:
//     busy                 — HIGH while integration is in progress
//     done                 — pulses HIGH for 1 cycle when integration finishes
//     result_valid         — HIGH when (result_x, result_y, result_err) are valid
//     result_x/y/err       — current read output from FIFO
//     result_count         — number of accepted steps in FIFO
//     fifo_empty           — FIFO empty flag
//   Controls:
//     result_read          — pulse HIGH to advance FIFO read pointer
// =============================================================================

`include "fp_pkg.svh"

import rk45_constants_pkg::*;

module rk45_top (
    input  logic        clk,
    input  logic        rst_n,

    // Control
    input  logic        start,
    input  logic [63:0] x_start,
    input  logic [63:0] x_end,
    input  logic [63:0] y0,
    input  logic [63:0] h0,
    input  logic [63:0] rtol,
    input  logic [63:0] atol,

    // Status
    output logic        busy,
    output logic        done,

    // Result FIFO read port
    input  logic        result_read,
    output logic        result_valid,
    output logic [63:0] result_x,
    output logic [63:0] result_y,
    output logic [63:0] result_err,
    output logic        fifo_empty,
    output logic [10:0] result_count
);

    // -------------------------------------------------------------------------
    // State registers
    // -------------------------------------------------------------------------
    logic [63:0] x_n, y_n, h_n;    // current state

    // -------------------------------------------------------------------------
    // RK45 step engine
    // -------------------------------------------------------------------------
    logic        step_start, step_done;
    logic [63:0] step_y_next, step_err_est, step_k7;

    rk45_step step_engine (
        .clk     (clk),
        .rst_n   (rst_n),
        .start   (step_start),
        .x_n     (x_n),
        .y_n     (y_n),
        .h       (h_n),
        .y_next  (step_y_next),
        .err_est (step_err_est),
        .k7_out  (step_k7),
        .done    (step_done)
    );

    // -------------------------------------------------------------------------
    // Step controller (adaptive h)
    // -------------------------------------------------------------------------
    logic        ctrl_start, ctrl_done, ctrl_accept;
    logic [63:0] ctrl_h_new;
    logic [63:0] x_after_step;  // x_n + h_n (computed in CHECK state)

    // FP adder for x_after_step = x_n + h_n
    logic        xa_valid_in, xa_valid_out;
    logic [63:0] xa_result;

    fp_add_sub fp_xa (
        .clk(clk), .valid_in(xa_valid_in),
        .a(x_n), .b(h_n), .is_sub(1'b0),
        .result(xa_result), .valid_out(xa_valid_out)
    );

    step_controller ctrl (
        .clk       (clk),
        .rst_n     (rst_n),
        .start     (ctrl_start),
        .y_n       (y_n),
        .y_next    (step_y_next),
        .err_est   (step_err_est),
        .h         (h_n),
        .x_current (x_after_step),
        .x_end     (x_end),
        .rtol      (rtol),
        .atol      (atol),
        .accept    (ctrl_accept),
        .h_new     (ctrl_h_new),
        .done      (ctrl_done)
    );

    // -------------------------------------------------------------------------
    // Comparator for end-of-interval check: x_after_step >= x_end
    // Implemented as: !(x_end > x_after_step)
    // -------------------------------------------------------------------------
    logic        end_cmp_valid_in, end_cmp_valid_out, end_cmp_gt;

    fp_compare fp_end_cmp (
        .clk(clk), .valid_in(end_cmp_valid_in),
        .a(x_end), .b(x_after_step),
        .a_gt_b(end_cmp_gt), .valid_out(end_cmp_valid_out)
    );

    // -------------------------------------------------------------------------
    // Output FIFO
    // -------------------------------------------------------------------------
    logic        fifo_write_en, fifo_full;

    output_buffer #(.DEPTH(1024)) fifo (
        .clk       (clk),
        .rst_n     (rst_n),
        .write_en  (fifo_write_en),
        .x_in      (x_after_step),
        .y_in      (step_y_next),
        .err_in    (step_err_est),
        .full      (fifo_full),
        .read_en   (result_read),
        .x_out     (result_x),
        .y_out     (result_y),
        .err_out   (result_err),
        .valid_out (result_valid),
        .empty     (fifo_empty),
        .count     (result_count)
    );

    // -------------------------------------------------------------------------
    // Main FSM
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_INIT,            // Latch parameters
        ST_STEP,            // Start RK45 step computation
        ST_STEP_WAIT,       // Wait for step engine to finish
        ST_COMPUTE_X,       // Compute x_after_step = x_n + h_n
        ST_COMPUTE_X_WAIT,
        ST_CTRL,            // Start step controller
        ST_CTRL_WAIT,       // Wait for step controller decision
        ST_CHECK,           // Apply accept/reject decision
        ST_WRITE_OUT,       // Write accepted result to FIFO
        ST_ADVANCE,         // Advance x_n, y_n; load new h
        ST_END_CHECK,       // Check if x_after_step >= x_end
        ST_END_CHECK_WAIT,
        ST_DONE
    } main_state_t;

    main_state_t main_state;
    logic        reached_end;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            main_state       <= ST_IDLE;
            busy             <= 1'b0;
            done             <= 1'b0;
            step_start       <= 1'b0;
            ctrl_start       <= 1'b0;
            xa_valid_in      <= 1'b0;
            end_cmp_valid_in <= 1'b0;
            fifo_write_en    <= 1'b0;
        end else begin
            step_start       <= 1'b0;
            ctrl_start       <= 1'b0;
            xa_valid_in      <= 1'b0;
            end_cmp_valid_in <= 1'b0;
            fifo_write_en    <= 1'b0;
            done             <= 1'b0;

            case (main_state)

                ST_IDLE: begin
                    if (start) begin
                        main_state <= ST_INIT;
                        busy       <= 1'b1;
                    end
                end

                ST_INIT: begin
                    x_n <= x_start;
                    y_n <= y0;
                    h_n <= h0;
                    main_state <= ST_STEP;
                end

                // Launch a step attempt
                ST_STEP: begin
                    step_start <= 1'b1;
                    main_state <= ST_STEP_WAIT;
                end

                ST_STEP_WAIT: begin
                    if (step_done) begin
                        main_state <= ST_COMPUTE_X;
                    end
                end

                // Compute x_after_step = x_n + h_n
                ST_COMPUTE_X: begin
                    xa_valid_in <= 1'b1;
                    main_state  <= ST_COMPUTE_X_WAIT;
                end

                ST_COMPUTE_X_WAIT: begin
                    if (xa_valid_out) begin
                        x_after_step <= xa_result;
                        main_state   <= ST_CTRL;
                    end
                end

                // Launch step controller to decide accept/reject + compute h_new
                ST_CTRL: begin
                    ctrl_start <= 1'b1;
                    main_state <= ST_CTRL_WAIT;
                end

                ST_CTRL_WAIT: begin
                    if (ctrl_done) begin
                        main_state <= ST_CHECK;
                    end
                end

                // Apply the accept/reject decision
                ST_CHECK: begin
                    if (ctrl_accept) begin
                        main_state <= ST_WRITE_OUT;
                    end else begin
                        // Reject: update h and retry from same (x_n, y_n)
                        h_n <= ctrl_h_new;
                        main_state <= ST_STEP;
                    end
                end

                // Write accepted (x, y, err) to FIFO
                ST_WRITE_OUT: begin
                    if (!fifo_full) begin
                        fifo_write_en <= 1'b1;
                        main_state    <= ST_ADVANCE;
                    end
                    // If FIFO is full, stall (wait for reads)
                end

                // Advance the state: x_n = x_after_step, y_n = y_next, h = h_new
                ST_ADVANCE: begin
                    x_n <= x_after_step;
                    y_n <= step_y_next;
                    h_n <= ctrl_h_new;
                    main_state <= ST_END_CHECK;
                end

                // Check: x_after_step >= x_end?
                ST_END_CHECK: begin
                    end_cmp_valid_in <= 1'b1;
                    main_state       <= ST_END_CHECK_WAIT;
                end

                ST_END_CHECK_WAIT: begin
                    if (end_cmp_valid_out) begin
                        // end_cmp_gt = (x_end > x_after_step)
                        // If x_end > x_after_step → not done yet
                        // If !(x_end > x_after_step) → x_after_step >= x_end → done
                        if (!end_cmp_gt)
                            main_state <= ST_DONE;
                        else
                            main_state <= ST_STEP;
                    end
                end

                ST_DONE: begin
                    done       <= 1'b1;
                    busy       <= 1'b0;
                    main_state <= ST_IDLE;
                end

            endcase
        end
    end

endmodule
