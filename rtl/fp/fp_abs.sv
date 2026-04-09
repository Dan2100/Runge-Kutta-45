// =============================================================================
// fp_abs.sv — IEEE 754 Double-Precision Absolute Value
// =============================================================================
// Combinational: clears the sign bit (bit 63).
// Zero latency — no clock required.
// =============================================================================

`include "fp_pkg.svh"

module fp_abs (
    input  logic [63:0] a,
    output logic [63:0] result
);
    assign result = a & ~`FP64_SIGN_MASK;

endmodule
