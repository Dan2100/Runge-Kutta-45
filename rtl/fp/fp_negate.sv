// =============================================================================
// fp_negate.sv — IEEE 754 Double-Precision Negation
// =============================================================================
// Combinational: flips the sign bit (bit 63).
// Zero latency — no clock required.
// =============================================================================

`include "fp_pkg.svh"

module fp_negate (
    input  logic [63:0] a,
    output logic [63:0] result
);
    assign result = a ^ `FP64_SIGN_MASK;

endmodule
