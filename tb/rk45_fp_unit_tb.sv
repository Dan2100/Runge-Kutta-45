// =============================================================================
// rk45_fp_unit_tb.sv — Unit Testbench for FP Primitives
// =============================================================================
// Tests: fp_abs, fp_negate, fp_add_sub, fp_mul, fp_div, fp_compare,
//        fp_pow_neg0p2
//
// Each test applies known input(s), waits the appropriate latency, then
// compares the output against a precomputed golden value using $bitstoreal.
//
// Run:  vsim work.rk45_fp_unit_tb -do "run -all"
//       or: iverilog -g2012 -o fp_test <files> && vvp fp_test
// =============================================================================

`include "fp_pkg.svh"

`timescale 1ns / 1ps

module rk45_fp_unit_tb;

    // -------------------------------------------------------------------------
    // Clock generation — 10 ns period (100 MHz)
    // -------------------------------------------------------------------------
    logic clk = 0;
    always #5 clk = ~clk;

    logic rst_n;

    // Counters
    int tests_passed = 0;
    int tests_failed = 0;

    // Tolerance for FP comparisons (1 ULP ≈ 2.2e-16 for FP64; use 1e-12)
    real TOLERANCE = 1.0e-12;

    // -------------------------------------------------------------------------
    // Helper task: check a real result against expected
    // -------------------------------------------------------------------------
    task automatic check_real(
        input string  name,
        input real    got,
        input real    expected,
        input real    tol
    );
        real abs_err;
        abs_err = (got > expected) ? (got - expected) : (expected - got);
        if (abs_err < tol || (expected != 0.0 && abs_err / ((expected > 0 ? expected : -expected)) < tol)) begin
            $display("  PASS: %s = %.15e  (expected %.15e, err=%.3e)", name, got, expected, abs_err);
            tests_passed++;
        end else begin
            $display("  FAIL: %s = %.15e  (expected %.15e, err=%.3e)", name, got, expected, abs_err);
            tests_failed++;
        end
    endtask

    // =========================================================================
    // Test 1: fp_abs
    // =========================================================================
    logic [63:0] abs_in, abs_out;

    fp_abs uut_abs (.a(abs_in), .result(abs_out));

    task test_fp_abs();
        $display("\n--- Test: fp_abs ---");

        abs_in = `FP64_NEG50;      // -50.0
        #1;
        check_real("abs(-50)", $bitstoreal(abs_out), 50.0, TOLERANCE);

        abs_in = `FP64_ZERO;       // 0.0
        #1;
        check_real("abs(0)", $bitstoreal(abs_out), 0.0, TOLERANCE);

        abs_in = `FP64_ONE;        // 1.0
        #1;
        check_real("abs(1)", $bitstoreal(abs_out), 1.0, TOLERANCE);

        abs_in = `FP64_NEG_ONE;    // -1.0
        #1;
        check_real("abs(-1)", $bitstoreal(abs_out), 1.0, TOLERANCE);
    endtask

    // =========================================================================
    // Test 2: fp_negate
    // =========================================================================
    logic [63:0] neg_in, neg_out;

    fp_negate uut_neg (.a(neg_in), .result(neg_out));

    task test_fp_negate();
        $display("\n--- Test: fp_negate ---");

        neg_in = `FP64_ONE;
        #1;
        check_real("negate(1)", $bitstoreal(neg_out), -1.0, TOLERANCE);

        neg_in = `FP64_NEG50;
        #1;
        check_real("negate(-50)", $bitstoreal(neg_out), 50.0, TOLERANCE);

        neg_in = `FP64_ZERO;
        #1;
        // -0.0 == 0.0 in IEEE 754 comparison
        check_real("negate(0)", $bitstoreal(neg_out), 0.0, TOLERANCE);
    endtask

    // =========================================================================
    // Test 3: fp_add_sub
    // =========================================================================
    logic        as_valid_in, as_valid_out;
    logic [63:0] as_a, as_b, as_result;
    logic        as_is_sub;

    fp_add_sub uut_as (
        .clk(clk), .valid_in(as_valid_in),
        .a(as_a), .b(as_b), .is_sub(as_is_sub),
        .result(as_result), .valid_out(as_valid_out)
    );

    task automatic test_add_sub(
        input string name,
        input real a_val, input real b_val,
        input logic sub,
        input real expected
    );
        as_a        <= $realtobits(a_val);
        as_b        <= $realtobits(b_val);
        as_is_sub   <= sub;
        as_valid_in <= 1'b1;
        @(posedge clk);
        as_valid_in <= 1'b0;

        // Wait for result
        wait (as_valid_out);
        @(posedge clk);
        check_real(name, $bitstoreal(as_result), expected, TOLERANCE);
    endtask

    task test_fp_add_sub();
        $display("\n--- Test: fp_add_sub ---");
        test_add_sub("3+7",      3.0,  7.0,  1'b0, 10.0);
        test_add_sub("10-3",    10.0,  3.0,  1'b1,  7.0);
        test_add_sub("-50+1",  -50.0,  1.0,  1'b0, -49.0);
        test_add_sub("1-1",     1.0,   1.0,  1'b1,  0.0);
        test_add_sub("0+0",     0.0,   0.0,  1'b0,  0.0);
    endtask

    // =========================================================================
    // Test 4: fp_mul
    // =========================================================================
    logic        mul_valid_in, mul_valid_out;
    logic [63:0] mul_a, mul_b, mul_result;

    fp_mul uut_mul (
        .clk(clk), .valid_in(mul_valid_in),
        .a(mul_a), .b(mul_b),
        .result(mul_result), .valid_out(mul_valid_out)
    );

    task automatic test_multiply(
        input string name,
        input real a_val, input real b_val,
        input real expected
    );
        mul_a        <= $realtobits(a_val);
        mul_b        <= $realtobits(b_val);
        mul_valid_in <= 1'b1;
        @(posedge clk);
        mul_valid_in <= 1'b0;

        wait (mul_valid_out);
        @(posedge clk);
        check_real(name, $bitstoreal(mul_result), expected, TOLERANCE);
    endtask

    task test_fp_mul();
        $display("\n--- Test: fp_mul ---");
        test_multiply("3*7",     3.0,   7.0,   21.0);
        test_multiply("-50*0.5",-50.0,  0.5,  -25.0);
        test_multiply("0*100",   0.0, 100.0,    0.0);
        test_multiply("1*1",     1.0,   1.0,    1.0);
    endtask

    // =========================================================================
    // Test 5: fp_div
    // =========================================================================
    logic        div_valid_in, div_valid_out;
    logic [63:0] div_a, div_b, div_result;

    fp_div uut_div (
        .clk(clk), .valid_in(div_valid_in),
        .a(div_a), .b(div_b),
        .result(div_result), .valid_out(div_valid_out)
    );

    task automatic test_divide(
        input string name,
        input real a_val, input real b_val,
        input real expected
    );
        div_a        <= $realtobits(a_val);
        div_b        <= $realtobits(b_val);
        div_valid_in <= 1'b1;
        @(posedge clk);
        div_valid_in <= 1'b0;

        wait (div_valid_out);
        @(posedge clk);
        check_real(name, $bitstoreal(div_result), expected, TOLERANCE);
    endtask

    task test_fp_div();
        $display("\n--- Test: fp_div ---");
        test_divide("10/2",    10.0,   2.0,   5.0);
        test_divide("1/3",      1.0,   3.0,   0.333333333333333);
        test_divide("-50/10", -50.0,  10.0,  -5.0);
        test_divide("7/1",      7.0,   1.0,   7.0);
    endtask

    // =========================================================================
    // Test 6: fp_compare
    // =========================================================================
    logic        cmp_valid_in, cmp_valid_out, cmp_gt;
    logic [63:0] cmp_a, cmp_b;

    fp_compare uut_cmp (
        .clk(clk), .valid_in(cmp_valid_in),
        .a(cmp_a), .b(cmp_b),
        .a_gt_b(cmp_gt), .valid_out(cmp_valid_out)
    );

    task automatic test_compare_gt(
        input string name,
        input real a_val, input real b_val,
        input logic expected_gt
    );
        cmp_a        <= $realtobits(a_val);
        cmp_b        <= $realtobits(b_val);
        cmp_valid_in <= 1'b1;
        @(posedge clk);
        cmp_valid_in <= 1'b0;

        wait (cmp_valid_out);
        @(posedge clk);
        if (cmp_gt === expected_gt) begin
            $display("  PASS: %s  (a>b)=%0b", name, cmp_gt);
            tests_passed++;
        end else begin
            $display("  FAIL: %s  got (a>b)=%0b, expected %0b", name, cmp_gt, expected_gt);
            tests_failed++;
        end
    endtask

    task test_fp_compare();
        $display("\n--- Test: fp_compare ---");
        test_compare_gt("10 > 5",     10.0,  5.0, 1'b1);
        test_compare_gt("5 > 10",      5.0, 10.0, 1'b0);
        test_compare_gt("-1 > 1",     -1.0,  1.0, 1'b0);
        test_compare_gt("1 > 1",       1.0,  1.0, 1'b0);
        test_compare_gt("0 > -0.001",  0.0, -0.001, 1'b1);
    endtask

    // =========================================================================
    // Test 7: fp_pow_neg0p2 — x^(-0.2)
    // =========================================================================
    logic        pow_valid_in, pow_valid_out;
    logic [63:0] pow_x, pow_result;

    fp_pow_neg0p2 uut_pow (
        .clk(clk), .rst_n(rst_n),
        .valid_in(pow_valid_in), .x(pow_x),
        .result(pow_result), .valid_out(pow_valid_out)
    );

    task automatic test_pow(
        input string name,
        input real x_val,
        input real expected
    );
        pow_x        <= $realtobits(x_val);
        pow_valid_in <= 1'b1;
        @(posedge clk);
        pow_valid_in <= 1'b0;

        wait (pow_valid_out);
        @(posedge clk);
        // Use relaxed tolerance for iterative method
        check_real(name, $bitstoreal(pow_result), expected, 1.0e-10);
    endtask

    task test_fp_pow_neg0p2();
        $display("\n--- Test: fp_pow_neg0p2 (x^-0.2) ---");
        // 1.0^(-0.2) = 1.0
        test_pow("1.0^(-0.2)", 1.0, 1.0);
        // 32.0^(-0.2) = (2^5)^(-0.2) = 2^(-1) = 0.5
        test_pow("32.0^(-0.2)", 32.0, 0.5);
        // 0.03125^(-0.2) = (2^-5)^(-0.2) = 2^1 = 2.0
        test_pow("0.03125^(-0.2)", 0.03125, 2.0);
        // 100.0^(-0.2) = 10^(-0.4) ≈ 0.398107170553497
        test_pow("100.0^(-0.2)", 100.0, 0.398107170553497);
        // 0.5^(-0.2) ≈ 1.148698354997035
        test_pow("0.5^(-0.2)", 0.5, 1.148698354997035);
    endtask

    // =========================================================================
    // Main test sequence
    // =========================================================================
    initial begin
        $display("=== FP Unit Testbench Start ===");

        rst_n = 0;
        as_valid_in  = 0;
        mul_valid_in = 0;
        div_valid_in = 0;
        cmp_valid_in = 0;
        pow_valid_in = 0;

        // Reset pulse
        repeat (5) @(posedge clk);
        rst_n = 1;
        repeat (2) @(posedge clk);

        // Run all tests
        test_fp_abs();
        test_fp_negate();
        test_fp_add_sub();
        test_fp_mul();
        test_fp_div();
        test_fp_compare();
        test_fp_pow_neg0p2();

        // Summary
        $display("\n=== FP Unit Testbench Complete ===");
        $display("  Passed: %0d", tests_passed);
        $display("  Failed: %0d", tests_failed);
        if (tests_failed == 0)
            $display("  RESULT: ALL PASS");
        else
            $display("  RESULT: SOME FAILURES");

        $finish;
    end

    // Timeout watchdog
    initial begin
        #1000000;  // 1 ms = 100,000 clock cycles
        $display("ERROR: Testbench timed out!");
        $finish;
    end

endmodule
