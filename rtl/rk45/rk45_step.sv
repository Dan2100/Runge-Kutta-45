// =============================================================================
// rk45_step.sv — Full Dormand-Prince RK45 Step (k1–k7 + Error Estimate)
// =============================================================================
// Orchestrates one complete RK45 step attempt:
//   1. Compute k1 through k6 via rk45_stage (sequentially)
//   2. Launch k7 stage AND begin error accumulation for k[0..5] in parallel
//   3. After k7 completes, fold in e7*k7 and compute err_est = h * err_sum
//   4. y_next comes from k7 stage (b-weights as a-coefficients)
//
// Phase B optimization: error terms e[0..5]*k[0..5] are computed during
// k7 computation using separate FP units (fp_mul_err, fp_as_err), hiding
// ~108 cycles of error work behind k7's ~130+ cycle computation.
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

    // ODE engine program (static during integration)
    input  logic [15:0] ode_prog_mem   [0:15],
    input  logic [63:0] ode_const_regs [0:5],
    input  logic [3:0]  ode_prog_len,
    input  logic [2:0]  ode_result_reg,

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
        .clk            (clk),
        .rst_n          (rst_n),
        .start          (stage_start),
        .stage          (stage_idx),
        .x_n            (x_n),
        .y_n            (y_n),
        .h              (h),
        .k              (k_array),
        .ode_prog_mem   (ode_prog_mem),
        .ode_const_regs (ode_const_regs),
        .ode_prog_len   (ode_prog_len),
        .ode_result_reg (ode_result_reg),
        .k_out          (stage_k_out),
        .y_stage_out    (stage_y_out),
        .done           (stage_done)
    );

    // -------------------------------------------------------------------------
    // Separate FP units for error accumulation (independent of stage engine)
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
        ST_K7_ERR_START,    // Launch k7 + init error loop for k[0..5]
        ST_ERR_MUL,         // e[j] * k[j]  (j = 0..5, overlapped with k7)
        ST_ERR_ADD,         // accum += e[j] * k[j]
        ST_ERR_NEXT,        // Advance j; if j>5, wait for k7
        ST_WAIT_K7,         // Wait for k7 stage_done (if not already done)
        ST_FOLD_K7_MUL,     // Compute e7 * k7
        ST_FOLD_K7_ADD,     // accum += e7 * k7
        ST_ERR_H_MUL,       // err_est = h * accum
        ST_DONE
    } state_t;

    state_t      state;
    logic [2:0]  current_stage;
    int          err_j;             // error accumulation index (0..5 during overlap)
    logic [63:0] err_accum;
    logic        launched;
    logic        k7_done;           // captures stage_done during error loop

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
            k7_done      <= 1'b0;
        end else begin
            stage_start  <= 1'b0;
            mul_valid_in <= 1'b0;
            as_valid_in  <= 1'b0;
            done         <= 1'b0;

            // ---- Capture k7 completion during error loop states ----
            // stage_done is a 1-cycle pulse; capture it whenever it fires
            // during the overlapped error computation.
            if ((state == ST_ERR_MUL || state == ST_ERR_ADD ||
                 state == ST_ERR_NEXT || state == ST_WAIT_K7) &&
                stage_done && !k7_done) begin
                k_array[6] <= stage_k_out;
                y_next     <= stage_y_out;
                k7_out     <= stage_k_out;
                k7_done    <= 1'b1;
            end

            case (state)

                // ---------------------------------------------------------
                ST_IDLE: begin
                    if (start) begin
                        x_r           <= x_n;
                        y_r           <= y_n;
                        h_r           <= h;
                        current_stage <= 3'd0;
                        launched      <= 1'b0;
                        k7_done       <= 1'b0;
                        for (int i = 0; i < 7; i++)
                            k_array[i] <= `FP64_ZERO;
                        state <= ST_COMPUTE_STAGE;
                    end
                end

                // ---------------------------------------------------------
                // Launch the stage engine (stages 0–5 only)
                // ---------------------------------------------------------
                ST_COMPUTE_STAGE: begin
                    stage_idx   <= current_stage;
                    stage_start <= 1'b1;
                    state       <= ST_WAIT_STAGE;
                end

                ST_WAIT_STAGE: begin
                    if (stage_done)
                        state <= ST_STORE_K;
                end

                // ---------------------------------------------------------
                // Store k[current_stage] and decide next action
                // ---------------------------------------------------------
                ST_STORE_K: begin
                    k_array[current_stage] <= stage_k_out;

                    if (current_stage == 3'd5) begin
                        // k6 done — launch k7 AND start error accumulation
                        state <= ST_K7_ERR_START;
                    end else begin
                        current_stage <= current_stage + 3'd1;
                        state         <= ST_COMPUTE_STAGE;
                    end
                end

                // ---------------------------------------------------------
                // Launch k7 stage + initialize error loop
                // ---------------------------------------------------------
                ST_K7_ERR_START: begin
                    // Launch k7 via stage engine
                    stage_idx   <= 3'd6;
                    stage_start <= 1'b1;

                    // Initialize error accumulation for j = 0..5
                    err_j     <= 0;
                    err_accum <= `FP64_ZERO;
                    launched  <= 1'b0;
                    k7_done   <= 1'b0;

                    state <= ST_ERR_MUL;
                end

                // ---------------------------------------------------------
                // Error loop (runs in parallel with k7 stage engine)
                // Compute e[j] * k[j] for j = 0..5
                // ---------------------------------------------------------
                ST_ERR_MUL: begin
                    if (!launched) begin
                        mul_a        <= get_e_coeff(err_j);
                        mul_b        <= k_array[err_j];
                        mul_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (mul_valid_out) begin
                        launched <= 1'b0;
                        // Skip accumulation for zero-coefficient terms (E2=0)
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

                // Advance j; loop while j < 6
                ST_ERR_NEXT: begin
                    if (err_j == 5) begin
                        // Partial error (j=0..5) complete. Need k7 now.
                        launched <= 1'b0;
                        if (k7_done)
                            state <= ST_FOLD_K7_MUL;
                        else
                            state <= ST_WAIT_K7;
                    end else begin
                        err_j <= err_j + 1;
                        state <= ST_ERR_MUL;
                    end
                end

                // ---------------------------------------------------------
                // Wait for k7 stage to complete (if not already captured)
                // ---------------------------------------------------------
                ST_WAIT_K7: begin
                    // k7_done is set by the capture logic above
                    if (k7_done) begin
                        launched <= 1'b0;
                        state    <= ST_FOLD_K7_MUL;
                    end
                end

                // ---------------------------------------------------------
                // Fold in e7 * k7
                // ---------------------------------------------------------
                ST_FOLD_K7_MUL: begin
                    if (!launched) begin
                        mul_a        <= E7_B;
                        mul_b        <= k_array[6];
                        mul_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (mul_valid_out) begin
                        launched <= 1'b0;
                        state    <= ST_FOLD_K7_ADD;
                    end
                end

                ST_FOLD_K7_ADD: begin
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
                        state     <= ST_ERR_H_MUL;
                    end
                end

                // ---------------------------------------------------------
                // err_est = h * accum
                // ---------------------------------------------------------
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
