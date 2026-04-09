// =============================================================================
// rk45_constants_pkg.sv — Dormand-Prince RK45 Butcher Tableau Constants
// =============================================================================
// All constants are declared as `real` parameters.
// Bit-pattern equivalents (FP64) use $realtobits(), which Vivado evaluates
// at elaboration time — safe for synthesis.
//
// Reference: Dormand & Prince (1980), "A family of embedded Runge-Kutta
//            formulae", J. Comput. Appl. Math., 6(1):19–26.
//
// Verify with: python scripts/python/gen_constants.py
// =============================================================================

package rk45_constants_pkg;

    // =========================================================================
    // c nodes — x-offsets for each stage: x_i = x_n + c_i * h
    // =========================================================================
    localparam real C2 = 1.0/5.0;          // 0.2
    localparam real C3 = 3.0/10.0;         // 0.3
    localparam real C4 = 4.0/5.0;          // 0.8
    localparam real C5 = 8.0/9.0;          // 0.8888...
    // C6 = 1.0 and C7 = 1.0 (not needed as parameters)

    // =========================================================================
    // a coefficients — Butcher tableau lower-triangular entries
    // =========================================================================

    // --- Stage 2 ---
    localparam real A21 = 1.0/5.0;         //  0.2

    // --- Stage 3 ---
    localparam real A31 = 3.0/40.0;        //  0.075
    localparam real A32 = 9.0/40.0;        //  0.225

    // --- Stage 4 ---
    localparam real A41 =  44.0/45.0;      //  0.97778...
    localparam real A42 = -56.0/15.0;      // -3.73333...
    localparam real A43 =  32.0/9.0;       //  3.55556...

    // --- Stage 5 ---
    localparam real A51 =  19372.0/6561.0;  //  2.95257...
    localparam real A52 = -25360.0/2187.0;  // -11.5954...
    localparam real A53 =  64448.0/6561.0;  //  9.8228...
    localparam real A54 =   -212.0/729.0;   // -0.29080...

    // --- Stage 6 ---
    localparam real A61 =   9017.0/3168.0;  //  2.84637...
    localparam real A62 =   -355.0/33.0;    // -10.7576...
    localparam real A63 =  46732.0/5247.0;  //  8.90642...
    localparam real A64 =     49.0/176.0;   //  0.27841...
    localparam real A65 =  -5103.0/18656.0; // -0.27355...

    // =========================================================================
    // b — 5th-order solution weights (used for y_{n+1})
    // =========================================================================
    localparam real B1 =    35.0/384.0;     //  0.09114...
    // B2 = 0
    localparam real B3 =   500.0/1113.0;    //  0.44942...
    localparam real B4 =   125.0/192.0;     //  0.65104...
    localparam real B5 = -2187.0/6784.0;    // -0.32237...
    localparam real B6 =    11.0/84.0;      //  0.13095...
    // B7 = 0

    // =========================================================================
    // e — Error estimate coefficients  (e_i = b_i − b*_i)
    // where b* is the 4th-order weights used only for error estimation
    //
    //   b*1 = 5179/57600,  b*3 = 7571/16695,  b*4 = 393/640,
    //   b*5 = -92097/339200,  b*6 = 187/2100,  b*7 = 1/40
    // =========================================================================
    localparam real E1 =     71.0/57600.0;   //  0.00123...
    // E2 = 0
    localparam real E3 =    -71.0/16695.0;   // -0.00425...
    localparam real E4 =     71.0/1920.0;    //  0.03698...
    localparam real E5 =  -17253.0/339200.0; // -0.05088...
    localparam real E6 =     22.0/525.0;     //  0.04190...
    localparam real E7 =     -1.0/40.0;      // -0.025

    // =========================================================================
    // Step-size controller constants
    // =========================================================================
    localparam real SAFETY      = 0.9;       // safety factor
    localparam real EXP_SHRINK  = -0.2;      // exponent for err_norm^(-1/5)
    localparam real MIN_SCALE   = 0.2;       // minimum h scale factor per step
    localparam real MAX_SCALE   = 10.0;      // maximum h scale factor per step

    // =========================================================================
    // FP64 bit-pattern equivalents — use these for hardware datapath
    // $realtobits() is evaluated at elaboration time by Vivado
    // =========================================================================
    localparam logic [63:0] C2_B   = $realtobits(C2);
    localparam logic [63:0] C3_B   = $realtobits(C3);
    localparam logic [63:0] C4_B   = $realtobits(C4);
    localparam logic [63:0] C5_B   = $realtobits(C5);

    localparam logic [63:0] A21_B  = $realtobits(A21);
    localparam logic [63:0] A31_B  = $realtobits(A31);
    localparam logic [63:0] A32_B  = $realtobits(A32);
    localparam logic [63:0] A41_B  = $realtobits(A41);
    localparam logic [63:0] A42_B  = $realtobits(A42);
    localparam logic [63:0] A43_B  = $realtobits(A43);
    localparam logic [63:0] A51_B  = $realtobits(A51);
    localparam logic [63:0] A52_B  = $realtobits(A52);
    localparam logic [63:0] A53_B  = $realtobits(A53);
    localparam logic [63:0] A54_B  = $realtobits(A54);
    localparam logic [63:0] A61_B  = $realtobits(A61);
    localparam logic [63:0] A62_B  = $realtobits(A62);
    localparam logic [63:0] A63_B  = $realtobits(A63);
    localparam logic [63:0] A64_B  = $realtobits(A64);
    localparam logic [63:0] A65_B  = $realtobits(A65);

    localparam logic [63:0] B1_B   = $realtobits(B1);
    localparam logic [63:0] B3_B   = $realtobits(B3);
    localparam logic [63:0] B4_B   = $realtobits(B4);
    localparam logic [63:0] B5_B   = $realtobits(B5);
    localparam logic [63:0] B6_B   = $realtobits(B6);

    localparam logic [63:0] E1_B   = $realtobits(E1);
    localparam logic [63:0] E3_B   = $realtobits(E3);
    localparam logic [63:0] E4_B   = $realtobits(E4);
    localparam logic [63:0] E5_B   = $realtobits(E5);
    localparam logic [63:0] E6_B   = $realtobits(E6);
    localparam logic [63:0] E7_B   = $realtobits(E7);

    localparam logic [63:0] SAFETY_B     = $realtobits(SAFETY);
    localparam logic [63:0] MIN_SCALE_B  = $realtobits(MIN_SCALE);
    localparam logic [63:0] MAX_SCALE_B  = $realtobits(MAX_SCALE);

endpackage
