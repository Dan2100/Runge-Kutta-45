"""
rk45_reference.py
-----------------
Software reference for the pipelined FPGA RK45 solver (Top_pipe.vhd).

ODE:   dy/dx = f(x, y) = 50*(x - y) + 1
IC:    y(2.0) = 1.0
Range: x = 2.0 → 2.5

Analytical solution:
    y(x) = x + C * exp(-50*x),   C = -exp(100)
    y(2.5) = 2.5 - exp(-25) ≈ 2.4999999999861

This script implements the SAME step-acceptance logic as the hardware so that
its per-step (x, y, err) output can be diff-ed against the VHDL simulation
transcript line-by-line.

Hardware tolerance:
    eff_tol = max(atol, rtol_approx * |y|)
    where rtol_approx * |y| is approximated by IEEE 754 exponent addition
    (mantissa treated as 1.0, within a factor of 2 of the true product).

Hardware step-size rule (step_ctrl.vhd):
    |err| > eff_tol         → reject,  h /= 2
    |err| < eff_tol / 32    → accept,  h *= 2
    otherwise               → accept,  h unchanged

Dormand-Prince RK45 (Butcher tableau — same coefficients as k_block_pipe.vhd):
    c2=1/5, c3=3/10, c4=4/5, c5=8/9
    b-weights: b1=35/384, b3=500/1113, b4=125/192, b5=-2187/6784, b6=11/84
    error:     e1=71/57600, e3=-71/16695, e4=71/1920, e5=-17253/339200,
               e6=22/525,   e7=-1/40  (FSAL: e7 uses k7=f(x+h, y_new))

Usage:
    python rk45_reference.py

Output format (one line per accepted step):
    [STEP N]  x=0xHHHHHHHH(real)  y=0xHHHHHHHH(real)  err=0xHHHHHHHH(real)

Compare against VHDL transcript [STEP N] lines.  The x and y hex values should
match to within 1 ULP (last bit rounding is acceptable).
"""

import struct
import math
import sys


# ---------------------------------------------------------------------------
# Hardware register file values (from reg.vhd) – used for exact bit matching
# ---------------------------------------------------------------------------
REG = {
    1: 0x40000000,   # 2.0    x0
    2: 0x3F800000,   # 1.0    y0
    3: 0x3DCCCCCD,   # 0.1    h
    4: 0x3C23D70A,   # 0.01   atol
    5: 0x41200000,   # 10.0   x_end
    6: 0x3A83126F,   # 0.001  rtol
}

def bits_to_f32(bits: int) -> float:
    """Unpack a 32-bit integer as an IEEE 754 single-precision float."""
    return struct.unpack('>f', struct.pack('>I', bits & 0xFFFFFFFF))[0]

def f32_to_bits(val: float) -> int:
    """Pack a Python float as an IEEE 754 single-precision 32-bit integer."""
    return struct.unpack('>I', struct.pack('>f', val))[0]

def f32_hex(val: float) -> str:
    """Return '0xHHHHHHHH' hex string for the single-precision encoding."""
    return f"0x{f32_to_bits(val):08X}"


# ---------------------------------------------------------------------------
# ODE function
# ---------------------------------------------------------------------------
def f_ode(x: float, y: float) -> float:
    """f(x, y) = 50*(x - y) + 1  (matches func.vhd)"""
    return 50.0 * (x - y) + 1.0


# ---------------------------------------------------------------------------
# Hardware-equivalent effective tolerance
# ---------------------------------------------------------------------------
def hw_eff_tol(y_val: float, atol: float, rtol: float) -> float:
    """
    Hardware approximation: rtol * |y| via IEEE 754 exponent addition only.
    The mantissa of both operands is treated as 1.0 (i.e. 2^0 = 1), so the
    result is 2^(exp_rtol + exp_y - 127).  This is within 2× of the true
    product and is the same approximation used in step_ctrl.vhd.
    """
    y_abs  = abs(y_val)
    r_bits = f32_to_bits(abs(rtol))
    y_bits = f32_to_bits(y_abs)

    exp_rtol = (r_bits >> 23) & 0xFF
    exp_y    = (y_bits >> 23) & 0xFF

    # Exponent addition with bias removal; guard underflow
    exp_prod = exp_rtol + exp_y
    if exp_prod > 127:
        exp_prod -= 127
    else:
        exp_prod = 0

    # Overflow → saturate; underflow already handled above
    if exp_prod >= 0xFF:
        rtol_y_approx = float('inf')
    elif exp_prod == 0:
        rtol_y_approx = 0.0
    else:
        # Reconstruct float with mantissa = 0 (implicit 1.0)
        rtol_y_approx = bits_to_f32(exp_prod << 23)

    return max(atol, rtol_y_approx)


# ---------------------------------------------------------------------------
# Single Dormand-Prince RK45 step
# Returns: (y_new, x_new, err_estimate)
# ---------------------------------------------------------------------------
def dp_step(x: float, y: float, h: float) -> tuple:
    # Stage coefficients (from k_block_pipe.vhd comments)
    c2 = 1.0/5.0;   c3 = 3.0/10.0;  c4 = 4.0/5.0;  c5 = 8.0/9.0

    a21 = 1.0/5.0
    a31 = 3.0/40.0;      a32 =  9.0/40.0
    a41 = 44.0/45.0;     a42 = -56.0/15.0;    a43 =  32.0/9.0
    a51 = 19372.0/6561.0; a52 = -25360.0/2187.0; a53 = 64448.0/6561.0; a54 = -212.0/729.0
    a61 =  9017.0/3168.0; a62 =  -355.0/33.0;    a63 = 46732.0/5247.0
    a64 =    49.0/176.0;  a65 =  -5103.0/18656.0

    # 5th-order solution weights
    b1 =   35.0/384.0;   b3 =  500.0/1113.0
    b4 =  125.0/192.0;   b5 = -2187.0/6784.0;   b6 =   11.0/84.0

    # Error weights (FSAL: uses k7)
    e1 =    71.0/57600.0; e3 =   -71.0/16695.0;  e4 =   71.0/1920.0
    e5 = -17253.0/339200.0; e6 =  22.0/525.0;    e7 =   -1.0/40.0

    k1 = f_ode(x,            y)
    k2 = f_ode(x + c2*h,     y + h*a21*k1)
    k3 = f_ode(x + c3*h,     y + h*(a31*k1 + a32*k2))
    k4 = f_ode(x + c4*h,     y + h*(a41*k1 + a42*k2 + a43*k3))
    k5 = f_ode(x + c5*h,     y + h*(a51*k1 + a52*k2 + a53*k3 + a54*k4))
    k6 = f_ode(x + h,        y + h*(a61*k1 + a62*k2 + a63*k3 + a64*k4 + a65*k5))

    y_new = y + h*(b1*k1 + b3*k3 + b4*k4 + b5*k5 + b6*k6)
    x_new = x + h

    k7 = f_ode(x_new, y_new)   # FSAL: first stage of next step

    err = h*(e1*k1 + e3*k3 + e4*k4 + e5*k5 + e6*k6 + e7*k7)

    return y_new, x_new, err


# ---------------------------------------------------------------------------
# Adaptive solver loop (mirrors adaptive_fsm in Top_pipe.vhd)
# ---------------------------------------------------------------------------
def run_solver(x0, y0, h0, atol, rtol, x_end, max_iter=4096, verbose=True):
    x, y, h = x0, y0, h0
    iters    = 0
    steps    = []

    if verbose:
        header = f"{'Step':>4}  {'x':>24}  {'y':>24}  {'err':>14}  {'accepted':>8}"
        print(header)
        print('-' * len(header))

    while x < x_end and iters < max_iter:
        # Clamp final step to hit x_end exactly
        h_use = min(h, x_end - x)

        y_new, x_new, err = dp_step(x, y, h_use)
        iters += 1

        tol     = hw_eff_tol(y_new, atol, rtol)
        abs_err = abs(err)

        if abs_err > tol:
            # Reject: halve h
            h = h / 2.0
            if verbose:
                print(f"      [rejected]  |err|={abs_err:.4e} > tol={tol:.4e}  h->{h:.6f}")
        elif abs_err < tol / 32.0:
            # Accept and grow h
            steps.append((x_new, y_new, err))
            x, y = x_new, y_new
            h = h_use * 2.0
            if verbose:
                x_hex = f32_hex(x)
                y_hex = f32_hex(y)
                e_hex = f32_hex(err)
                print(f"{len(steps):>4}  {x_hex}({x:>12.8f})  "
                      f"{y_hex}({y:>14.10f})  {e_hex}  grow")
        else:
            # Accept, keep h
            steps.append((x_new, y_new, err))
            x, y = x_new, y_new
            if verbose:
                x_hex = f32_hex(x)
                y_hex = f32_hex(y)
                e_hex = f32_hex(err)
                print(f"{len(steps):>4}  {x_hex}({x:>12.8f})  "
                      f"{y_hex}({y:>14.10f})  {e_hex}  keep")

    return x, y, steps, iters


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if __name__ == '__main__':
    # Decode hardware register values as Python floats
    x0    = bits_to_f32(REG[1])   # 2.0
    y0    = bits_to_f32(REG[2])   # 1.0
    h0    = bits_to_f32(REG[3])   # 0.1
    atol  = bits_to_f32(REG[4])   # ~0.05
    x_end = bits_to_f32(REG[5])   # 2.5
    rtol  = bits_to_f32(REG[6])   # ~0.01666

    print("=" * 72)
    print("RK45 Software Reference  (matches hardware step acceptance logic)")
    print("=" * 72)
    print(f"ODE:    dy/dx = 50*(x-y)+1")
    print(f"IC:     y({x0}) = {y0}")
    print(f"x_end:  {x_end}")
    print(f"atol:   {atol:.6f}  ({f32_hex(atol)})")
    print(f"rtol:   {rtol:.6f}  ({f32_hex(rtol)})")
    print(f"h0:     {h0:.6f}  ({f32_hex(h0)})")
    print()

    x_f, y_f, steps, iters = run_solver(x0, y0, h0, atol, rtol, x_end)

    # Analytical answer: y(10) = 10 - exp(100 - 50*10) = 10 - exp(-400) ≈ 10.0
    y_exact = 10.0 - math.exp(-400) if -400 > -700 else 10.0

    print()
    print("=" * 72)
    print("SUMMARY")
    print("=" * 72)
    print(f"  Steps taken : {len(steps)}")
    print(f"  Iterations  : {iters}  (includes rejected steps)")
    print(f"  x_final     : {x_f:.10f}  ({f32_hex(x_f)})")
    print(f"  y_final     : {y_f:.10f}  ({f32_hex(y_f)})")
    print(f"  y_exact     : {y_exact:.10f}")
    print(f"  |error|     : {abs(y_f - y_exact):.4e}")
    print(f"  within atol : {'YES' if abs(y_f - y_exact) < atol else 'NO'}")
    print(f"  (atol={atol}, rtol={rtol}, x_end={x_end})")
    print()
    print("How to compare against VHDL simulation:")
    print("  1. Run Vivado behavioural simulation of Top_TB_pipe.")
    print("  2. Capture the transcript; extract lines beginning with [STEP N].")
    print("  3. Compare the hex values column-by-column against this output.")
    print("  4. x and y should match to 1 ULP; larger deviations indicate")
    print("     a pipeline timing error or wrong Butcher coefficient.")
    print("=" * 72)
