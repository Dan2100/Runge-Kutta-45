"""
generate_resource_comparison.py
4-panel comparison figure: RK4 (fixed-step, SP, post-route) vs
                           RK45 (adaptive, DP, post-synthesis)
Artix-7 XC7A200T — sized for a full IEEE two-column figure (~7 in wide).
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import os

# ---------------------------------------------------------------------------
# Data
# ---------------------------------------------------------------------------
C_RK4  = "#4F81BD"   # steel blue  — RK4
C_RK45 = "#C0504D"   # brick red   — RK45

# (a) Fmax (MHz)
FMAX_RK4  = 276.5   # post-route
FMAX_RK45 = 185.0   # post-synthesis

# (b) Power breakdown (W)
PWR = {
    #            RK4     RK45
    "Clocks":  (0.046,  0.182),
    "Logic":   (0.064,  0.188),
    "Signals": (0.081,  0.170),
    "DSPs":    (0.031,  0.032),
    "I/O":     (0.025,  0.000),
    "Static":  (0.132,  0.124),
}
PWR_COLORS = {
    "Clocks":  "#2E75B6",
    "Logic":   "#ED7D31",
    "Signals": "#70AD47",
    "DSPs":    "#FFC000",
    "I/O":     "#9DC3E6",
    "Static":  "#BFBFBF",
}
PWR_TOTALS = (0.378, 0.696)   # (RK4, RK45)

# (c) Resource utilization %
RES_NAMES = ["Slice LUTs", "Slice Regs", "DSP48E1"]
RK4_PCT   = [4.14,  4.21,  6.49]
RK45_PCT  = [21.50, 28.39, 9.19]
RK4_ABS   = [5_575,  11_332, 48]
RK45_ABS  = [28_935, 76_432, 68]

# ---------------------------------------------------------------------------
# Figure skeleton  (2 × 2)
# ---------------------------------------------------------------------------
fig, axes = plt.subplots(2, 2, figsize=(7.0, 4.6))
(ax_fmax, ax_pwr), (ax_pct, ax_abs) = axes

LSIZ = 7.5    # axis-label font size
TSIZ = 7.0    # tick font size
HSIZ = 8.5    # panel-title font size
VSIZ = 6.5    # value-label font size

for ax in axes.flat:
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.tick_params(labelsize=TSIZ)

# ---------------------------------------------------------------------------
# (a)  Fmax
# ---------------------------------------------------------------------------
ax = ax_fmax
x_pos  = [0, 1]
x_lbls = ["RK4\n", "RK45\n"]
bars = ax.bar(x_pos, [FMAX_RK4, FMAX_RK45],
              color=[C_RK4, C_RK45], width=0.45, zorder=3)
ax.set_xticks(x_pos)
ax.set_xticklabels(x_lbls, fontsize=TSIZ)
ax.set_ylabel("Fmax (MHz)", fontsize=LSIZ)
ax.set_ylim(0, 350)
ax.yaxis.grid(True, color="#e8e8e8", linewidth=0.6, zorder=0)
ax.set_axisbelow(True)
ax.set_title("(a)  Maximum Clock Frequency", fontsize=HSIZ, pad=4)

for bar, val in zip(bars, [FMAX_RK4, FMAX_RK45]):
    ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 6,
            f"{val:.1f} MHz", ha="center", va="bottom",
            fontsize=VSIZ, fontweight="bold")

# ---------------------------------------------------------------------------
# (b)  Power breakdown — stacked horizontal bars
# ---------------------------------------------------------------------------
ax = ax_pwr
y_des = np.array([0.0, 1.0])    # two rows: RK4, RK45
BAR_H = 0.42

lefts = np.zeros(2)
legend_patches = []
for comp, (rk4_w, rk45_w) in PWR.items():
    vals = np.array([rk4_w, rk45_w])
    ax.barh(y_des, vals, left=lefts, height=BAR_H,
            color=PWR_COLORS[comp], zorder=3, label=comp)
    # Label segments wide enough to read (>0.025 W)
    for i, (v, l) in enumerate(zip(vals, lefts)):
        if v >= 0.025:
            ax.text(l + v / 2, y_des[i],
                    f"{v:.3f}", ha="center", va="center",
                    fontsize=5.2, color="white" if comp != "I/O" else "#333")
    lefts = lefts + vals

# Total labels at right end
for i, (tot, y) in enumerate(zip(PWR_TOTALS, y_des)):
    ax.text(tot + 0.008, y, f"{tot:.3f} W",
            va="center", ha="left", fontsize=6.0, fontweight="bold")

ax.set_yticks(y_des)
ax.set_yticklabels(["RK4", "RK45"], fontsize=TSIZ)
ax.set_xlabel("Power (W)", fontsize=LSIZ)
ax.set_xlim(0, 0.85)
ax.xaxis.grid(True, color="#e8e8e8", linewidth=0.6, zorder=0)
ax.set_axisbelow(True)
ax.set_title("(b)  Power Breakdown", fontsize=HSIZ, pad=4)
ax.legend(fontsize=5.5, loc="lower right", frameon=False, ncol=3,
          handlelength=1.0, handletextpad=0.4, columnspacing=0.6,
          borderpad=0)

# ---------------------------------------------------------------------------
# (c)  Resource utilization %
# ---------------------------------------------------------------------------
ax = ax_pct
n   = len(RES_NAMES)
y   = np.arange(n)
h   = 0.32

bars4  = ax.barh(y + h / 2, RK4_PCT,  height=h, color=C_RK4,  zorder=3,
                 label="RK4")
bars45 = ax.barh(y - h / 2, RK45_PCT, height=h, color=C_RK45, zorder=3,
                 label="RK45")

THRESH = 5.5
for bar, pct in zip(bars4, RK4_PCT):
    xw  = bar.get_width()
    ym  = bar.get_y() + bar.get_height() / 2
    if pct >= THRESH:
        ax.text(xw - 0.4, ym, f"{pct:.1f}%",
                va="center", ha="right", fontsize=5.5, color="white", zorder=4)
    else:
        ax.text(xw + 0.4, ym, f"{pct:.1f}%",
                va="center", ha="left", fontsize=5.5, color="#333333", zorder=4)

for bar, pct in zip(bars45, RK45_PCT):
    xw = bar.get_width()
    ym = bar.get_y() + bar.get_height() / 2
    ax.text(xw - 0.4, ym, f"{pct:.1f}%",
            va="center", ha="right", fontsize=5.5, color="white", zorder=4)

ax.set_yticks(y)
ax.set_yticklabels(RES_NAMES, fontsize=TSIZ)
ax.set_xlabel("Device Utilization (%)", fontsize=LSIZ)
ax.set_xlim(0, 36)
ax.set_ylim(-0.7, n - 0.2)
ax.xaxis.grid(True, color="#e8e8e8", linewidth=0.6, zorder=0)
ax.set_axisbelow(True)
ax.set_title("(c)  Resource Utilization", fontsize=HSIZ, pad=4)
ax.legend(handles=[bars4, bars45], fontsize=6.0, frameon=False,
          loc="upper right", handlelength=1.2, handletextpad=0.5)

# ---------------------------------------------------------------------------
# (d)  Absolute resource counts (log scale)
# ---------------------------------------------------------------------------
ax = ax_abs

bars4a  = ax.barh(y + h / 2, RK4_ABS,  height=h, color=C_RK4,  zorder=3,
                  label="RK4")
bars45a = ax.barh(y - h / 2, RK45_ABS, height=h, color=C_RK45, zorder=3,
                  label="RK45")

ax.set_xscale("log")
ax.set_yticks(y)
ax.set_yticklabels(RES_NAMES, fontsize=TSIZ)
ax.set_xlabel("Count (log scale)", fontsize=LSIZ)
ax.set_ylim(-0.7, n - 0.2)
ax.xaxis.grid(True, color="#e8e8e8", linewidth=0.6, zorder=0, which="both")
ax.set_axisbelow(True)
ax.set_title("(d)  Absolute Resource Counts", fontsize=HSIZ, pad=4)

for bar, val in zip(bars4a, RK4_ABS):
    ax.text(bar.get_width() * 1.12, bar.get_y() + bar.get_height() / 2,
            f"{val:,}", va="center", ha="left", fontsize=5.5, color="#333333")
for bar, val in zip(bars45a, RK45_ABS):
    ax.text(bar.get_width() * 1.12, bar.get_y() + bar.get_height() / 2,
            f"{val:,}", va="center", ha="left", fontsize=5.5, color="#333333")

ax.legend(handles=[bars4a, bars45a], fontsize=6.0, frameon=False,
          loc="upper right", handlelength=1.2)

# ---------------------------------------------------------------------------
# Save
# ---------------------------------------------------------------------------
fig.tight_layout(pad=0.7, h_pad=1.8, w_pad=1.4)

base = os.path.normpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "..", "..", "docs/diagrams", "resource_comparison"))

fig.savefig(base + ".png", format="png", dpi=300, bbox_inches="tight")
print(f"Saved: {base}.png")
