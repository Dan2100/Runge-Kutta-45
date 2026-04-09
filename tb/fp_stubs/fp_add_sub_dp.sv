// =============================================================================
// Behavioral stub for Xilinx Floating Point v7.1 — Add/Subtract (Double)
// =============================================================================
// Replaces the generated IP for simulation. Performs IEEE 754 FP64 add/sub
// using SystemVerilog $bitstoreal/$realtobits with the correct latency.
// =============================================================================

`include "fp_pkg.svh"

module fp_add_sub_dp (
    input  logic        aclk,
    input  logic        s_axis_a_tvalid,
    input  logic [63:0] s_axis_a_tdata,
    input  logic        s_axis_b_tvalid,
    input  logic [63:0] s_axis_b_tdata,
    input  logic        s_axis_operation_tvalid,
    input  logic [7:0]  s_axis_operation_tdata,   // [0]=0→add, [0]=1→sub
    output logic        m_axis_result_tvalid,
    output logic [63:0] m_axis_result_tdata
);

    localparam int LAT = `FP_ADDSUB_LATENCY;

    logic [63:0] pipe_data  [0:LAT-1];
    logic        pipe_valid [0:LAT-1];

    // Compute result combinationally
    real a_real, b_real, r_real;
    always_comb begin
        a_real = $bitstoreal(s_axis_a_tdata);
        b_real = $bitstoreal(s_axis_b_tdata);
        r_real = s_axis_operation_tdata[0] ? (a_real - b_real) : (a_real + b_real);
    end

    // Pipeline stage 0
    always_ff @(posedge aclk) begin
        pipe_data[0]  <= $realtobits(r_real);
        pipe_valid[0] <= s_axis_a_tvalid & s_axis_b_tvalid & s_axis_operation_tvalid;
    end

    // Pipeline stages 1..LAT-1
    genvar i;
    generate
        for (i = 1; i < LAT; i++) begin : pipe
            always_ff @(posedge aclk) begin
                pipe_data[i]  <= pipe_data[i-1];
                pipe_valid[i] <= pipe_valid[i-1];
            end
        end
    endgenerate

    assign m_axis_result_tdata  = pipe_data[LAT-1];
    assign m_axis_result_tvalid = pipe_valid[LAT-1];

endmodule
