@echo off
REM ==========================================================================
REM run_rk45_top_tb.bat — Compile & simulate full RK45 integration testbench
REM ==========================================================================
REM Usage: run_rk45_top_tb.bat
REM ==========================================================================

set VIVADO_PATH=C:\AMDDesignTools\2025.2\Vivado\bin
set PROJ_ROOT=%~dp0..
set RTL=%PROJ_ROOT%\rtl
set TB=%PROJ_ROOT%\tb
set SIM_DIR=%PROJ_ROOT%\sim_rk45_top

REM Create sim directory
if not exist "%SIM_DIR%" mkdir "%SIM_DIR%"
cd /d "%SIM_DIR%"

echo ===== Compiling RK45 Top-Level Testbench =====

REM Compile in dependency order:
REM   1. FP stubs (behavioral Xilinx IP replacements)
REM   2. FP primitives (wrappers)
REM   3. Constants package
REM   4. ODE function
REM   5. Stage engine
REM   6. Step engine
REM   7. Step controller
REM   8. Output buffer
REM   9. Top level
REM  10. Testbench

"%VIVADO_PATH%\xvlog" -sv ^
    --include "%RTL%\fp" ^
    "%TB%\fp_stubs\fp_add_sub_dp.sv" ^
    "%TB%\fp_stubs\fp_mul_dp.sv" ^
    "%TB%\fp_stubs\fp_div_dp.sv" ^
    "%TB%\fp_stubs\fp_gt_dp.sv" ^
    "%RTL%\fp\fp_abs.sv" ^
    "%RTL%\fp\fp_negate.sv" ^
    "%RTL%\fp\fp_add_sub.sv" ^
    "%RTL%\fp\fp_mul.sv" ^
    "%RTL%\fp\fp_div.sv" ^
    "%RTL%\fp\fp_compare.sv" ^
    "%RTL%\fp\fp_pow_neg0p2.sv" ^
    "%RTL%\rk45\rk45_constants_pkg.sv" ^
    "%RTL%\rk45\ode_func.sv" ^
    "%RTL%\rk45\rk45_stage.sv" ^
    "%RTL%\rk45\rk45_step.sv" ^
    "%RTL%\rk45\step_controller.sv" ^
    "%RTL%\rk45\output_buffer.sv" ^
    "%RTL%\rk45_top.sv" ^
    "%TB%\rk45_top_tb.sv"

if %ERRORLEVEL% neq 0 (
    echo COMPILATION FAILED
    exit /b 1
)

echo ===== Elaborating =====
"%VIVADO_PATH%\xelab" -debug typical rk45_top_tb -s rk45_top_sim

if %ERRORLEVEL% neq 0 (
    echo ELABORATION FAILED
    exit /b 1
)

echo ===== Running Simulation =====
"%VIVADO_PATH%\xsim" rk45_top_sim -runall -log rk45_top_sim.log

echo ===== Done =====
echo.
echo Results:
type rk45_top_sim.log | findstr /i "Step Complete Error Starting Accepted"
echo.
echo Full log: %SIM_DIR%\rk45_top_sim.log
echo Output data: %SIM_DIR%\rk45_output.txt
