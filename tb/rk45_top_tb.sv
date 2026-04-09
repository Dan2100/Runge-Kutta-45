// =============================================================================
// rk45_top_tb.sv — Integration Testbench for RK45 ODE Solver
// =============================================================================
// Drives the rk45_top module with test parameters:
//   ODE:    dy/dx = -50*(y-x) + 1
//   IC:     y(0) = 1.0
//   Range:  x ∈ [0.0, 1.0]
//   h0:     0.1
//   rtol:   1e-6
//   atol:   1e-9
//
// After integration completes, reads all accepted (x, y, err) triples from
// the output FIFO and writes them to "rk45_output.txt" in both hex and
// decimal formats for comparison with Python reference.
// =============================================================================

`timescale 1ns / 1ps

`include "fp_pkg.svh"

module rk45_top_tb;

    // -------------------------------------------------------------------------
    // Parameters (FP64 bit patterns via $realtobits)
    // -------------------------------------------------------------------------
    localparam logic [63:0] X_START = $realtobits(0.0);
    localparam logic [63:0] X_END   = $realtobits(1.0);
    localparam logic [63:0] Y0      = $realtobits(1.0);
    localparam logic [63:0] H0      = $realtobits(0.1);
    localparam logic [63:0] RTOL    = $realtobits(1.0e-6);
    localparam logic [63:0] ATOL    = $realtobits(1.0e-9);

    // -------------------------------------------------------------------------
    // Clock and reset
    // -------------------------------------------------------------------------
    logic clk, rst_n;

    localparam real CLK_PERIOD = 10.0;  // 100 MHz

    initial clk = 1'b0;
    always #(CLK_PERIOD / 2.0) clk = ~clk;

    // -------------------------------------------------------------------------
    // DUT connections
    // -------------------------------------------------------------------------
    logic        start;
    logic        busy, dut_done;
    logic        result_read, result_valid;
    logic [63:0] result_x, result_y, result_err;
    logic        fifo_empty;
    logic [10:0] result_count;

    rk45_top dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (start),
        .x_start      (X_START),
        .x_end        (X_END),
        .y0           (Y0),
        .h0           (H0),
        .rtol         (RTOL),
        .atol         (ATOL),
        .busy         (busy),
        .done         (dut_done),
        .result_read  (result_read),
        .result_valid (result_valid),
        .result_x     (result_x),
        .result_y     (result_y),
        .result_err   (result_err),
        .fifo_empty   (fifo_empty),
        .result_count (result_count)
    );

    // -------------------------------------------------------------------------
    // Exact analytical solution for verification
    // -------------------------------------------------------------------------
    function automatic real exact_y(input real x);
        // y(x) = x + (y0 - x0) * exp(-50*(x - x0))
        // With x0=0, y0=1:
        //   y(x) = x + exp(-50*x)
        real x0, y0_val;
        x0     = 0.0;
        y0_val = 1.0;
        exact_y = x + (y0_val - x0) * $exp(-50.0 * (x - x0));
    endfunction

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    integer fd;
    integer step_num;
    real    x_val, y_val, err_val, y_exact, y_relerr;

    initial begin
        // Initialise
        rst_n       = 1'b0;
        start       = 1'b0;
        result_read = 1'b0;

        // Reset for 20 cycles
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
        repeat (5) @(posedge clk);

        // Start integration
        $display("=== RK45 Integration Starting ===");
        $display("  x_start = %f", $bitstoreal(X_START));
        $display("  x_end   = %f", $bitstoreal(X_END));
        $display("  y0      = %f", $bitstoreal(Y0));
        $display("  h0      = %f", $bitstoreal(H0));
        $display("  rtol    = %e", $bitstoreal(RTOL));
        $display("  atol    = %e", $bitstoreal(ATOL));

        @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        // Wait for completion (with timeout)
        fork
            begin
                wait (dut_done === 1'b1);
            end
            begin
                #100_000_000;  // 100 ms timeout
                $display("ERROR: Integration timed out after 100ms!");
                $finish;
            end
        join_any
        disable fork;

        $display("=== Integration Complete ===");
        $display("  Accepted steps: %0d", result_count);
        $display("");

        // Wait a few cycles after done
        repeat (5) @(posedge clk);

        // Open output file
        fd = $fopen("rk45_output.txt", "w");
        if (fd == 0) begin
            $display("ERROR: Could not open rk45_output.txt for writing!");
            $finish;
        end

        // Header
        $fwrite(fd, "# step  x_hex               y_hex               err_hex             x_dec            y_dec            err_dec          y_exact          rel_err\n");

        // Read all results from FIFO
        step_num = 0;

        while (!fifo_empty) begin
            // Pulse read_en for one cycle
            @(posedge clk);
            result_read = 1'b1;
            @(posedge clk);
            result_read = 1'b0;

            // Wait for valid_out with timeout
            begin : wait_for_valid
                int wait_cnt;
                wait_cnt = 0;
                while (!result_valid && wait_cnt < 5) begin
                    @(posedge clk);
                    wait_cnt = wait_cnt + 1;
                end
            end

            if (result_valid) begin
                x_val   = $bitstoreal(result_x);
                y_val   = $bitstoreal(result_y);
                err_val = $bitstoreal(result_err);
                y_exact = exact_y(x_val);

                if (y_exact != 0.0)
                    y_relerr = (y_val - y_exact) / y_exact;
                else
                    y_relerr = y_val - y_exact;

                $fwrite(fd, "%4d    %016h  %016h  %016h  %16.12f %16.12f %16.6e %16.12f %16.6e\n",
                        step_num,
                        result_x, result_y, result_err,
                        x_val, y_val, err_val,
                        y_exact, y_relerr);

                $display("Step %3d: x=%12.8f  y=%16.12f  y_exact=%16.12f  rel_err=%10.3e",
                         step_num, x_val, y_val, y_exact, y_relerr);

                step_num = step_num + 1;
            end else begin
                $display("WARNING: FIFO read timeout at step %0d", step_num);
            end
        end

        $fclose(fd);

        $display("");
        $display("=== %0d steps written to rk45_output.txt ===", step_num);
        $display("=== Simulation Complete ===");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Watchdog timer
    // -------------------------------------------------------------------------
    initial begin
        #500_000_000;  // 500 ms absolute timeout
        $display("WATCHDOG: Simulation exceeded 500ms. Aborting.");
        $finish;
    end

endmodule
