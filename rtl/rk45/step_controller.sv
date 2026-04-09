// =============================================================================
// step_controller.sv — Adaptive Step-Size Controller for RK45
// =============================================================================
// Decides accept/reject for a completed RK45 step attempt and computes the
// new step size h_new.
//
// Algorithm:
//   sc  = atol + rtol * max(|y_n|, |y_next|)
//   err_norm = |err_est| / sc
//   if (err_norm <= 1.0):
//       accept = 1
//   else:
//       accept = 0
//   scale = 0.9 * err_norm^(-0.2)              [safety-dampened]
//   scale = clamp(scale, MIN_SCALE, MAX_SCALE)  [0.2 .. 10.0]
//   h_new = h * scale
//   h_new = min(h_new, x_end - x_current)       [don't overshoot]
//
// Sequential operation using shared FP units and fp_pow_neg0p2.
//
// Interface:
//   - Assert start HIGH for 1 cycle with stable inputs.
//   - accept and h_new are valid when done pulses HIGH.
// =============================================================================

`include "fp_pkg.svh"

import rk45_constants_pkg::*;

module step_controller (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,

    input  logic [63:0] y_n,        // current y
    input  logic [63:0] y_next,     // proposed next y (5th-order)
    input  logic [63:0] err_est,    // error estimate from rk45_step
    input  logic [63:0] h,          // current step size
    input  logic [63:0] x_current,  // current x (after step: x_n + h)
    input  logic [63:0] x_end,      // integration end point
    input  logic [63:0] rtol,
    input  logic [63:0] atol,

    output logic        accept,     // 1 = accept step, 0 = reject
    output logic [63:0] h_new,      // new step size
    output logic        done
);

    // -------------------------------------------------------------------------
    // FP unit instances (private to this module)
    // -------------------------------------------------------------------------
    logic        mul_valid_in,  mul_valid_out;
    logic [63:0] mul_a, mul_b,  mul_result;

    logic        as_valid_in,   as_valid_out;
    logic [63:0] as_a, as_b,    as_result;
    logic        as_is_sub;

    logic        div_valid_in,  div_valid_out;
    logic [63:0] div_a, div_b,  div_result;

    logic        cmp_valid_in,  cmp_valid_out;
    logic [63:0] cmp_a, cmp_b;
    logic        cmp_gt;

    fp_mul     fp_mul_i     (.clk(clk), .valid_in(mul_valid_in),
                              .a(mul_a), .b(mul_b), .result(mul_result), .valid_out(mul_valid_out));
    fp_add_sub fp_add_sub_i (.clk(clk), .valid_in(as_valid_in),
                              .a(as_a), .b(as_b), .is_sub(as_is_sub),
                              .result(as_result), .valid_out(as_valid_out));
    fp_div     fp_div_i     (.clk(clk), .valid_in(div_valid_in),
                              .a(div_a), .b(div_b), .result(div_result), .valid_out(div_valid_out));
    fp_compare fp_cmp_i     (.clk(clk), .valid_in(cmp_valid_in),
                              .a(cmp_a), .b(cmp_b), .a_gt_b(cmp_gt), .valid_out(cmp_valid_out));

    // fp_pow_neg0p2 instance
    logic        pow_valid_in, pow_valid_out;
    logic [63:0] pow_x, pow_result;

    fp_pow_neg0p2 fp_pow_i (
        .clk(clk), .rst_n(rst_n),
        .valid_in(pow_valid_in), .x(pow_x),
        .result(pow_result), .valid_out(pow_valid_out)
    );

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    typedef enum logic [4:0] {
        ST_IDLE,
        ST_ABS_YN,         // |y_n|
        ST_ABS_YNEXT,      // |y_next|
        ST_CMP_YS,         // compare |y_n| > |y_next|
        ST_CMP_WAIT,
        ST_MUL_RTOL,       // rtol * max(|y_n|, |y_next|)
        ST_MUL_WAIT,
        ST_ADD_ATOL,       // sc = atol + rtol*max_y
        ST_ADD_WAIT,
        ST_ABS_ERR,        // |err_est|
        ST_DIV_ERR,        // err_norm = |err_est| / sc
        ST_DIV_WAIT,
        ST_CMP_ERR,        // err_norm <= 1.0?
        ST_CMP_ERR_WAIT,
        ST_POW,            // err_norm^(-0.2)
        ST_POW_WAIT,
        ST_MUL_SAFETY,     // scale = 0.9 * pow_result
        ST_MUL_SAFETY_WAIT,
        ST_CLAMP_LO,       // clamp scale >= MIN_SCALE
        ST_CLAMP_LO_WAIT,
        ST_CLAMP_HI,       // clamp scale <= MAX_SCALE
        ST_CLAMP_HI_WAIT,
        ST_MUL_H,          // h_new = h * scale
        ST_MUL_H_WAIT,
        ST_LIMIT_XEND,     // h_new = min(h_new, x_end - x_current)
        ST_LIMIT_SUB,
        ST_LIMIT_SUB_WAIT,
        ST_LIMIT_CMP,
        ST_LIMIT_CMP_WAIT,
        ST_DONE
    } state_t;

    state_t state;
    logic   launched;

    // Intermediate values
    logic [63:0] abs_yn, abs_ynext, max_y;
    logic [63:0] sc;                // tolerance scale: atol + rtol*max_y
    logic [63:0] abs_err;           // |err_est|
    logic [63:0] err_norm;
    logic [63:0] scale;             // step-size scale factor
    logic [63:0] h_candidate;
    logic [63:0] x_remain;          // x_end - x_current

    // Latched inputs
    logic [63:0] h_r, x_cur_r, x_end_r, rtol_r, atol_r, err_r;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            done         <= 1'b0;
            launched     <= 1'b0;
            mul_valid_in <= 1'b0;
            as_valid_in  <= 1'b0;
            div_valid_in <= 1'b0;
            cmp_valid_in <= 1'b0;
            pow_valid_in <= 1'b0;
        end else begin
            mul_valid_in <= 1'b0;
            as_valid_in  <= 1'b0;
            div_valid_in <= 1'b0;
            cmp_valid_in <= 1'b0;
            pow_valid_in <= 1'b0;
            done         <= 1'b0;

            case (state)

                ST_IDLE: begin
                    if (start) begin
                        h_r     <= h;
                        x_cur_r <= x_current;
                        x_end_r <= x_end;
                        rtol_r  <= rtol;
                        atol_r  <= atol;
                        err_r   <= err_est;
                        launched <= 1'b0;

                        // Compute |y_n| and |y_next| (combinational via fp_abs)
                        abs_yn    <= y_n    & ~`FP64_SIGN_MASK;
                        abs_ynext <= y_next & ~`FP64_SIGN_MASK;
                        abs_err   <= err_est & ~`FP64_SIGN_MASK;

                        state <= ST_CMP_YS;
                    end
                end

                // Compare |y_n| > |y_next| to find max
                ST_CMP_YS: begin
                    if (!launched) begin
                        cmp_a        <= abs_yn;
                        cmp_b        <= abs_ynext;
                        cmp_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (cmp_valid_out) begin
                        max_y    <= cmp_gt ? abs_yn : abs_ynext;
                        launched <= 1'b0;
                        state    <= ST_MUL_RTOL;
                    end
                end

                // rtol * max(|y_n|, |y_next|)
                ST_MUL_RTOL: begin
                    if (!launched) begin
                        mul_a        <= rtol_r;
                        mul_b        <= max_y;
                        mul_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (mul_valid_out) begin
                        launched <= 1'b0;
                        state    <= ST_ADD_ATOL;
                    end
                end

                // sc = atol + rtol * max_y
                ST_ADD_ATOL: begin
                    if (!launched) begin
                        as_a        <= atol_r;
                        as_b        <= mul_result;
                        as_is_sub   <= 1'b0;
                        as_valid_in <= 1'b1;
                        launched    <= 1'b1;
                    end
                    if (as_valid_out) begin
                        sc       <= as_result;
                        launched <= 1'b0;
                        state    <= ST_DIV_ERR;
                    end
                end

                // err_norm = |err_est| / sc
                ST_DIV_ERR: begin
                    if (!launched) begin
                        div_a        <= abs_err;
                        div_b        <= sc;
                        div_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (div_valid_out) begin
                        err_norm <= div_result;
                        launched <= 1'b0;
                        state    <= ST_CMP_ERR;
                    end
                end

                // err_norm <= 1.0?  (check: 1.0 >= err_norm, i.e., !(err_norm > 1.0))
                ST_CMP_ERR: begin
                    if (!launched) begin
                        cmp_a        <= err_norm;
                        cmp_b        <= `FP64_ONE;
                        cmp_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (cmp_valid_out) begin
                        accept   <= ~cmp_gt;  // accept if err_norm <= 1.0
                        launched <= 1'b0;
                        state    <= ST_POW;
                    end
                end

                // Compute err_norm^(-0.2)
                // Guard: if err_norm ≈ 0, set scale to MAX_SCALE
                ST_POW: begin
                    if (err_norm == `FP64_ZERO) begin
                        scale    <= MAX_SCALE_B;
                        launched <= 1'b0;
                        state    <= ST_MUL_H;
                    end else begin
                        if (!launched) begin
                            pow_x        <= err_norm;
                            pow_valid_in <= 1'b1;
                            launched     <= 1'b1;
                        end
                        if (pow_valid_out) begin
                            launched <= 1'b0;
                            state    <= ST_MUL_SAFETY;
                        end
                    end
                end

                // scale = 0.9 * err_norm^(-0.2)
                ST_MUL_SAFETY: begin
                    if (!launched) begin
                        mul_a        <= SAFETY_B;
                        mul_b        <= pow_result;
                        mul_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (mul_valid_out) begin
                        scale    <= mul_result;
                        launched <= 1'b0;
                        state    <= ST_CLAMP_LO;
                    end
                end

                // Clamp: scale >= MIN_SCALE (0.2)
                ST_CLAMP_LO: begin
                    if (!launched) begin
                        cmp_a        <= MIN_SCALE_B;
                        cmp_b        <= scale;
                        cmp_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (cmp_valid_out) begin
                        // If MIN_SCALE > scale, replace scale with MIN_SCALE
                        if (cmp_gt)
                            scale <= MIN_SCALE_B;
                        launched <= 1'b0;
                        state    <= ST_CLAMP_HI;
                    end
                end

                // Clamp: scale <= MAX_SCALE (10.0)
                ST_CLAMP_HI: begin
                    if (!launched) begin
                        cmp_a        <= scale;
                        cmp_b        <= MAX_SCALE_B;
                        cmp_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (cmp_valid_out) begin
                        // If scale > MAX_SCALE, replace scale with MAX_SCALE
                        if (cmp_gt)
                            scale <= MAX_SCALE_B;
                        launched <= 1'b0;
                        state    <= ST_MUL_H;
                    end
                end

                // h_new = h * scale
                ST_MUL_H: begin
                    if (!launched) begin
                        mul_a        <= h_r;
                        mul_b        <= scale;
                        mul_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (mul_valid_out) begin
                        h_candidate <= mul_result;
                        launched    <= 1'b0;
                        state       <= ST_LIMIT_XEND;
                    end
                end

                // Ensure h_new doesn't overshoot x_end
                // x_remain = x_end - x_current
                ST_LIMIT_XEND: begin
                    if (!launched) begin
                        as_a        <= x_end_r;
                        as_b        <= x_cur_r;
                        as_is_sub   <= 1'b1;
                        as_valid_in <= 1'b1;
                        launched    <= 1'b1;
                    end
                    if (as_valid_out) begin
                        x_remain <= as_result;
                        launched <= 1'b0;
                        state    <= ST_LIMIT_CMP;
                    end
                end

                // If h_candidate > x_remain, use x_remain
                ST_LIMIT_CMP: begin
                    if (!launched) begin
                        cmp_a        <= h_candidate;
                        cmp_b        <= x_remain;
                        cmp_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (cmp_valid_out) begin
                        h_new    <= cmp_gt ? x_remain : h_candidate;
                        launched <= 1'b0;
                        state    <= ST_DONE;
                    end
                end

                ST_DONE: begin
                    done  <= 1'b1;
                    state <= ST_IDLE;
                end

            endcase
        end
    end

endmodule
