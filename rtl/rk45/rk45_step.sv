// =============================================================================
// rk45_step.sv — Full Dormand-Prince RK45 Step (k1–k7 + Error Estimate)
// =============================================================================
// Orchestrates one complete RK45 step attempt:
//   1. Compute k1 through k7 via rk45_stage (sequentially)
//   2. Compute y_next = y_n + h * Σ(b_i * k_i)  [5th-order solution]
//      (This is done implicitly by k7 stage using b-weights as a-coefficients)
//   3. Compute err = h * Σ(e_i * k_i)  [error estimate]
//
// Design note: k7 stage uses b1..b6 as its "a" coefficients, so the stage
// engine's output y_stage for k7 IS the 5th-order solution y_next.
// The k7 value itself is also needed for the error estimate (e7 ≠ 0).
//
// Interface:
//   - Assert start HIGH for 1 cycle with stable inputs.
//   - done pulses HIGH when y_next, err_est are valid.
//   - Do not assert start again until done has been seen.
// =============================================================================

`include "fp_pkg.svh"

import rk45_constants_pkg::*;

module rk45_step (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [63:0] x_n,        // current x
    input  logic [63:0] y_n,        // current y
    input  logic [63:0] h,          // current step size
    output logic [63:0] y_next,     // 5th-order solution
    output logic [63:0] err_est,    // error estimate (weighted sum)
    output logic [63:0] k7_out,     // k7 value (for FSAL reuse as next k1)
    output logic        done
);

    // -------------------------------------------------------------------------
    // Stage engine instance
    // -------------------------------------------------------------------------
    logic        stage_start, stage_done;
    logic [2:0]  stage_idx;
    logic [63:0] stage_k_out;
    logic [63:0] stage_y_out;       // y_stage from stage engine
    logic [63:0] k_array [0:6];

    rk45_stage stage_engine (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (stage_start),
        .stage       (stage_idx),
        .x_n         (x_n),
        .y_n         (y_n),
        .h           (h),
        .k           (k_array),
        .k_out       (stage_k_out),
        .y_stage_out (stage_y_out),
        .done        (stage_done)
    );

    // -------------------------------------------------------------------------
    // Shared FP units for error accumulation
    // -------------------------------------------------------------------------
    logic        mul_valid_in, mul_valid_out;
    logic [63:0] mul_a, mul_b, mul_result;

    logic        as_valid_in, as_valid_out;
    logic [63:0] as_a, as_b, as_result;
    logic        as_is_sub;

    fp_mul fp_mul_err (
        .clk(clk), .valid_in(mul_valid_in),
        .a(mul_a), .b(mul_b), .result(mul_result), .valid_out(mul_valid_out)
    );

    fp_add_sub fp_as_err (
        .clk(clk), .valid_in(as_valid_in),
        .a(as_a), .b(as_b), .is_sub(as_is_sub),
        .result(as_result), .valid_out(as_valid_out)
    );

    // -------------------------------------------------------------------------
    // Error coefficient lookup
    // -------------------------------------------------------------------------
    function automatic logic [63:0] get_e_coeff(input int idx);
        case (idx)
            0: return E1_B;
            1: return `FP64_ZERO;   // E2 = 0
            2: return E3_B;
            3: return E4_B;
            4: return E5_B;
            5: return E6_B;
            6: return E7_B;
            default: return `FP64_ZERO;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_COMPUTE_STAGE,   // Launch stage engine for k[stage_idx]
        ST_WAIT_STAGE,      // Wait for stage engine to finish
        ST_STORE_K,         // Store ki and advance to next stage
        ST_ERR_INIT,        // Begin error accumulation
        ST_ERR_MUL,         // e[j] * k[j]
        ST_ERR_MUL_WAIT,
        ST_ERR_ADD,         // accum += e[j] * k[j]
        ST_ERR_ADD_WAIT,
        ST_ERR_NEXT,        // Advance j
        ST_ERR_H_MUL,      // err = h * accum
        ST_ERR_H_MUL_WAIT,
        ST_DONE
    } state_t;

    state_t      state;
    logic [2:0]  current_stage;
    int          err_j;             // error accumulation index
    logic [63:0] err_accum;
    logic        launched;

    // Latched inputs
    logic [63:0] x_r, y_r, h_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            done         <= 1'b0;
            stage_start  <= 1'b0;
            mul_valid_in <= 1'b0;
            as_valid_in  <= 1'b0;
            launched     <= 1'b0;
        end else begin
            stage_start  <= 1'b0;
            mul_valid_in <= 1'b0;
            as_valid_in  <= 1'b0;
            done         <= 1'b0;

            case (state)

                // ---------------------------------------------------------
                ST_IDLE: begin
                    if (start) begin
                        x_r           <= x_n;
                        y_r           <= y_n;
                        h_r           <= h;
                        current_stage <= 3'd0;
                        launched      <= 1'b0;
                        for (int i = 0; i < 7; i++)
                            k_array[i] <= `FP64_ZERO;
                        state <= ST_COMPUTE_STAGE;
                    end
                end

                // ---------------------------------------------------------
                // Launch the stage engine
                // ---------------------------------------------------------
                ST_COMPUTE_STAGE: begin
                    stage_idx   <= current_stage;
                    stage_start <= 1'b1;
                    state       <= ST_WAIT_STAGE;
                end

                ST_WAIT_STAGE: begin
                    if (stage_done) begin
                        state <= ST_STORE_K;
                    end
                end

                // ---------------------------------------------------------
                // Store k[current_stage] and decide next action
                // ---------------------------------------------------------
                ST_STORE_K: begin
                    k_array[current_stage] <= stage_k_out;

                    if (current_stage == 3'd6) begin
                        // Stage 6 (k7) uses b-weights as a-coefficients, so
                        // y_stage = y_n + h*(b1*k1 + b3*k3 + b4*k4 + b5*k5 + b6*k6)
                        // which IS the 5th-order y_next (b2=b7=0).
                        y_next <= stage_y_out;
                        k7_out <= stage_k_out;
                        state  <= ST_ERR_INIT;
                    end else begin
                        current_stage <= current_stage + 3'd1;
                        state         <= ST_COMPUTE_STAGE;
                    end
                end

                // ---------------------------------------------------------
                // Error accumulation: err = h * Σ(e_i * k_i, i=1..7)
                // ---------------------------------------------------------
                ST_ERR_INIT: begin
                    err_j    <= 0;
                    err_accum <= `FP64_ZERO;
                    launched <= 1'b0;
                    state    <= ST_ERR_MUL;
                end

                // Compute e[j] * k[j]
                ST_ERR_MUL: begin
                    if (!launched) begin
                        mul_a        <= get_e_coeff(err_j);
                        mul_b        <= k_array[err_j];
                        mul_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (mul_valid_out) begin
                        launched <= 1'b0;
                        // Skip accumulation for zero-coefficient terms
                        if (get_e_coeff(err_j) == `FP64_ZERO)
                            state <= ST_ERR_NEXT;
                        else
                            state <= ST_ERR_ADD;
                    end
                end

                // accum += e[j] * k[j]
                ST_ERR_ADD: begin
                    if (!launched) begin
                        as_a        <= err_accum;
                        as_b        <= mul_result;
                        as_is_sub   <= 1'b0;
                        as_valid_in <= 1'b1;
                        launched    <= 1'b1;
                    end
                    if (as_valid_out) begin
                        err_accum <= as_result;
                        launched  <= 1'b0;
                        state     <= ST_ERR_NEXT;
                    end
                end

                ST_ERR_NEXT: begin
                    if (err_j == 6)
                        state <= ST_ERR_H_MUL;
                    else begin
                        err_j <= err_j + 1;
                        state <= ST_ERR_MUL;
                    end
                end

                // err_est = h * accum
                ST_ERR_H_MUL: begin
                    if (!launched) begin
                        mul_a        <= h_r;
                        mul_b        <= err_accum;
                        mul_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (mul_valid_out) begin
                        err_est  <= mul_result;
                        launched <= 1'b0;
                        state    <= ST_DONE;
                    end
                end

                // ---------------------------------------------------------
                ST_DONE: begin
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end

            endcase
        end
    end

endmodule
