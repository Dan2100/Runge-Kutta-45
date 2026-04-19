// =============================================================================
// rk45_stage.sv — Compute One Dormand-Prince RK45 Stage (ki)
// =============================================================================
// For a given stage index s ∈ {1..7}, computes:
//
//   y_stage = y_n + h * Σ(a[s][j] * k[j],  j = 1..s-1)
//   x_stage = x_n + c[s] * h
//   k[s]    = f(x_stage, y_stage)
//
// Phase A optimization: The pipelined fp_mul accepts a new input every cycle.
// We feed c*h first, then all a[j]*k[j] products back-to-back (1/cycle) and
// collect results into a buffer as they emerge 6 cycles later. Sequential
// accumulation then reduces the buffer. After accumulation, h*accum (mul) and
// x+c*h (add) run in parallel since they use different FP units.
//
// Interface:
//   - Assert start HIGH for 1 cycle with stable inputs.
//   - k_out becomes valid when done pulses HIGH.
//   - Do not assert start again until done has been seen.
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

    // ODE engine program (static during integration)
    input  logic [15:0] ode_prog_mem   [0:15],
    input  logic [63:0] ode_const_regs [0:5],
    input  logic [3:0]  ode_prog_len,
    input  logic [2:0]  ode_result_reg,

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
    // ODE engine instance (programmable microcode)
    // -------------------------------------------------------------------------
    logic        ode_valid_in, ode_valid_out;
    logic [63:0] ode_x, ode_y, ode_result;

    ode_engine ode_engine_i (
        .clk(clk), .rst_n(rst_n),
        .prog_mem(ode_prog_mem), .const_regs(ode_const_regs),
        .prog_len(ode_prog_len), .result_reg(ode_result_reg),
        .valid_in(ode_valid_in), .x(ode_x), .y(ode_y),
        .f_xy(ode_result), .valid_out(ode_valid_out)
    );

    // -------------------------------------------------------------------------
    // Butcher tableau coefficient lookup
    // -------------------------------------------------------------------------

    function automatic int n_terms(input logic [2:0] s);
        case (s)
            3'd0: return 0;
            3'd1: return 1;
            3'd2: return 2;
            3'd3: return 3;
            3'd4: return 4;
            3'd5: return 5;
            3'd6: return 6;
            default: return 0;
        endcase
    endfunction

    function automatic logic [63:0] get_a_coeff(input logic [2:0] s, input int j);
        case (s)
            3'd1: return A21_B;
            3'd2: case (j) 0: return A31_B; 1: return A32_B;
                   default: return `FP64_ZERO; endcase
            3'd3: case (j) 0: return A41_B; 1: return A42_B;
                           2: return A43_B;
                   default: return `FP64_ZERO; endcase
            3'd4: case (j) 0: return A51_B; 1: return A52_B;
                           2: return A53_B; 3: return A54_B;
                   default: return `FP64_ZERO; endcase
            3'd5: case (j) 0: return A61_B; 1: return A62_B;
                           2: return A63_B; 3: return A64_B;
                           4: return A65_B;
                   default: return `FP64_ZERO; endcase
            3'd6: case (j) 0: return B1_B;  1: return `FP64_ZERO;
                           2: return B3_B;  3: return B4_B;
                           4: return B5_B;  5: return B6_B;
                   default: return `FP64_ZERO; endcase
            default: return `FP64_ZERO;
        endcase
    endfunction

    function automatic logic [63:0] get_c(input logic [2:0] s);
        case (s)
            3'd0: return `FP64_ZERO;
            3'd1: return C2_B;
            3'd2: return C3_B;
            3'd3: return C4_B;
            3'd4: return C5_B;
            3'd5: return `FP64_ONE;
            3'd6: return `FP64_ONE;
            default: return `FP64_ZERO;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_DIRECT_ODE,      // Stage 0: skip accumulation, call f(x_n, y_n)
        ST_MAC_FEED,        // Feed c*h then a[j]*k[j] into mul pipeline
        ST_MAC_ACCUM,       // Sequential accumulation of buffered products
        ST_POST_PARALLEL,   // Launch h*accum (mul) + x+c_h (add) simultaneously
        ST_POST_WAIT,       // Wait for both parallel operations
        ST_ADD_Y,           // y_stage = y_n + h_accum
        ST_CALL_ODE,        // Call f(x_stage, y_stage)
        ST_DONE
    } state_t;

    state_t      state;
    int          n;                     // number of a-coefficient terms
    logic [2:0]  stage_r;
    logic [63:0] x_r, y_r, h_r;
    logic [63:0] k_r [0:6];
    logic        launched;

    // MAC pipeline state
    int          feed_idx;              // next term to feed (0 = c*h, 1..n = a[j]*k[j])
    int          collect_count;         // number of results collected
    logic [63:0] c_h_result;            // precomputed c*h
    logic [63:0] products [0:5];        // buffered a[j]*k[j] results (max 6)
    int          prod_count;            // number of a*k products collected

    // Accumulation state
    int          acc_idx;
    logic [63:0] accum;

    // Post-MAC parallel state
    logic [63:0] h_accum;               // h * Σ(a*k)
    logic [63:0] x_stage;
    logic [63:0] y_stage;
    logic        h_mul_done;
    logic        x_add_done;

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
                        launched <= 1'b0;

                        if (stage == 3'd0)
                            state <= ST_DIRECT_ODE;
                        else begin
                            // Initialize MAC feed: first feed is c*h
                            feed_idx      <= 0;
                            collect_count <= 0;
                            prod_count    <= 0;
                            state         <= ST_MAC_FEED;
                        end
                    end
                end

                // ---------------------------------------------------------
                // Stage 0 (k1): no accumulation, just f(x_n, y_n)
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
                // MAC_FEED: Feed c*h (idx 0) then a[j]*k[j] (idx 1..n)
                // into the pipelined multiplier, 1 per cycle.
                // Simultaneously collect results as they emerge.
                // ---------------------------------------------------------
                ST_MAC_FEED: begin
                    // --- Feed side: one new mul input per cycle ---
                    if (feed_idx <= n) begin
                        if (feed_idx == 0) begin
                            // First feed: c * h
                            mul_a        <= get_c(stage_r);
                            mul_b        <= h_r;
                        end else begin
                            // Subsequent feeds: a[j] * k[j]  (j = feed_idx-1)
                            mul_a        <= get_a_coeff(stage_r, feed_idx - 1);
                            mul_b        <= k_r[feed_idx - 1];
                        end
                        mul_valid_in <= 1'b1;
                        feed_idx     <= feed_idx + 1;
                    end

                    // --- Collect side: results arrive 6 cycles after feed ---
                    if (mul_valid_out) begin
                        if (collect_count == 0) begin
                            // First result is c*h
                            c_h_result <= mul_result;
                        end else begin
                            // Subsequent results are a[j]*k[j]
                            products[collect_count - 1] <= mul_result;
                            prod_count <= collect_count; // = collect_count (1-based → 0-based+1)
                        end
                        collect_count <= collect_count + 1;
                    end

                    // --- Done when all n+1 results collected ---
                    // (n a*k products + 1 c*h)
                    if (collect_count == n + 1) begin
                        // Set up accumulation
                        accum   <= products[0];
                        acc_idx <= 1;
                        launched <= 1'b0;
                        if (n <= 1)
                            state <= ST_POST_PARALLEL;  // Only 1 product, no reduction needed
                        else
                            state <= ST_MAC_ACCUM;
                    end
                end

                // ---------------------------------------------------------
                // MAC_ACCUM: Sequential accumulation of products[1..n-1]
                // accum starts as products[0], then accum += products[i]
                // ---------------------------------------------------------
                ST_MAC_ACCUM: begin
                    if (!launched) begin
                        as_a        <= accum;
                        as_b        <= products[acc_idx];
                        as_is_sub   <= 1'b0;
                        as_valid_in <= 1'b1;
                        launched    <= 1'b1;
                    end
                    if (as_valid_out) begin
                        accum    <= as_result;
                        launched <= 1'b0;
                        if (acc_idx + 1 >= n) begin
                            state <= ST_POST_PARALLEL;
                        end else begin
                            acc_idx <= acc_idx + 1;
                        end
                    end
                end

                // ---------------------------------------------------------
                // POST_PARALLEL: Launch two operations simultaneously:
                //   mul: h * accum  (uses fp_mul)
                //   add: x_n + c_h  (uses fp_add_sub)
                // These use different FP units so no conflict.
                // ---------------------------------------------------------
                ST_POST_PARALLEL: begin
                    // Launch h * accum on multiplier
                    mul_a        <= h_r;
                    mul_b        <= accum;
                    mul_valid_in <= 1'b1;

                    // Launch x_n + c*h on adder
                    as_a        <= x_r;
                    as_b        <= c_h_result;
                    as_is_sub   <= 1'b0;
                    as_valid_in <= 1'b1;

                    h_mul_done  <= 1'b0;
                    x_add_done  <= 1'b0;
                    state       <= ST_POST_WAIT;
                end

                // ---------------------------------------------------------
                // POST_WAIT: Wait for both h*accum and x+c*h to complete
                // ---------------------------------------------------------
                ST_POST_WAIT: begin
                    if (mul_valid_out) begin
                        h_accum    <= mul_result;
                        h_mul_done <= 1'b1;
                    end
                    if (as_valid_out) begin
                        x_stage    <= as_result;
                        x_add_done <= 1'b1;
                    end

                    // Both done?
                    if ((h_mul_done || mul_valid_out) &&
                        (x_add_done || as_valid_out)) begin
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
                        as_b        <= h_accum;
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
