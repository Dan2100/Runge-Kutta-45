"""
generate_hw_sw_comparison.py — HW vs SW RK45 comparison plot
=============================================================
Reads hardware simulation output from sim_rk45_top/rk45_output.txt
and compares against scipy RK45 + exact analytical solution.

Style matches hw_sw_rk45_comparison.py reference.

Usage:
    python scripts/python/generate_hw_sw_comparison.py
"""

import re
import numpy as np
import matplotlib.pyplot as plt
from scipy.integrate import solve_ivp
from pathlib import Path

plt.rcParams.update({
    "font.family": "monospace",
    "axes.facecolor": "#0d1117",
    "figure.facecolor": "#0d1117",
    "axes.edgecolor": "#30363d",
    "axes.labelcolor": "#e6edf3",
    "xtick.color": "#8b949e",
    "ytick.color": "#8b949e",
    "grid.color": "#21262d",
    "grid.linewidth": 0.8,
    "text.color": "#e6edf3",
})

BLUE  = "#58a6ff"
GREEN = "#3fb950"
WHITE = "#e6edf3"

# ODE: dy/dx = -50(y - x) + 1
# Exact solution: y(x) = x + exp(-50x)  (y0=1, x0=0)
def f(t, y):
    return [-50.0 * (y[0] - t) + 1.0]

def exact(t):
    return t + np.exp(-50.0 * t)

# ── Hardware results (from xsim output) ──────────────────────────────────────
root = Path(__file__).resolve().parent.parent.parent
hw_path = root / "sim_rk45_top" / "rk45_output.txt"
if not hw_path.exists():
    raise SystemExit(f"Hardware output not found: {hw_path}\nRun scripts/run_rk45_top_tb.bat first.")

t_hw, y_hw, err_hw_raw = [], [], []
with hw_path.open() as fp:
    for line in fp:
        if line.startswith("#") or line.strip() == "":
            continue
        parts = line.split()
        if len(parts) >= 7:
            try:
                t_hw.append(float(parts[4]))
                y_hw.append(float(parts[5]))
                err_hw_raw.append(float(parts[6]))
            except (ValueError, IndexError):
                pass

t_hw = np.array(t_hw)
y_hw = np.array(y_hw)
h_hw = np.diff(t_hw)

t0, tf = t_hw[0], t_hw[-1]
y0 = [y_hw[0] if len(y_hw) > 0 else 1.0]

# Use the actual integration bounds for software comparison
t0_int, tf_int = 0.0, 1.0

# ── Software RK45 (scipy, matching tolerances) ──────────────────────────────
sol45 = solve_ivp(f, [t0_int, tf_int], [1.0], method='RK45',
                  rtol=1e-6, atol=1e-9, dense_output=False)
t_sw = sol45.t
y_sw = sol45.y[0]
h_sw = np.diff(t_sw)

# ── Exact reference ──────────────────────────────────────────────────────────
t_fine = np.linspace(t0_int, tf_int, 5000)
y_true = exact(t_fine)

# ── Errors vs exact ─────────────────────────────────────────────────────────
err_sw = np.abs(y_sw - exact(t_sw))
err_hw = np.abs(y_hw - exact(t_hw))

# Clamp zero errors for log plot
err_sw = np.maximum(err_sw, 1e-18)
err_hw = np.maximum(err_hw, 1e-18)

# ── Plot ─────────────────────────────────────────────────────────────────────
fig, (ax1, ax2, ax3) = plt.subplots(
    3, 1, figsize=(10, 9), sharex=True,
    gridspec_kw={'height_ratios': [2.2, 1, 1], 'hspace': 0.06}
)

# Panel 1 — Trajectories
ax1.plot(t_fine, y_true, color=WHITE, lw=1.2, label="Exact solution", zorder=2)
ax1.plot(t_sw, y_sw, color=GREEN, lw=1.6,
         label=f"RK45 SW adaptive ({len(t_sw)-1} steps)", zorder=3)
ax1.plot(t_hw, y_hw, color=BLUE, lw=1.6, ls='--',
         label=f"RK45 HW (FPGA, {len(t_hw)} steps)", zorder=4)
ax1.set_ylabel("y(x)")
ax1.legend(framealpha=0.2, fontsize=8.5)
ax1.grid(True)
ax1.set_title(
    r"RK45 Hardware (FPGA) vs Software: $dy/dx = -50(y - x) + 1$",
    fontsize=13, fontweight="bold", pad=10
)

# Panel 2 — Absolute error
ax2.semilogy(t_sw, err_sw, color=GREEN, lw=1.6, label="RK45 SW")
ax2.semilogy(t_hw, err_hw, color=BLUE, lw=1.6, ls='--', label="RK45 HW")
ax2.set_ylabel("|error|")
ax2.legend(framealpha=0.2, fontsize=8.5)
ax2.grid(True, which='both')

# Panel 3 — Step sizes
ax3.step(t_sw[:-1], h_sw, color=GREEN, lw=2, where='post', label="RK45 SW h")
ax3.step(t_hw[:-1], h_hw, color=BLUE, lw=2, where='post', ls='--', label="RK45 HW h")
ax3.set_ylabel("Step size h")
ax3.set_xlabel("x")
ax3.legend(framealpha=0.2, fontsize=8.5)
ax3.grid(True)

fig.tight_layout()
out = root / "scripts" / "python" / "hw_vs_sw_rk45.png"
plt.savefig(out, dpi=150, bbox_inches='tight')
print(f"Saved: {out}")
plt.show()
