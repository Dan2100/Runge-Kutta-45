// =============================================================================
// ode_engine.sv — Programmable Microcode ODE Function Engine
// =============================================================================
// Replaces the hard-coded ode_func module with a programmable engine that
// executes a user-loaded sequence of FP instructions to compute f(x,y).
//
// Instruction format (16 bits):
//   [15:14] op     — 00=ADD, 01=SUB, 10=MUL, 11=DIV
//   [13:11] dst    — destination register (0–7)
//   [10:8]  src_a  — source register A (0–7)
//   [7:5]   src_b  — source register B (0–7)
//   [4:0]   reserved
//
// Register file (8 × 64-bit):
//   R0 = x  (loaded automatically from input on each call)
//   R1 = y  (loaded automatically from input on each call)
//   R2–R7 = user-preloaded constants (reset to initial values each call)
//
// Program memory: up to 16 instructions.
//
// Example — f(x,y) = -50*(y-x)+1:
//   R2 = -50.0, R3 = 1.0
//   Instr 0: SUB R4, R1, R0    → R4 = y - x
//   Instr 1: MUL R4, R2, R4    → R4 = -50*(y-x)
//   Instr 2: ADD R4, R4, R3    → R4 = -50*(y-x)+1
//   prog_len = 3, result_reg = 4
//   Total latency: 11 + 6 + 11 = 28 cycles (same as original ode_func)
//
// Interface:
//   - Load program/constants via prog/const ports before integration.
//   - Assert valid_in HIGH for 1 cycle with stable x, y.
//   - valid_out pulses HIGH when f_xy is ready.
//   - Do not assert valid_in again until valid_out has been seen.
// =============================================================================

`include "fp_pkg.svh"

module ode_engine (
    input  logic        clk,
    input  logic        rst_n,

    // Program configuration (static during integration)
    input  logic [15:0] prog_mem   [0:15],  // instruction memory
    input  logic [63:0] const_regs [0:5],   // initial values for R2–R7
    input  logic [3:0]  prog_len,           // number of instructions (1–16)
    input  logic [2:0]  result_reg,         // which register holds the result

    // Datapath interface (same as ode_func)
    input  logic        valid_in,
    input  logic [63:0] x,
    input  logic [63:0] y,
    output logic [63:0] f_xy,
    output logic        valid_out
);

    // -------------------------------------------------------------------------
    // Internal FP units
    // -------------------------------------------------------------------------
    logic        as_valid_in,  as_valid_out;
    logic [63:0] as_a, as_b,   as_result;
    logic        as_is_sub;

    logic        mul_valid_in, mul_valid_out;
    logic [63:0] mul_a, mul_b, mul_result;

    logic        div_valid_in, div_valid_out;
    logic [63:0] div_a, div_b, div_result;

    fp_add_sub fp_add_sub_i (
        .clk(clk), .valid_in(as_valid_in),
        .a(as_a), .b(as_b), .is_sub(as_is_sub),
        .result(as_result), .valid_out(as_valid_out)
    );

    fp_mul fp_mul_i (
        .clk(clk), .valid_in(mul_valid_in),
        .a(mul_a), .b(mul_b),
        .result(mul_result), .valid_out(mul_valid_out)
    );

    fp_div fp_div_i (
        .clk(clk), .valid_in(div_valid_in),
        .a(div_a), .b(div_b),
        .result(div_result), .valid_out(div_valid_out)
    );

    // -------------------------------------------------------------------------
    // Register file
    // -------------------------------------------------------------------------
    logic [63:0] regfile [0:7];

    // -------------------------------------------------------------------------
    // Instruction decode helpers
    // -------------------------------------------------------------------------
    logic [15:0] cur_instr;
    logic [1:0]  cur_op;
    logic [2:0]  cur_dst, cur_src_a, cur_src_b;

    assign cur_op    = cur_instr[15:14];
    assign cur_dst   = cur_instr[13:11];
    assign cur_src_a = cur_instr[10:8];
    assign cur_src_b = cur_instr[7:5];

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_FETCH,       // Fetch instruction, read operands
        ST_EXECUTE,     // Launch FP unit, wait for result
        ST_WRITEBACK,   // Store result, advance PC
        ST_DONE
    } state_t;

    state_t     state;
    logic [3:0] pc;
    logic       launched;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= ST_IDLE;
            valid_out    <= 1'b0;
            launched     <= 1'b0;
            as_valid_in  <= 1'b0;
            mul_valid_in <= 1'b0;
            div_valid_in <= 1'b0;
        end else begin
            as_valid_in  <= 1'b0;
            mul_valid_in <= 1'b0;
            div_valid_in <= 1'b0;
            valid_out    <= 1'b0;

            case (state)

                // ---------------------------------------------------------
                ST_IDLE: begin
                    if (valid_in) begin
                        // Load R0 = x, R1 = y, R2–R7 = constants
                        regfile[0] <= x;
                        regfile[1] <= y;
                        regfile[2] <= const_regs[0];
                        regfile[3] <= const_regs[1];
                        regfile[4] <= const_regs[2];
                        regfile[5] <= const_regs[3];
                        regfile[6] <= const_regs[4];
                        regfile[7] <= const_regs[5];
                        pc         <= 4'd0;
                        launched   <= 1'b0;
                        state      <= ST_FETCH;
                    end
                end

                // ---------------------------------------------------------
                // Fetch: read instruction at PC, latch operands
                // ---------------------------------------------------------
                ST_FETCH: begin
                    cur_instr <= prog_mem[pc];
                    launched  <= 1'b0;
                    state     <= ST_EXECUTE;
                end

                // ---------------------------------------------------------
                // Execute: dispatch to the appropriate FP unit and wait
                // ---------------------------------------------------------
                ST_EXECUTE: begin
                    if (!launched) begin
                        case (cur_op)
                            2'b00: begin // ADD
                                as_a        <= regfile[cur_src_a];
                                as_b        <= regfile[cur_src_b];
                                as_is_sub   <= 1'b0;
                                as_valid_in <= 1'b1;
                            end
                            2'b01: begin // SUB
                                as_a        <= regfile[cur_src_a];
                                as_b        <= regfile[cur_src_b];
                                as_is_sub   <= 1'b1;
                                as_valid_in <= 1'b1;
                            end
                            2'b10: begin // MUL
                                mul_a        <= regfile[cur_src_a];
                                mul_b        <= regfile[cur_src_b];
                                mul_valid_in <= 1'b1;
                            end
                            2'b11: begin // DIV
                                div_a        <= regfile[cur_src_a];
                                div_b        <= regfile[cur_src_b];
                                div_valid_in <= 1'b1;
                            end
                        endcase
                        launched <= 1'b1;
                    end

                    // Wait for the appropriate FP unit to produce a result
                    case (cur_op)
                        2'b00, 2'b01: begin
                            if (as_valid_out) begin
                                // Write result to register file (skip R0/R1)
                                if (cur_dst >= 3'd2)
                                    regfile[cur_dst] <= as_result;
                                state <= ST_WRITEBACK;
                            end
                        end
                        2'b10: begin
                            if (mul_valid_out) begin
                                if (cur_dst >= 3'd2)
                                    regfile[cur_dst] <= mul_result;
                                state <= ST_WRITEBACK;
                            end
                        end
                        2'b11: begin
                            if (div_valid_out) begin
                                if (cur_dst >= 3'd2)
                                    regfile[cur_dst] <= div_result;
                                state <= ST_WRITEBACK;
                            end
                        end
                    endcase
                end

                // ---------------------------------------------------------
                // Writeback: advance PC; done if PC == prog_len
                // ---------------------------------------------------------
                ST_WRITEBACK: begin
                    if (pc + 1 >= prog_len) begin
                        state <= ST_DONE;
                    end else begin
                        pc    <= pc + 4'd1;
                        state <= ST_FETCH;
                    end
                end

                // ---------------------------------------------------------
                ST_DONE: begin
                    f_xy      <= regfile[result_reg];
                    valid_out <= 1'b1;
                    state     <= ST_IDLE;
                end

            endcase
        end
    end

endmodule
