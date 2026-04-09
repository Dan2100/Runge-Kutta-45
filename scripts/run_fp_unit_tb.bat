@echo off
REM ==========================================================================
REM run_fp_unit_tb.bat — Compile & simulate FP unit testbench with Vivado xsim
REM ==========================================================================
REM Usage: run_fp_unit_tb.bat
REM Requires: Vivado on PATH or set VIVADO_PATH below
REM ==========================================================================

set VIVADO_PATH=C:\AMDDesignTools\2025.2\Vivado\bin
set PROJ_ROOT=%~dp0..
set RTL=%PROJ_ROOT%\rtl
set TB=%PROJ_ROOT%\tb
set SIM_DIR=%PROJ_ROOT%\sim_fp_unit

REM Create sim directory
if not exist "%SIM_DIR%" mkdir "%SIM_DIR%"
cd /d "%SIM_DIR%"

echo ===== Compiling FP Unit Testbench =====

REM Compile all sources (stubs first, then RTL, then TB)
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
    "%TB%\rk45_fp_unit_tb.sv"

if %ERRORLEVEL% neq 0 (
    echo COMPILATION FAILED
    exit /b 1
)

echo ===== Elaborating =====
"%VIVADO_PATH%\xelab" -debug typical rk45_fp_unit_tb -s fp_unit_sim

if %ERRORLEVEL% neq 0 (
    echo ELABORATION FAILED
    exit /b 1
)

echo ===== Running Simulation =====
"%VIVADO_PATH%\xsim" fp_unit_sim -runall -log fp_unit_sim.log

echo ===== Done =====
type fp_unit_sim.log | findstr /i "PASS FAIL ERROR"
