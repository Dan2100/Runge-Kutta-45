// =============================================================================
// fp_pkg.svh — IEEE 754 Double-Precision FP Constants & Latency Parameters
// =============================================================================
// All latencies must match the Xilinx IP configurations in:
//   scripts/vivado/create_fp_ips.tcl
//
// FP64 hex literals verified with: struct.pack('>d', value).hex()
// =============================================================================

`ifndef FP_PKG_SVH
`define FP_PKG_SVH

`timescale 1ns / 1ps

// ----------------------------------------------------------------------------
// Xilinx IP pipeline latencies (clock cycles)
// ----------------------------------------------------------------------------
`define FP_ADDSUB_LATENCY   11
`define FP_MUL_LATENCY       6
`define FP_DIV_LATENCY      28
`define FP_CMP_LATENCY       2

// ----------------------------------------------------------------------------
// IEEE 754 double-precision constants
// ----------------------------------------------------------------------------
`define FP64_ZERO        64'h0000000000000000  //  0.0
`define FP64_ONE         64'h3FF0000000000000  //  1.0
`define FP64_NEG_ONE     64'hBFF0000000000000  // -1.0
`define FP64_TWO         64'h4000000000000000  //  2.0
`define FP64_HALF        64'h3FE0000000000000  //  0.5
`define FP64_0P2         64'h3FC999999999999A  //  0.2  (1/5)
`define FP64_0P9         64'h3FECCCCCCCCCCCCD  //  0.9  (safety factor)
`define FP64_6P0         64'h4018000000000000  //  6.0
`define FP64_NEG50       64'hC049000000000000  // -50.0
`define FP64_50          64'h4049000000000000  //  50.0

// Sign-bit mask (bit 63)
`define FP64_SIGN_MASK   64'h8000000000000000

`endif // FP_PKG_SVH
