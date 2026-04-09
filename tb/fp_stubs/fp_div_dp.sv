// =============================================================================
// Behavioral stub for Xilinx Floating Point v7.1 — Divide (Double)
// =============================================================================

`include "fp_pkg.svh"

module fp_div_dp (
    input  logic        aclk,
    input  logic        s_axis_a_tvalid,
    input  logic [63:0] s_axis_a_tdata,
    input  logic        s_axis_b_tvalid,
    input  logic [63:0] s_axis_b_tdata,
    output logic        m_axis_result_tvalid,
    output logic [63:0] m_axis_result_tdata
);

    localparam int LAT = `FP_DIV_LATENCY;

    logic [63:0] pipe_data  [0:LAT-1];
    logic        pipe_valid [0:LAT-1];

    real a_real, b_real, r_real;
    always_comb begin
        a_real = $bitstoreal(s_axis_a_tdata);
        b_real = $bitstoreal(s_axis_b_tdata);
        r_real = a_real / b_real;
    end

    always_ff @(posedge aclk) begin
        pipe_data[0]  <= $realtobits(r_real);
        pipe_valid[0] <= s_axis_a_tvalid & s_axis_b_tvalid;
    end

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
