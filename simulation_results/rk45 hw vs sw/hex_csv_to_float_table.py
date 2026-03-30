import csv
import struct
import sys
from pathlib import Path


def hex32_to_float(hex_text: str) -> float:
    """Convert xsim hex string to float32. Returns NaN for uninitialised (U/X/Z) values."""
    s = (hex_text or "").strip().lower()
    if not s:
        return float("nan")

    # Handle common xsim forms: 3f800000, 32'h3f800000, 0x3f800000
    if "'h" in s:
        s = s.split("'h", 1)[1]
    if s.startswith("0x"):
        s = s[2:]

    s = s.replace("_", "")
    s = s.zfill(8)[-8:]

    # xsim uninitialized/unknown: any U, X, Z, ? → NaN
    if any(c in s for c in "uxz?"):
        return float("nan")

    try:
        return struct.unpack("!f", bytes.fromhex(s))[0]
    except ValueError:
        return float("nan")


def is_valid_row(row: dict) -> bool:
    """Keep only committed accepted-step rows with settled signal values."""
    # Must be an accepted, committed update (mem_init=1 AND accepted=1)
    if row.get("mem_init", "").strip() != "1":
        return False
    if row.get("accepted", "").strip() != "1":
        return False
    # Skip rows with uninitialised hex values in x_hex or y_hex
    for col in ("x_hex", "y_hex"):
        val = (row.get(col) or "").lower()
        if any(c in val for c in "uxz?"):
            return False
    # Skip rows where x or y is exactly zero (pre-init garbage)
    try:
        x = struct.unpack("!f", bytes.fromhex(row.get("x_hex", "00000000").zfill(8)[-8:]))[0]
        y = struct.unpack("!f", bytes.fromhex(row.get("y_hex", "00000000").zfill(8)[-8:]))[0]
        if x == 0.0 or y == 0.0:
            return False
    except ValueError:
        return False
    return True


def convert_file(input_csv: Path, output_csv: Path) -> None:
    with input_csv.open("r", newline="") as f_in, output_csv.open("w", newline="") as f_out:
        reader = csv.DictReader(f_in)
        fieldnames = list(reader.fieldnames or [])

        extra = ["x", "y", "err", "h", "time_ns"]
        writer = csv.DictWriter(f_out, fieldnames=fieldnames + extra)
        writer.writeheader()

        kept = 0
        for row in reader:
            if not is_valid_row(row):
                continue

            row["x"]       = hex32_to_float(row.get("x_hex", ""))
            row["y"]       = hex32_to_float(row.get("y_hex", ""))
            row["err"]     = hex32_to_float(row.get("err_hex", ""))
            row["h"]       = hex32_to_float(row.get("h_hex", ""))
            # Normalise time_ps column (may contain "10 ns" or "10000 ps")
            t_raw = (row.get("time_ps") or "").strip().lower().replace(" ", "")
            if t_raw.endswith("ns"):
                row["time_ns"] = float(t_raw[:-2])
            elif t_raw.endswith("ps"):
                row["time_ns"] = float(t_raw[:-2]) / 1000.0
            else:
                try:
                    row["time_ns"] = float(t_raw) / 1000.0
                except ValueError:
                    row["time_ns"] = float("nan")

            writer.writerow(row)
            kept += 1

    print(f"  Kept {kept} rows (filtered out uninitialised/zero-x rows)")


if __name__ == "__main__":
    root = Path(__file__).resolve().parent
    default_in = root / "xsim" / "rk45_hw_hex.csv"
    alt_in = root.parent / "RK45" / "RK45.sim" / "sim_1" / "behav" / "xsim" / "rk45_hw_hex.csv"

    if len(sys.argv) >= 2:
        inp = Path(sys.argv[1]).resolve()
    elif default_in.exists():
        inp = default_in
    else:
        inp = alt_in

    if len(sys.argv) >= 3:
        out = Path(sys.argv[2]).resolve()
    else:
        out = root / "rk45_hw_float.csv"

    if not inp.exists():
        raise SystemExit(f"Input file not found: {inp}")

    convert_file(inp, out)
    print(f"Wrote: {out}")
