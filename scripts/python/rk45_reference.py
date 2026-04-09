"""
rk45_reference.py — Python Golden Reference for Hardware RK45 Verification
===========================================================================
Solves the test ODE:
    dy/dx = f(x, y) = -50*(y - x) + 1
    y(0) = 1.0    over x ∈ [0, 1]

Exact analytical solution (derived via v=y-x substitution):
    y(x) = x + (y0 - x0) * exp(-50*(x - x0))
         = x + exp(-50*x)    [for x0=0, y0=1]

Outputs two CSV files:
  - rk45_scipy_trajectory.csv   : step-by-step scipy RK45 trajectory
  - rk45_exact_trajectory.csv   : analytical solution sampled at same points

Usage:
    python scripts/python/rk45_reference.py

Requires: numpy, scipy, matplotlib (pip install numpy scipy matplotlib)
"""

import numpy as np
from scipy.integrate import solve_ivp
import csv
import os

# ---------------------------------------------------------------------------
# ODE definition
# ---------------------------------------------------------------------------
def f(x, y):
    """dy/dx = -50*(y - x) + 1"""
    return -50.0 * (y[0] - x) + 1.0

def f_scalar(x, y_scalar):
    return -50.0 * (y_scalar - x) + 1.0

# ---------------------------------------------------------------------------
# Analytical solution
# ---------------------------------------------------------------------------
def exact_solution(x, x0=0.0, y0=1.0):
    """y(x) = x + (y0 - x0)*exp(-50*(x-x0))"""
    return x + (y0 - x0) * np.exp(-50.0 * (x - x0))

# ---------------------------------------------------------------------------
# Solver parameters — match hardware configuration
# ---------------------------------------------------------------------------
X_START = 0.0
X_END   = 1.0
Y0      = 1.0
RTOL    = 1e-6
ATOL    = 1e-9
H0      = 0.1       # initial step size hint

# ---------------------------------------------------------------------------
# Run scipy RK45
# ---------------------------------------------------------------------------
print("Solving ODE with scipy RK45...")
sol = solve_ivp(
    fun=lambda x, y: [f_scalar(x, y[0])],
    t_span=(X_START, X_END),
    y0=[Y0],
    method='RK45',
    rtol=RTOL,
    atol=ATOL,
    first_step=H0,
    dense_output=False,
    max_step=np.inf
)

if not sol.success:
    raise RuntimeError(f"scipy RK45 failed: {sol.message}")

xs      = sol.t            # x values at accepted steps
ys      = sol.y[0]         # y values at accepted steps
n_steps = len(xs)
print(f"  Accepted steps: {n_steps}")
print(f"  Final y({X_END:.1f}) = {ys[-1]:.15e}")
print(f"  Exact  y({X_END:.1f}) = {exact_solution(X_END):.15e}")

# ---------------------------------------------------------------------------
# Compute exact solution and relative error at each step
# ---------------------------------------------------------------------------
y_exact = np.array([exact_solution(x) for x in xs])
rel_err = np.abs(ys - y_exact) / (ATOL + RTOL * np.abs(y_exact))

# ---------------------------------------------------------------------------
# Write scipy trajectory CSV
# ---------------------------------------------------------------------------
out_dir = os.path.dirname(os.path.abspath(__file__))
scipy_csv = os.path.join(out_dir, "rk45_scipy_trajectory.csv")

with open(scipy_csv, 'w', newline='') as f_out:
    writer = csv.writer(f_out)
    writer.writerow(["step", "x", "y_scipy", "y_exact", "rel_err_vs_exact"])
    for i in range(n_steps):
        writer.writerow([i, f"{xs[i]:.17e}", f"{ys[i]:.17e}",
                         f"{y_exact[i]:.17e}", f"{rel_err[i]:.6e}"])

print(f"\nWrote: {scipy_csv}")

# ---------------------------------------------------------------------------
# Write exact solution on fine grid
# ---------------------------------------------------------------------------
x_fine    = np.linspace(X_START, X_END, 1000)
y_fine    = exact_solution(x_fine)
exact_csv = os.path.join(out_dir, "rk45_exact_trajectory.csv")

with open(exact_csv, 'w', newline='') as f_out:
    writer = csv.writer(f_out)
    writer.writerow(["x", "y_exact"])
    for xi, yi in zip(x_fine, y_fine):
        writer.writerow([f"{xi:.17e}", f"{yi:.17e}"])

print(f"Wrote: {exact_csv}")

# ---------------------------------------------------------------------------
# Print step summary
# ---------------------------------------------------------------------------
print("\n--- Step Summary (first 10 steps) ---")
print(f"{'step':>5}  {'x':>22}  {'y_scipy':>22}  {'y_exact':>22}  {'rel_err':>12}")
for i in range(min(10, n_steps)):
    print(f"{i:>5}  {xs[i]:>22.15e}  {ys[i]:>22.15e}  "
          f"{y_exact[i]:>22.15e}  {rel_err[i]:>12.4e}")
if n_steps > 10:
    print(f"  ... ({n_steps - 10} more steps)")
print(f"\n{'PASS' if np.all(rel_err < 10.0) else 'WARN'}: "
      f"max normalised error = {np.max(rel_err):.4e}")

# ---------------------------------------------------------------------------
# Optional: plot
# ---------------------------------------------------------------------------
try:
    import matplotlib.pyplot as plt

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 8))

    ax1.plot(x_fine, y_fine, 'b-', linewidth=1.5, label='Exact solution')
    ax1.plot(xs, ys, 'r+', markersize=8, label=f'scipy RK45 ({n_steps} steps)')
    ax1.set_xlabel('x')
    ax1.set_ylabel('y(x)')
    ax1.set_title("ODE: dy/dx = -50(y-x)+1,  y(0)=1")
    ax1.legend()
    ax1.grid(True, alpha=0.3)

    ax2.semilogy(xs, rel_err + 1e-20, 'g.-', label='Rel. error vs exact')
    ax2.axhline(RTOL, color='orange', linestyle='--', label=f'rtol={RTOL}')
    ax2.set_xlabel('x')
    ax2.set_ylabel('Normalised error')
    ax2.set_title('scipy RK45: error at accepted steps')
    ax2.legend()
    ax2.grid(True, alpha=0.3)

    plt.tight_layout()
    plot_path = os.path.join(out_dir, "rk45_reference_plot.png")
    plt.savefig(plot_path, dpi=150)
    print(f"Wrote: {plot_path}")
    plt.close()
except ImportError:
    print("(matplotlib not installed — skipping plot)")
