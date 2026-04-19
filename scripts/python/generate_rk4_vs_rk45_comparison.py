"""
generate_rk4_vs_rk45_comparison.py — RK4 HW vs RK45 HW comparison plot
========================================================================
Compares:
  - RK4 hardware (single-precision, fixed step h=0.025) from rk4_hw_float.csv
  - RK45 hardware (double-precision, adaptive step)      from sim_rk45_top/rk45_output.txt
  - Exact analytical solution y(x) = x + exp(-50x)

Only compares over the common x-range [0, 1].

Usage:
    python scripts/python/generate_rk4_vs_rk45_comparison.py
"""

import csv
import numpy as np
import matplotlib.pyplot as plt
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

ORANGE = "#d29922"
BLUE   = "#58a6ff"
WHITE  = "#e6edf3"

# Exact solution: y(x) = x + exp(-50x)  (y0=1, x0=0)
def exact(t):
    return t + np.exp(-50.0 * t)

root = Path(__file__).resolve().parent.parent.parent

# ── RK4 hardware results (single-precision, fixed step) ─────────────────────
rk4_path = Path(__file__).resolve().parent / "rk4_hw_float.csv"
if not rk4_path.exists():
    raise SystemExit(f"RK4 hardware CSV not found: {rk4_path}")

t_rk4_all, y_rk4_all, h_rk4_all = [], [], []
with rk4_path.open() as fp:
    reader = csv.DictReader(fp)
    for row in reader:
        t_rk4_all.append(float(row["x"]))
        y_rk4_all.append(float(row["y"]))
        h_rk4_all.append(float(row["h"]))

t_rk4_all = np.array(t_rk4_all)
y_rk4_all = np.array(y_rk4_all)

# Filter to x <= 1.0 (common range with RK45)
mask = t_rk4_all <= 1.0 + 1e-9
t_rk4 = t_rk4_all[mask]
y_rk4 = y_rk4_all[mask]
h_rk4 = np.diff(t_rk4)

# ── RK45 hardware results (double-precision, adaptive) ──────────────────────
hw_path = root / "sim_rk45_top" / "rk45_output.txt"
if not hw_path.exists():
    raise SystemExit(f"RK45 hardware output not found: {hw_path}\nRun scripts/run_rk45_top_tb.bat first.")

t_rk45, y_rk45 = [], []
with hw_path.open() as fp:
    for line in fp:
        if line.startswith("#") or line.strip() == "":
            continue
        parts = line.split()
        if len(parts) >= 7:
            try:
                t_rk45.append(float(parts[4]))
                y_rk45.append(float(parts[5]))
            except (ValueError, IndexError):
                pass

t_rk45 = np.array(t_rk45)
y_rk45 = np.array(y_rk45)
h_rk45 = np.diff(t_rk45)

# ── Exact reference ──────────────────────────────────────────────────────────
t_fine = np.linspace(0.0, 1.0, 5000)
y_true = exact(t_fine)

# ── Errors vs exact ─────────────────────────────────────────────────────────
err_rk4  = np.abs(y_rk4  - exact(t_rk4))
err_rk45 = np.abs(y_rk45 - exact(t_rk45))

# Clamp zero errors for log plot
err_rk4  = np.maximum(err_rk4,  1e-18)
err_rk45 = np.maximum(err_rk45, 1e-18)

# ── Summary statistics ───────────────────────────────────────────────────────
print(f"RK4  HW:  {len(t_rk4)} steps (fixed h={h_rk4_all[0]:.4f}), "
      f"single-precision, x ∈ [0, {t_rk4[-1]:.3f}]")
print(f"RK45 HW:  {len(t_rk45)} steps (adaptive), "
      f"double-precision, x ∈ [0, {t_rk45[-1]:.3f}]")
print()
print(f"RK4  max |error| vs exact:  {np.max(err_rk4):.6e}")
print(f"RK45 max |error| vs exact:  {np.max(err_rk45):.6e}")
print(f"RK4  mean |error| vs exact: {np.mean(err_rk4):.6e}")
print(f"RK45 mean |error| vs exact: {np.mean(err_rk45):.6e}")

# ── Plot ─────────────────────────────────────────────────────────────────────
fig, (ax1, ax2, ax3) = plt.subplots(
    3, 1, figsize=(10, 9), sharex=True,
    gridspec_kw={'height_ratios': [2.2, 1, 1], 'hspace': 0.06}
)

# Panel 1 — Trajectories
ax1.plot(t_fine, y_true, color=WHITE, lw=1.2, label="Exact solution", zorder=2)
ax1.plot(t_rk4, y_rk4, color=ORANGE, lw=1.6,
         label=f"RK4 HW (fixed, {len(t_rk4)} steps)", zorder=3)
ax1.plot(t_rk45, y_rk45, color=BLUE, lw=1.6, ls='--',
         label=f"RK45 HW (adaptive, {len(t_rk45)} steps)", zorder=4)
ax1.set_ylabel("y(x)")
ax1.legend(framealpha=0.2, fontsize=8.5)
ax1.grid(True)
ax1.set_title(
    r"RK4 vs RK45 Hardware: $dy/dx = -50(y - x) + 1$",
    fontsize=13, fontweight="bold", pad=10
)

# Panel 2 — Absolute error vs exact
ax2.semilogy(t_rk4,  err_rk4,  color=ORANGE, lw=1.6, label="RK4 HW")
ax2.semilogy(t_rk45, err_rk45, color=BLUE,   lw=1.6, ls='--', label="RK45 HW")
ax2.set_ylabel("|error| vs exact")
ax2.legend(framealpha=0.2, fontsize=8.5)
ax2.grid(True, which='both')

# Panel 3 — Step sizes
ax3.step(t_rk4[:-1],  h_rk4,  color=ORANGE, lw=2, where='post',
         label=f"RK4 h (fixed {h_rk4_all[0]:.4f})")
ax3.step(t_rk45[:-1], h_rk45, color=BLUE,   lw=2, where='post', ls='--',
         label="RK45 h (adaptive)")
ax3.set_ylabel("Step size h")
ax3.set_xlabel("x")
ax3.legend(framealpha=0.2, fontsize=8.5)
ax3.grid(True)

fig.tight_layout()
out = root / "scripts" / "python" / "rk4_vs_rk45_hw.png"
plt.savefig(out, dpi=150, bbox_inches='tight')
print(f"\nSaved: {out}")
plt.show()
