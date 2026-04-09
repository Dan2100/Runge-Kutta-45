// =============================================================================
// fp_pow_neg0p2.sv — Computes x^(-0.2) via Newton's Method
// =============================================================================
// Computes y = x^(-1/5) for use in the RK45 adaptive step-size controller:
//   h_new = 0.9 * h * err_norm^(-0.2)
//
// Algorithm: Newton iteration on f(z) = z^5 * x - 1 = 0
//   z_{n+1} = z_n * (6 - x * z_n^5) / 5
//           = z_n * (6 - x * z_n^5) * 0.2
//
// Seed strategy:
//   x = 2^(e-1023) * mantissa   (IEEE 754 double)
//   x^(-1/5) ≈ 2^(-(e-1023)/5)
//   Seed exponent (biased) = (6138 - e_biased) / 5  [integer division]
//   Seed mantissa = 1.0 (all zeros)
//
//   This places the seed within a factor of 2^0.2 ≈ 1.15 of the true value,
//   ensuring convergence for all positive x. 4 Newton iterations then give
//   >15 correct decimal digits.
//
// Per iteration: 6× fp_mul + 1× fp_add_sub ≈ 47 clock cycles
// Total (4 iterations): ≈ 188 clock cycles
//
// Interface:
//   - Assert valid_in HIGH for 1 cycle while x is stable (x must be > 0).
//   - valid_out pulses HIGH when result is ready.
//   - Do not assert valid_in again until valid_out has been seen.
//
// This module instantiates its own fp_mul and fp_add_sub units internally.
// It does NOT share FP resources with the parent RK45 datapath.
// =============================================================================

`include "fp_pkg.svh"

module fp_pow_neg0p2 (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [63:0] x,          // must be > 0
    output logic [63:0] result,     // x^(-0.2)
    output logic        valid_out
);

    // -------------------------------------------------------------------------
    // Internal FP unit ports
    // -------------------------------------------------------------------------
    logic        mul_valid_in,  mul_valid_out;
    logic [63:0] mul_a, mul_b,  mul_result;

    logic        as_valid_in,   as_valid_out;
    logic [63:0] as_a, as_b,    as_result;
    logic        as_is_sub;

    fp_mul fp_mul_i (
        .clk       (clk),
        .valid_in  (mul_valid_in),
        .a         (mul_a),
        .b         (mul_b),
        .result    (mul_result),
        .valid_out (mul_valid_out)
    );

    fp_add_sub fp_add_sub_i (
        .clk       (clk),
        .valid_in  (as_valid_in),
        .a         (as_a),
        .b         (as_b),
        .is_sub    (as_is_sub),
        .result    (as_result),
        .valid_out (as_valid_out)
    );

    // -------------------------------------------------------------------------
    // Exponent-based seed computation (combinational)
    // -------------------------------------------------------------------------
    // For x = 2^(e-1023) * m, x^(-1/5) ≈ 2^(-(e-1023)/5)
    // Target biased exponent = (6138 - e) / 5, where 6138 = 6 * 1023
    logic [12:0] seed_exp_calc;
    logic [12:0] seed_exp_div5;
    logic [63:0] z_seed;

    always_comb begin
        seed_exp_calc = 13'd6138 - {2'b0, x[62:52]};
        seed_exp_div5 = seed_exp_calc / 5;
        z_seed = {1'b0, seed_exp_div5[10:0], 52'b0};
    end

    // -------------------------------------------------------------------------
    // State machine
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_Z2,          // z2  = z  * z
        ST_Z4,          // z4  = z2 * z2
        ST_Z5,          // z5  = z4 * z
        ST_XZ5,         // xz5 = x  * z5
        ST_SIX_MINUS,   // t   = 6.0 - xz5
        ST_ZT,          // zt  = z  * t
        ST_SCALE,       // z   = zt * 0.2  → new z
        ST_CHECK,       // iter done? → repeat or finish
        ST_DONE
    } state_t;

    localparam int NUM_ITERS = 8;

    state_t      state;
    logic [3:0]  iter;          // iteration counter
    logic        launched;      // prevents re-issuing current op

    // Intermediate registers
    logic [63:0] z, z2, z4, z5, xz5_r, t_r, zt_r;
    logic [63:0] x_r;           // latched input

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            valid_out   <= 1'b0;
            launched    <= 1'b0;
            iter        <= 4'd0;
            mul_valid_in <= 1'b0;
            as_valid_in  <= 1'b0;
        end else begin
            // Default: deassert strobes
            mul_valid_in <= 1'b0;
            as_valid_in  <= 1'b0;
            valid_out    <= 1'b0;

            case (state)

                // ---------------------------------------------------------
                ST_IDLE: begin
                    if (valid_in) begin
                        z        <= z_seed;
                        x_r      <= x;
                        iter     <= 4'd0;
                        launched <= 1'b0;
                        state    <= ST_Z2;
                    end
                end

                // ---------------------------------------------------------
                // Each compute state: issue op on first cycle (launched=0),
                // then wait for valid_out from the FP unit.
                // ---------------------------------------------------------

                ST_Z2: begin
                    if (!launched) begin
                        mul_a        <= z;
                        mul_b        <= z;
                        mul_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (mul_valid_out) begin
                        z2       <= mul_result;
                        launched <= 1'b0;
                        state    <= ST_Z4;
                    end
                end

                ST_Z4: begin
                    if (!launched) begin
                        mul_a        <= z2;
                        mul_b        <= z2;
                        mul_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (mul_valid_out) begin
                        z4       <= mul_result;
                        launched <= 1'b0;
                        state    <= ST_Z5;
                    end
                end

                ST_Z5: begin
                    if (!launched) begin
                        mul_a        <= z4;
                        mul_b        <= z;
                        mul_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (mul_valid_out) begin
                        z5       <= mul_result;
                        launched <= 1'b0;
                        state    <= ST_XZ5;
                    end
                end

                ST_XZ5: begin
                    if (!launched) begin
                        mul_a        <= x_r;
                        mul_b        <= z5;
                        mul_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (mul_valid_out) begin
                        xz5_r    <= mul_result;
                        launched <= 1'b0;
                        state    <= ST_SIX_MINUS;
                    end
                end

                ST_SIX_MINUS: begin
                    // t = 6.0 - xz5
                    if (!launched) begin
                        as_a        <= `FP64_6P0;
                        as_b        <= xz5_r;
                        as_is_sub   <= 1'b1;
                        as_valid_in <= 1'b1;
                        launched    <= 1'b1;
                    end
                    if (as_valid_out) begin
                        t_r      <= as_result;
                        launched <= 1'b0;
                        state    <= ST_ZT;
                    end
                end

                ST_ZT: begin
                    // zt = z * t
                    if (!launched) begin
                        mul_a        <= z;
                        mul_b        <= t_r;
                        mul_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (mul_valid_out) begin
                        zt_r     <= mul_result;
                        launched <= 1'b0;
                        state    <= ST_SCALE;
                    end
                end

                ST_SCALE: begin
                    // z_new = zt * 0.2
                    if (!launched) begin
                        mul_a        <= zt_r;
                        mul_b        <= `FP64_0P2;
                        mul_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (mul_valid_out) begin
                        z        <= mul_result;
                        iter     <= iter + 4'd1;
                        launched <= 1'b0;
                        state    <= ST_CHECK;
                    end
                end

                ST_CHECK: begin
                    if (iter == NUM_ITERS[3:0])
                        state <= ST_DONE;
                    else
                        state <= ST_Z2;
                end

                // ---------------------------------------------------------
                ST_DONE: begin
                    result    <= z;
                    valid_out <= 1'b1;
                    state     <= ST_IDLE;
                end

            endcase
        end
    end

endmodule
