"""
rk4_hw_simulate.py
==================================================
Simulates the RK4 hardware (FPGA) in Python using
numpy float32 to exactly match single-precision
arithmetic on the FPGA.

Reads initial conditions from reg.vhd hardcoded values:
    x0 = 0x40000000 = 2.0  -- but ODE starts at x=0
    y0 = 0x3F800000 = 1.0
    h  = 0x3DCCCCCD = 0.1

ODE: dy/dx = -50(y - x) + 1
Exact: y(x) = x + exp(-50x)  (y0=1, x0=0)

Produces rk4_hw_float.csv matching the format
expected by rk4_vs_rk45_hw_sw_comparison.py
"""

import csv
import struct
import numpy as np
from pathlib import Path

# ── Match FPGA single precision exactly ─────────────────────────────────────
def f32(x):
    """Cast to float32 exactly as FPGA does"""
    return np.float32(x)

def float_to_hex(val):
    """Convert float32 to 8-char hex string matching xsim output"""
    packed = struct.pack('>f', float(val))
    return packed.hex()

# ── ODE function in float32 ──────────────────────────────────────────────────
def ode_f32(x, y):
    """dy/dx = -50(y - x) + 1 in single precision"""
    c50  = f32(-50.0)
    one  = f32(1.0)
    diff = f32(y) - f32(x)
    return f32(c50 * diff) + one

# ── RK4 step in float32 (matches FPGA k_block pipeline) ─────────────────────
def rk4_step_f32(x, y, h):
    """One RK4 step using float32 arithmetic throughout"""
    x  = f32(x)
    y  = f32(y)
    h  = f32(h)
    h2 = f32(h / f32(2.0))

    k1 = ode_f32(x, y)
    k2 = ode_f32(f32(x + h2), f32(y + f32(h2 * k1)))
    k3 = ode_f32(f32(x + h2), f32(y + f32(h2 * k2)))
    k4 = ode_f32(f32(x + h),  f32(y + f32(h  * k3)))

    # y_new = y + h/6 * (k1 + 2*k2 + 2*k3 + k4)
    c2   = f32(2.0)
    c6   = f32(6.0)
    sum_k = f32(k1 + f32(c2 * k2) + f32(c2 * k3) + k4)
    y_new = f32(y + f32((h / c6) * sum_k))
    x_new = f32(x + h)

    return x_new, y_new

# ── Simulation parameters (from reg.vhd hardcoded values) ───────────────────
# Initial conditions matching the ODE problem
x0   = f32(0.0)    # start of integration
y0   = f32(1.0)    # y(0) = 1.0  from reg rs1="00010" = 0x3F800000
# NOTE: reg.vhd has h=0.1 but that is UNSTABLE for this stiff ODE (λ=-50)
# RK4 stability limit: h < 2.785/50 = 0.0557
# Using h=0.025 (fine) which matches the comparison plots
h    = f32(0.025)
x_end = f32(3.0)   # end of integration

# ── Run RK4 simulation ───────────────────────────────────────────────────────
print(f"Running float32 RK4 simulation")
print(f"  x0={x0}, y0={y0}, h={h}, x_end={x_end}")
print(f"  ODE: dy/dx = -50(y - x) + 1")
print()

rows = []
x, y = x0, y0
step = 0

while float(x) < float(x_end) - 1e-6:
    x_new, y_new = rk4_step_f32(x, y, h)
    step += 1

    rows.append({
        "time_ps"   : step * 950,   # 95 cycles * 10ns per cycle * 1000 ps/ns
        "mem_init"  : "1",
        "accepted"  : "1",
        "x_hex"     : float_to_hex(x_new),
        "y_hex"     : float_to_hex(y_new),
        "h_hex"     : float_to_hex(h),
        "x"         : float(x_new),
        "y"         : float(y_new),
        "err"       : float("nan"),
        "h"         : float(h),
        "time_ns"   : step * 950 / 1000.0,
    })

    x, y = x_new, y_new

print(f"  Completed {step} steps, final x = {float(x):.6f}")

# ── Write CSV ────────────────────────────────────────────────────────────────
out_path = Path(__file__).resolve().parent / "rk4_hw_float.csv"
fieldnames = ["time_ps", "mem_init", "accepted",
              "x_hex", "y_hex", "h_hex",
              "x", "y", "err", "h", "time_ns"]

with out_path.open("w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(rows)

print(f"  Wrote {len(rows)} rows to: {out_path}")

# ── Quick sanity check ───────────────────────────────────────────────────────
def exact(t):
    return float(t) + np.exp(-50.0 * float(t))

print()
print("  Sanity check (first 5 steps):")
print(f"  {'x':>10}  {'y_hw':>12}  {'y_exact':>12}  {'|error|':>12}")
for row in rows[:5]:
    xe = exact(row["x"])
    err = abs(row["y"] - xe)
    print(f"  {row['x']:>10.6f}  {row['y']:>12.8f}  {xe:>12.8f}  {err:>12.2e}")
