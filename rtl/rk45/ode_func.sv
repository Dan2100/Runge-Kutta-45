// =============================================================================
// ode_func.sv — Hardcoded ODE Right-Hand Side: f(x,y) = -50*(y-x) + 1
// =============================================================================
// Computes the derivative for the test ODE:
//   dy/dx = -50*(y - x) + 1
//
// Operation sequence (sequential, shared add/sub and mul):
//   Step 1:  diff   = y - x          (fp_add_sub, is_sub=1)
//   Step 2:  scaled = -50.0 * diff   (fp_mul)
//   Step 3:  result = scaled + 1.0   (fp_add_sub, is_sub=0)
//
// Total latency: FP_ADDSUB_LATENCY + FP_MUL_LATENCY + FP_ADDSUB_LATENCY
//              = 11 + 6 + 11 = 28 clock cycles
//
// Interface:
//   - Assert valid_in HIGH for 1 cycle with stable x, y.
//   - valid_out pulses HIGH when result (f_xy) is ready.
//   - Do not assert valid_in again until valid_out has been seen.
// =============================================================================

`include "fp_pkg.svh"

module ode_func (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        valid_in,
    input  logic [63:0] x,
    input  logic [63:0] y,
    output logic [63:0] f_xy,       // f(x,y) = -50*(y-x)+1
    output logic        valid_out
);

    // -------------------------------------------------------------------------
    // Internal FP unit ports
    // -------------------------------------------------------------------------
    logic        as_valid_in,  as_valid_out;
    logic [63:0] as_a, as_b,   as_result;
    logic        as_is_sub;

    logic        mul_valid_in, mul_valid_out;
    logic [63:0] mul_a, mul_b, mul_result;

    fp_add_sub fp_add_sub_i (
        .clk       (clk),
        .valid_in  (as_valid_in),
        .a         (as_a),
        .b         (as_b),
        .is_sub    (as_is_sub),
        .result    (as_result),
        .valid_out (as_valid_out)
    );

    fp_mul fp_mul_i (
        .clk       (clk),
        .valid_in  (mul_valid_in),
        .a         (mul_a),
        .b         (mul_b),
        .result    (mul_result),
        .valid_out (mul_valid_out)
    );

    // -------------------------------------------------------------------------
    // State machine
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_SUB_YX,      // diff   = y - x
        ST_MUL_NEG50,   // scaled = -50.0 * diff
        ST_ADD_ONE,     // result = scaled + 1.0
        ST_DONE
    } state_t;

    state_t      state;
    logic        launched;
    logic [63:0] diff_r;        // y - x
    logic [63:0] scaled_r;      // -50 * (y - x)
    logic [63:0] x_r, y_r;     // latched inputs

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            valid_out    <= 1'b0;
            launched     <= 1'b0;
            as_valid_in  <= 1'b0;
            mul_valid_in <= 1'b0;
        end else begin
            as_valid_in  <= 1'b0;
            mul_valid_in <= 1'b0;
            valid_out    <= 1'b0;

            case (state)

                ST_IDLE: begin
                    if (valid_in) begin
                        x_r      <= x;
                        y_r      <= y;
                        launched <= 1'b0;
                        state    <= ST_SUB_YX;
                    end
                end

                // Step 1: diff = y - x
                ST_SUB_YX: begin
                    if (!launched) begin
                        as_a        <= y_r;
                        as_b        <= x_r;
                        as_is_sub   <= 1'b1;
                        as_valid_in <= 1'b1;
                        launched    <= 1'b1;
                    end
                    if (as_valid_out) begin
                        diff_r   <= as_result;
                        launched <= 1'b0;
                        state    <= ST_MUL_NEG50;
                    end
                end

                // Step 2: scaled = -50.0 * diff
                ST_MUL_NEG50: begin
                    if (!launched) begin
                        mul_a        <= `FP64_NEG50;
                        mul_b        <= diff_r;
                        mul_valid_in <= 1'b1;
                        launched     <= 1'b1;
                    end
                    if (mul_valid_out) begin
                        scaled_r <= mul_result;
                        launched <= 1'b0;
                        state    <= ST_ADD_ONE;
                    end
                end

                // Step 3: result = scaled + 1.0
                ST_ADD_ONE: begin
                    if (!launched) begin
                        as_a        <= scaled_r;
                        as_b        <= `FP64_ONE;
                        as_is_sub   <= 1'b0;
                        as_valid_in <= 1'b1;
                        launched    <= 1'b1;
                    end
                    if (as_valid_out) begin
                        f_xy     <= as_result;
                        launched <= 1'b0;
                        state    <= ST_DONE;
                    end
                end

                ST_DONE: begin
                    valid_out <= 1'b1;
                    state     <= ST_IDLE;
                end

            endcase
        end
    end

endmodule
