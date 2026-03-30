import csv
import struct
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

BLUE   = "#58a6ff"
GREEN  = "#3fb950"
WHITE  = "#e6edf3"

# ODE: dy/dx = -50(y - x) + 1
# Exact solution: y(x) = x + exp(-50x)  (y0=1, x0=0)
def f(t, y):
    return [-50 * (y[0] - t) + 1]

def exact(t):
    return t + np.exp(-50.0 * t)

t0, tf, y0 = 0.0, 3.0, [1.0]

# ── Software RK45 (scipy, double precision) ─────────────────────────────────
sol45 = solve_ivp(f, [t0, tf], y0, method='RK45', rtol=1e-4, atol=1e-6,
                  dense_output=False)
t_sw   = sol45.t
y_sw   = sol45.y[0]
h_sw   = np.diff(t_sw)

# ── Hardware RK45 (FPGA simulation results) ──────────────────────────────────
hw_path = Path(__file__).resolve().parent / "rk45_hw_float.csv"
if not hw_path.exists():
    raise SystemExit(f"Hardware CSV not found: {hw_path}\nRun hex_csv_to_float_table.py first.")

t_hw, y_hw, h_hw = [], [], []
with hw_path.open("r", newline="") as fp:
    for row in csv.DictReader(fp):
        try:
            t_hw.append(float(row["x"]))
            y_hw.append(float(row["y"]))
            h_hw.append(float(row["h"]))
        except (ValueError, KeyError):
            pass

t_hw = np.array(t_hw)
y_hw = np.array(y_hw)
h_hw = np.array(h_hw)

# ── Exact reference ──────────────────────────────────────────────────────────
t_fine = np.linspace(t0, tf, 5000)
y_true = exact(t_fine)

# ── Errors vs exact ──────────────────────────────────────────────────────────
err_sw = np.abs(y_sw  - exact(t_sw))
err_hw = np.abs(y_hw  - exact(t_hw))

# ── Plot ─────────────────────────────────────────────────────────────────────
fig, (ax1, ax2, ax3) = plt.subplots(
    3, 1, figsize=(10, 9), sharex=True,
    gridspec_kw={'height_ratios': [2.2, 1, 1], 'hspace': 0.06}
)

# Panel 1 — Trajectories
ax1.plot(t_fine, y_true, color=WHITE, lw=1.2, label="Exact solution", zorder=2)
ax1.plot(t_sw,   y_sw,   color=GREEN, lw=1.6,
         label=f"RK45 SW adaptive ({len(t_sw)-1} steps)", zorder=3)
ax1.plot(t_hw,   y_hw,   color=BLUE,  lw=1.6, ls='--',
         label=f"RK45 HW (FPGA, {len(t_hw)} steps)", zorder=4)
ax1.set_ylim(-0.1, 1.5)
ax1.set_ylabel("y(x)")
ax1.legend(framealpha=0.2, fontsize=8.5)
ax1.grid(True)
ax1.set_title(
    "RK45 Hardware (FPGA) vs Software — dy/dx = -50(y − x) + 1",
    fontsize=13, fontweight="bold", pad=10
)

# Panel 2 — Absolute error
ax2.semilogy(t_sw, err_sw, color=GREEN, lw=1.6, label="RK45 SW")
ax2.semilogy(t_hw, err_hw, color=BLUE,  lw=1.6, ls='--', label="RK45 HW")
ax2.set_ylabel("|error|")
ax2.legend(framealpha=0.2, fontsize=8.5)
ax2.grid(True, which='both')

# Panel 3 — Step sizes
ax3.step(t_sw[:-1], h_sw, color=GREEN, lw=2, where='post', label="RK45 SW h")
ax3.step(t_hw[:-1], h_hw[:-1], color=BLUE,  lw=2, where='post', ls='--', label="RK45 HW h")
ax3.set_ylabel("Step size h")
ax3.set_xlabel("x")
ax3.legend(framealpha=0.2, fontsize=8.5)
ax3.grid(True)

fig.tight_layout()
out = Path(__file__).resolve().parent / "hw_vs_sw_rk45.png"
plt.savefig(out, dpi=150, bbox_inches='tight')
print(f"Saved: {out}")
plt.show()
