import numpy as np
import matplotlib.pyplot as plt
from scipy.integrate import solve_ivp

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
ORANGE = "#f78166"
WHITE  = "#e6edf3"

# ODE: dy/dx = -50(y - x) + 1
# Exact solution: y(x) = x + 2*exp(-50x)  (for y(0) = 2)
def f(t, y):
    return [-50*(y[0] - t) + 1]

def exact(t, y0):
    return t + y0 * np.exp(-50*t)

t0, tf, y0 = 0.0, 3.0, [2.0]
t_fine = np.linspace(t0, tf, 5000)
y_true = exact(t_fine, y0[0])

def rk4_solve(f, t0, tf, y0, h):
    ts, ys = [t0], [y0[0]]
    t, y = t0, y0[0]
    while t < tf - 1e-10:
        h_cur = min(h, tf - t)
        k1 = f(t,            [y])[0]
        k2 = f(t + h_cur/2,  [y + h_cur*k1/2])[0]
        k3 = f(t + h_cur/2,  [y + h_cur*k2/2])[0]
        k4 = f(t + h_cur,    [y + h_cur*k3])[0]
        y += h_cur*(k1 + 2*k2 + 2*k3 + k4)/6
        t += h_cur
        ts.append(t); ys.append(y)
    return np.array(ts), np.array(ys)

h_rk4        = 0.02
h_rk4_coarse = 0.08
t_rk4,  y_rk4  = rk4_solve(f, t0, tf, y0, h_rk4)
t_rk4c, y_rk4c = rk4_solve(f, t0, tf, y0, h_rk4_coarse)

sol45 = solve_ivp(f, [t0, tf], y0, method='RK45', rtol=1e-4, atol=1e-6)
t_rk45 = sol45.t
y_rk45 = sol45.y[0]
step_sizes_45 = np.diff(t_rk45)

err_rk4  = np.abs(y_rk4  - exact(t_rk4,  y0[0]))
err_rk4c = np.abs(y_rk4c - exact(t_rk4c, y0[0]))
err_rk45 = np.abs(y_rk45 - exact(t_rk45, y0[0]))

fig, (ax1, ax2, ax3) = plt.subplots(3, 1, figsize=(10, 9), sharex=True,
                                     gridspec_kw={'height_ratios': [2.2, 1, 1], 'hspace': 0.06})

ax1.plot(t_fine, y_true, color=WHITE, lw=2.5, label="Exact solution", zorder=10)
ax1.plot(t_rk4,  y_rk4,  color=BLUE,   lw=1.6,
         label=f"RK4 fine (h={h_rk4}, {len(t_rk4)-1} steps)", zorder=3)
ax1.plot(t_rk4c, y_rk4c, color=ORANGE, lw=1.6, ls='--',
         label=f"RK4 coarse (h={h_rk4_coarse}, {len(t_rk4c)-1} steps)", zorder=2)
ax1.plot(t_rk45, y_rk45, color=GREEN,  lw=1.6,
         label=f"RK45 adaptive ({len(t_rk45)-1} steps)", zorder=4)
ax1.set_ylim(-0.5, 2.5)
ax1.set_ylabel("y(x)")
ax1.legend(framealpha=0.2, fontsize=8.5)
ax1.grid(True)
ax1.set_title("RK4 vs RK45 — dy/dx = -50(y - x) + 1", fontsize=13, fontweight="bold", pad=10)

ax2.semilogy(t_rk4,  err_rk4,  color=BLUE,   lw=1.6, label="RK4 fine")
ax2.semilogy(t_rk4c, err_rk4c, color=ORANGE, lw=1.6, ls='--', label="RK4 coarse")
ax2.semilogy(t_rk45, err_rk45, color=GREEN,  lw=1.6, label="RK45 adaptive")
ax2.set_ylabel("|error|")
ax2.legend(framealpha=0.2, fontsize=8.5)
ax2.grid(True, which='both')

ax3.hlines(h_rk4,        t0, tf, colors=BLUE,   lw=2,      label=f"RK4 fine h={h_rk4}")
ax3.hlines(h_rk4_coarse, t0, tf, colors=ORANGE, lw=2, ls='--', label=f"RK4 coarse h={h_rk4_coarse}")
ax3.step(t_rk45[:-1], step_sizes_45, color=GREEN, lw=2, where='post', label="RK45 adaptive h")
ax3.set_ylabel("Step size h")
ax3.set_xlabel("x")
ax3.legend(framealpha=0.2, fontsize=8.5)
ax3.grid(True)

fig.tight_layout()
plt.savefig("rk4_vs_rk45_stiff.png", dpi=150, bbox_inches='tight')
plt.show()