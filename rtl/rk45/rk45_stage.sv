// =============================================================================
// rk45_stage.sv — Compute One Dormand-Prince RK45 Stage (ki)
// =============================================================================
// For a given stage index s ∈ {1..7}, computes:
//
//   y_stage = y_n + h * Σ(a[s][j] * k[j],  j = 1..s-1)
//   x_stage = x_n + c[s] * h
//   k[s]    = f(x_stage, y_stage)
//
// The multiply-accumulate is sequential: for each j, compute a[s][j]*k[j],
// then accumulate with running sum. This reuses a single fp_mul and fp_add_sub.
//
// Interface:
//   - Assert start HIGH for 1 cycle with stable inputs.
//   - k_out becomes valid when done pulses HIGH.
//   - Do not assert start again until done has been seen.
//
// The stage index selects the appropriate Butcher tableau coefficients from
// rk45_constants_pkg. Stage 1 (s=0) has no accumulation — it calls f(x_n, y_n)
// directly.
// =============================================================================

`include "fp_pkg.svh"

import rk45_constants_pkg::*;

module rk45_stage (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [2:0]  stage,      // 0=k1, 1=k2, ..., 6=k7
    input  logic [63:0] x_n,        // current x
    input  logic [63:0] y_n,        // current y
    input  logic [63:0] h,          // current step size
    input  logic [63:0] k [0:6],    // previously computed ki values
    output logic [63:0] k_out,      // computed k[stage]
    output logic [63:0] y_stage_out,// y_n + h*Σ(a*k) before ODE call (valid at done)
    output logic        done
);

    // -------------------------------------------------------------------------
    // FP unit ports (shared multiply and add/sub)
    // -------------------------------------------------------------------------
    logic        mul_valid_in,  mul_valid_out;
    logic [63:0] mul_a, mul_b,  mul_result;

    logic        as_valid_in,   as_valid_out;
    logic [63:0] as_a, as_b,    as_result;
    logic        as_is_sub;

    fp_mul fp_mul_i (
        .clk(clk), .valid_in(mul_valid_in),
        .a(mul_a), .b(mul_b), .result(mul_result), .valid_out(mul_valid_out)
    );

    fp_add_sub fp_add_sub_i (
        .clk(clk), .valid_in(as_valid_in),
        .a(as_a), .b(as_b), .is_sub(as_is_sub),
        .result(as_result), .valid_out(as_valid_out)
    );

    // -------------------------------------------------------------------------
    // ODE function instance
    // -------------------------------------------------------------------------
    logic        ode_valid_in, ode_valid_out;
    logic [63:0] ode_x, ode_y, ode_result;

    ode_func ode_func_i (
        .clk(clk), .rst_n(rst_n),
        .valid_in(ode_valid_in), .x(ode_x), .y(ode_y),
        .f_xy(ode_result), .valid_out(ode_valid_out)
    );

    // -------------------------------------------------------------------------
    // Butcher tableau coefficient lookup
    // -------------------------------------------------------------------------
    // Max coefficients per stage: stage 6 has 5 terms (a61..a65)
    // Stored as flattened array indexed by [stage][j]

    // Number of a-coefficients for each stage
    function automatic int n_terms(input logic [2:0] s);
        case (s)
            3'd0: return 0;    // k1: no prior terms
            3'd1: return 1;    // k2: a21
            3'd2: return 2;    // k3: a31, a32
            3'd3: return 3;    // k4: a41..a43
            3'd4: return 4;    // k5: a51..a54
            3'd5: return 5;    // k6: a61..a65
            3'd6: return 6;    // k7: b1..b6 (same as 5th-order weights)
            default: return 0;
        endcase
    endfunction

    // Get a-coefficient for stage s, term index j (0-based)
    function automatic logic [63:0] get_a_coeff(input logic [2:0] s, input int j);
        case (s)
            3'd1: return A21_B;                                       // k2
            3'd2: case (j) 0: return A31_B; 1: return A32_B;         // k3
                   default: return `FP64_ZERO; endcase
            3'd3: case (j) 0: return A41_B; 1: return A42_B;
                           2: return A43_B;                           // k4
                   default: return `FP64_ZERO; endcase
            3'd4: case (j) 0: return A51_B; 1: return A52_B;
                           2: return A53_B; 3: return A54_B;          // k5
                   default: return `FP64_ZERO; endcase
            3'd5: case (j) 0: return A61_B; 1: return A62_B;
                           2: return A63_B; 3: return A64_B;
                           4: return A65_B;                           // k6
                   default: return `FP64_ZERO; endcase
            3'd6: case (j) 0: return B1_B;  1: return `FP64_ZERO;    // k7 uses b weights
                           2: return B3_B;  3: return B4_B;
                           4: return B5_B;  5: return B6_B;
                   default: return `FP64_ZERO; endcase
            default: return `FP64_ZERO;
        endcase
    endfunction

    // Get c-node for stage s
    function automatic logic [63:0] get_c(input logic [2:0] s);
        case (s)
            3'd0: return `FP64_ZERO;
            3'd1: return C2_B;
            3'd2: return C3_B;
            3'd3: return C4_B;
            3'd4: return C5_B;
            3'd5: return `FP64_ONE;     // c6 = 1
            3'd6: return `FP64_ONE;     // c7 = 1
            default: return `FP64_ZERO;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_DIRECT_ODE,      // Stage 0: skip accumulation, call f(x_n, y_n)
        ST_MUL_AK,          // Compute a[s][j] * k[j]
        ST_ADD_ACCUM,       // accumulator += a[s][j] * k[j]
        ST_NEXT_J,          // Advance j, check if more terms
        ST_H_MUL_ACCUM,    // Multiply accumulator by h
        ST_COMPUTE_XSTAGE,  // x_stage = x_n + c[s]*h  (start multiply c*h)
        ST_XSTAGE_ADD,      // x_stage = x_n + (c*h)
        ST_ADD_Y,           // y_stage = y_n + h*accum
        ST_CALL_ODE,        // Call f(x_stage, y_stage)
        ST_DONE
    } state_t;

    state_t      state;
    int          j;             // current term index in accumulation
    int          n;             // number of terms for this stage
    logic [63:0] accum;         // running sum: Σ a[s][j]*k[j]
    logic [63:0] x_stage;
    logic [63:0] y_stage;
    logic [2:0]  stage_r;       // latched stage
    logic [63:0] x_r, y_r, h_r;
    logic [63:0] k_r [0:6];
    logic        launched;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            done         <= 1'b0;
            launched     <= 1'b0;
            mul_valid_in <= 1'b0;
            as_valid_in  <= 1'b0;
            ode_valid_in <= 1'b0;
        end else begin
            mul_valid_in <= 1'b0;
            as_valid_in  <= 1'b0;
            ode_valid_in <= 1'b0;
            done         <= 1'b0;

            case (state)

                // ---------------------------------------------------------
                ST_IDLE: begin
                    if (start) begin
                        stage_r  <= stage;
                        x_r      <= x_n;
                        y_r      <= y_n;
                        h_r      <= h;
                        for (int i = 0; i < 7; i++) k_r[i] <= k[i];
                        n        <= n_terms(stage);
                        j        <= 0;
                        accum    <= `FP64_ZERO;
                        launched <= 1'b0;

                        if (stage == 3'd0)
                            state <= ST_DIRECT_ODE;
                        else
                            state <= ST_MUL_AK;
                    end
                end

                // ---------------------------------------------------------
                // Stage 1 (k1): no accumulation, just f(x_n, y_n)
                // ---------------------------------------------------------
                ST_DIRECT_ODE: begin
                    if (!launched) begin
                        ode_x        <= x_r;
                        ode_y        <= y_r;
                        ode_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (ode_valid_out) begin
                        k_out    <= ode_result;
                        launched <= 1'b0;
                        state    <= ST_DONE;
                    end
                end

                // ---------------------------------------------------------
                // Multiply-accumulate loop: accum += a[s][j] * k[j]
                // ---------------------------------------------------------
                ST_MUL_AK: begin
                    if (!launched) begin
                        mul_a        <= get_a_coeff(stage_r, j);
                        mul_b        <= k_r[j];
                        mul_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (mul_valid_out) begin
                        launched <= 1'b0;
                        // Skip zero-coefficient terms (B2 = 0 for k7 stage)
                        if (get_a_coeff(stage_r, j) == `FP64_ZERO)
                            state <= ST_NEXT_J;
                        else
                            state <= ST_ADD_ACCUM;
                    end
                end

                ST_ADD_ACCUM: begin
                    if (!launched) begin
                        as_a        <= accum;
                        as_b        <= mul_result;
                        as_is_sub   <= 1'b0;
                        as_valid_in <= 1'b1;
                        launched    <= 1'b1;
                    end
                    if (as_valid_out) begin
                        accum    <= as_result;
                        launched <= 1'b0;
                        state    <= ST_NEXT_J;
                    end
                end

                ST_NEXT_J: begin
                    j <= j + 1;
                    if (j + 1 >= n)
                        state <= ST_H_MUL_ACCUM;
                    else
                        state <= ST_MUL_AK;
                end

                // ---------------------------------------------------------
                // Multiply accumulated sum by h: h_accum = h * accum
                // ---------------------------------------------------------
                ST_H_MUL_ACCUM: begin
                    if (!launched) begin
                        mul_a        <= h_r;
                        mul_b        <= accum;
                        mul_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (mul_valid_out) begin
                        accum    <= mul_result;  // now holds h * Σ(a*k)
                        launched <= 1'b0;
                        state    <= ST_COMPUTE_XSTAGE;
                    end
                end

                // ---------------------------------------------------------
                // Compute x_stage = x_n + c[s] * h
                // ---------------------------------------------------------
                ST_COMPUTE_XSTAGE: begin
                    if (!launched) begin
                        mul_a        <= get_c(stage_r);
                        mul_b        <= h_r;
                        mul_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (mul_valid_out) begin
                        launched <= 1'b0;
                        state    <= ST_XSTAGE_ADD;
                    end
                end

                ST_XSTAGE_ADD: begin
                    if (!launched) begin
                        as_a        <= x_r;
                        as_b        <= mul_result;
                        as_is_sub   <= 1'b0;
                        as_valid_in <= 1'b1;
                        launched    <= 1'b1;
                    end
                    if (as_valid_out) begin
                        x_stage  <= as_result;
                        launched <= 1'b0;
                        state    <= ST_ADD_Y;
                    end
                end

                // ---------------------------------------------------------
                // Compute y_stage = y_n + h * accum
                // ---------------------------------------------------------
                ST_ADD_Y: begin
                    if (!launched) begin
                        as_a        <= y_r;
                        as_b        <= accum;  // already h * Σ(a*k)
                        as_is_sub   <= 1'b0;
                        as_valid_in <= 1'b1;
                        launched    <= 1'b1;
                    end
                    if (as_valid_out) begin
                        y_stage  <= as_result;
                        launched <= 1'b0;
                        state    <= ST_CALL_ODE;
                    end
                end

                // ---------------------------------------------------------
                // Call ODE function: k[s] = f(x_stage, y_stage)
                // ---------------------------------------------------------
                ST_CALL_ODE: begin
                    if (!launched) begin
                        ode_x        <= x_stage;
                        ode_y        <= y_stage;
                        ode_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (ode_valid_out) begin
                        k_out    <= ode_result;
                        launched <= 1'b0;
                        state    <= ST_DONE;
                    end
                end

                // ---------------------------------------------------------
                ST_DONE: begin
                    done        <= 1'b1;
                    y_stage_out <= y_stage;
                    state       <= ST_IDLE;
                end

            endcase
        end
    end

endmodule
