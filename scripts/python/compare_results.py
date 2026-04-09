"""
compare_results.py — Compare Hardware RK45 Output to Python Reference
======================================================================
Parses hardware simulation output (from testbench $fwrite) and compares
against the scipy RK45 trajectory CSV.

Usage:
    python scripts/python/compare_results.py <hw_output.txt> [scipy_csv]

hw_output.txt format (one line per accepted step, space-separated):
    <x_hex_64> <y_hex_64> <err_hex_64>
    OR
    <x_float> <y_float> <err_float>

If scipy_csv is omitted, uses scripts/python/rk45_scipy_trajectory.csv

Reports per-step comparison and pass/fail summary.
"""

import sys
import os
import struct
import csv
import numpy as np

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def hex64_to_double(h):
    """Convert 16-char hex string (or '0x' prefixed) to float64."""
    h = h.strip().replace("0x", "").replace("_", "")
    raw = int(h, 16)
    return struct.unpack('>d', struct.pack('>Q', raw))[0]

def parse_hw_line(line):
    """Parse one line of hardware output → (x, y, err) as floats."""
    parts = line.strip().split()
    if len(parts) < 3:
        return None
    vals = []
    for p in parts[:3]:
        p_clean = p.strip().rstrip(',').rstrip(';')
        if len(p_clean) == 16 and all(c in '0123456789abcdefABCDEF' for c in p_clean):
            vals.append(hex64_to_double(p_clean))
        elif p_clean.startswith("0x") or p_clean.startswith("0X"):
            vals.append(hex64_to_double(p_clean))
        else:
            vals.append(float(p_clean))
    return tuple(vals)

def exact_solution(x, x0=0.0, y0=1.0):
    """Analytical: y(x) = x + (y0-x0)*exp(-50*(x-x0))"""
    return x + (y0 - x0) * np.exp(-50.0 * (x - x0))

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <hw_output.txt> [scipy_csv]")
        sys.exit(1)

    hw_file = sys.argv[1]
    script_dir = os.path.dirname(os.path.abspath(__file__))
    scipy_csv = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        script_dir, "rk45_scipy_trajectory.csv")

    # --- Parse hardware output ---
    hw_steps = []
    with open(hw_file, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or line.startswith('//'):
                continue
            parsed = parse_hw_line(line)
            if parsed:
                hw_steps.append(parsed)

    print(f"Hardware output: {len(hw_steps)} accepted steps from {hw_file}")

    if len(hw_steps) == 0:
        print("ERROR: No valid steps parsed from hardware output.")
        sys.exit(1)

    hw_x   = np.array([s[0] for s in hw_steps])
    hw_y   = np.array([s[1] for s in hw_steps])
    hw_err = np.array([s[2] for s in hw_steps])

    # --- Load scipy reference ---
    scipy_x = []
    scipy_y = []
    if os.path.exists(scipy_csv):
        with open(scipy_csv, 'r') as f:
            reader = csv.DictReader(f)
            for row in reader:
                scipy_x.append(float(row['x']))
                scipy_y.append(float(row['y_scipy']))
        scipy_x = np.array(scipy_x)
        scipy_y = np.array(scipy_y)
        print(f"Scipy reference: {len(scipy_x)} steps from {scipy_csv}")
    else:
        print(f"WARNING: Scipy CSV not found at {scipy_csv}")
        print("         Comparing against analytical solution only.")
        scipy_x = None

    # --- Compare against exact solution ---
    y_exact     = np.array([exact_solution(x) for x in hw_x])
    abs_err     = np.abs(hw_y - y_exact)
    rel_err     = abs_err / (1e-9 + 1e-6 * np.abs(y_exact))  # atol + rtol*|y|

    RTOL = 1e-6
    ATOL = 1e-9

    print(f"\n{'step':>5}  {'x_hw':>22}  {'y_hw':>22}  {'y_exact':>22}  "
          f"{'abs_err':>12}  {'norm_err':>12}  {'PASS':>5}")
    print("-" * 110)

    all_pass = True
    for i in range(len(hw_steps)):
        tol = ATOL + RTOL * abs(y_exact[i])
        norm = abs_err[i] / tol
        ok = norm < 100.0  # generous: 100x tolerance for FP differences
        if not ok:
            all_pass = False
        print(f"{i:>5}  {hw_x[i]:>22.15e}  {hw_y[i]:>22.15e}  "
              f"{y_exact[i]:>22.15e}  {abs_err[i]:>12.4e}  {norm:>12.4e}  "
              f"{'OK' if ok else 'FAIL':>5}")

    print("-" * 110)
    print(f"\nMax normalised error vs exact: {np.max(rel_err):.6e}")
    print(f"Max absolute error vs exact:   {np.max(abs_err):.6e}")

    # --- Compare against scipy if available ---
    if scipy_x is not None and len(scipy_x) > 0:
        # Interpolate hw at scipy x-points for comparison
        n_compare = min(len(hw_x), len(scipy_x))
        if n_compare > 0:
            print(f"\n--- Scipy Comparison (first {min(n_compare, 10)} steps) ---")
            for i in range(min(n_compare, 10)):
                dx = abs(hw_x[i] - scipy_x[i]) if i < len(scipy_x) else float('nan')
                dy = abs(hw_y[i] - scipy_y[i]) if i < len(scipy_y) else float('nan')
                print(f"  step {i}: Δx={dx:.4e}  Δy={dy:.4e}")

    # --- Final verdict ---
    print(f"\n{'='*60}")
    if all_pass:
        print("RESULT: PASS — all hardware steps within tolerance of exact solution")
    else:
        print("RESULT: FAIL — some hardware steps exceeded tolerance")
    print(f"{'='*60}")

    # --- Optional plot ---
    try:
        import matplotlib.pyplot as plt

        fig, axes = plt.subplots(2, 1, figsize=(12, 8))

        # Trajectory comparison
        x_fine = np.linspace(hw_x[0], hw_x[-1], 500)
        axes[0].plot(x_fine, exact_solution(x_fine), 'b-', lw=1.5, label='Exact')
        axes[0].plot(hw_x, hw_y, 'r+', ms=8, label=f'Hardware ({len(hw_x)} steps)')
        if scipy_x is not None:
            axes[0].plot(scipy_x, scipy_y, 'gx', ms=6, alpha=0.6,
                         label=f'Scipy ({len(scipy_x)} steps)')
        axes[0].set_xlabel('x')
        axes[0].set_ylabel('y(x)')
        axes[0].set_title("RK45 Hardware vs Reference: dy/dx = -50(y-x)+1")
        axes[0].legend()
        axes[0].grid(True, alpha=0.3)

        # Error plot
        axes[1].semilogy(hw_x, abs_err + 1e-20, 'r.-', label='|y_hw - y_exact|')
        axes[1].semilogy(hw_x, np.abs(hw_err) + 1e-20, 'm.--', alpha=0.5,
                         label='HW error estimate')
        axes[1].set_xlabel('x')
        axes[1].set_ylabel('Error')
        axes[1].set_title('Hardware Step Errors')
        axes[1].legend()
        axes[1].grid(True, alpha=0.3)

        plt.tight_layout()
        plot_path = os.path.join(script_dir, "hw_comparison_plot.png")
        plt.savefig(plot_path, dpi=150)
        print(f"\nPlot saved: {plot_path}")
        plt.close()
    except ImportError:
        print("\n(matplotlib not installed — skipping plot)")

    sys.exit(0 if all_pass else 1)

if __name__ == "__main__":
    main()
