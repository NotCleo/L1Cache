#!/usr/bin/env python3
"""
run_cacti_sweep.py — Drive CACTI 7 across sweeps of capacity, associativity,
block size, technology node, and read/write port count.

Reads /home/amrut/Downloads/cacti/cache.cfg as a template, edits parameter
lines, invokes ./cacti -infile <generated.cfg> from inside the cacti dir,
and parses the .cfg.out CSV line.

Outputs:
  cache-run/cacti/outputs/<sweep>/<config>.cfg
  cache-run/cacti/outputs/<sweep>/<config>.cfg.out
  cache-run/cacti/outputs/<sweep>/results.csv
"""

import os, re, sys, shutil, subprocess, time
from pathlib import Path

CACTI_DIR = Path("/home/amrut/Downloads/cacti")
CACTI_BIN = CACTI_DIR / "cacti"
TEMPLATE  = CACTI_DIR / "cache.cfg"
OUT_ROOT  = Path("/home/amrut/cache-run/cacti/outputs")
CFG_DIR   = Path("/home/amrut/cache-run/cacti/configs")

OUT_ROOT.mkdir(parents=True, exist_ok=True)
CFG_DIR.mkdir(parents=True, exist_ok=True)

# ------------------------------------------------------------ helpers
def load_template() -> str:
    return TEMPLATE.read_text()

def set_param(cfg: str, key: str, value: str) -> str:
    """Replace the first uncommented line beginning with `key` with the
    user-supplied value.  All variants of the same key (commented or not)
    are commented-out, then the new line is appended at the end."""
    lines = cfg.splitlines()
    out = []
    pattern = re.compile(rf"^\s*//?\s*{re.escape(key)}")
    for ln in lines:
        if pattern.match(ln):
            if not ln.lstrip().startswith("//"):
                out.append("//" + ln)
            else:
                out.append(ln)
        else:
            out.append(ln)
    out.append(f"{key} {value}")
    return "\n".join(out) + "\n"

def run_one(cfg_path: Path) -> Path:
    """Run CACTI on a config and return the .cfg.out path."""
    out = cfg_path.with_suffix(".cfg.out")
    # CACTI writes the .cfg.out file next to the .cfg input
    proc = subprocess.run(
        [str(CACTI_BIN), "-infile", str(cfg_path)],
        cwd=str(CACTI_DIR),
        capture_output=True, text=True, timeout=120
    )
    if proc.returncode != 0:
        print(f"  ! CACTI exit {proc.returncode} on {cfg_path.name}")
        print(proc.stderr[-200:])
    return out

# CACTI writes the CSV-style output to current dir as
# <cfg_basename>.cfg.out — we invoke with absolute path; CACTI strips path
# and writes to cwd by default.  We'll handle both possibilities.

def find_output(cfg_path: Path) -> Path | None:
    candidates = [
        cfg_path.with_suffix(".cfg.out"),
        CACTI_DIR / (cfg_path.stem + ".cfg.out"),
        Path.cwd() / (cfg_path.stem + ".cfg.out"),
    ]
    for c in candidates:
        if c.exists():
            return c
    return None

def parse_csv(path: Path) -> dict | None:
    """Return a dict from the first data line of the CACTI .cfg.out file."""
    try:
        txt = path.read_text()
    except FileNotFoundError:
        return None
    lines = [l for l in txt.splitlines() if l.strip()]
    if len(lines) < 2:
        return None
    header = [h.strip() for h in lines[0].rstrip(",").split(",")]
    data   = [d.strip() for d in lines[1].rstrip(",").split(",")]
    if len(data) < len(header):
        return None
    rec = dict(zip(header, data))
    return rec

# ------------------------------------------------------------ sweeps
BASE_KNOBS = {
    "-size (bytes)": 32768,
    "-block size (bytes)": 64,
    "-associativity": 4,
    "-technology (u)": 0.090,
    "-read-write port": 1,
    "-exclusive read port": 0,
    "-exclusive write port": 0,
    "-cache type": '"cache"',
    "-tag size (b)": '"default"',
    "-access mode (normal, sequential, fast) -": '"normal"',
    "-output/input bus width": 64,
    "-UCA bank count": 1,
    "-operating temperature (K)": 360,
}

def apply_knobs(cfg, knobs):
    for k, v in knobs.items():
        cfg = set_param(cfg, k, str(v))
    return cfg

SWEEPS = {
    # 1) Associativity sweep at 32 KB / 64 B
    "assoc": [
        {"-associativity": k}
        for k in [1, 2, 4, 8, 16]
    ],
    # 2) Capacity sweep at K=4 / 64 B
    "capacity": [
        {"-size (bytes)": c}
        for c in [16384, 32768, 65536, 131072, 262144, 524288, 1048576]
    ],
    # 3) Block size sweep at C=32 KB / K=4
    "block": [
        {"-block size (bytes)": b}
        for b in [16, 32, 64, 128]
    ],
    # 4) Tech node sweep at C=32 KB / K=4 / B=64
    "tech": [
        {"-technology (u)": t}
        for t in [0.022, 0.032, 0.045, 0.065, 0.090]
    ],
    # 5) R/W ports sweep
    "ports": [
        {"-read-write port": p}
        for p in [1, 2, 3, 4]
    ],
    # 6) Access mode sweep
    "access_mode": [
        {"-access mode (normal, sequential, fast) -": f'"{m}"'}
        for m in ["normal", "fast", "sequential"]
    ],
}

# ------------------------------------------------------------ main
def main():
    template = load_template()
    all_records = []

    for sweep_name, variants in SWEEPS.items():
        sweep_dir = OUT_ROOT / sweep_name
        sweep_dir.mkdir(parents=True, exist_ok=True)
        cfg_subdir = CFG_DIR / sweep_name
        cfg_subdir.mkdir(parents=True, exist_ok=True)

        print(f"\n=== sweep: {sweep_name} ===")
        for idx, override in enumerate(variants):
            knobs = dict(BASE_KNOBS)
            knobs.update(override)

            tag = "_".join(f"{re.sub(r'[^a-zA-Z0-9]', '', k)}_{v}"
                           for k, v in override.items())
            cfg_name = f"{sweep_name}_{idx:02d}_{tag}.cfg"
            cfg_path = cfg_subdir / cfg_name

            cfg_text = apply_knobs(template, knobs)
            cfg_path.write_text(cfg_text)

            t0 = time.time()
            run_one(cfg_path)
            dt = time.time() - t0

            out_path = find_output(cfg_path)
            rec = parse_csv(out_path) if out_path else None
            if rec is None:
                print(f"  [{idx:02d}] {tag:60s}  FAILED")
                continue

            rec["_sweep"]   = sweep_name
            rec["_variant"] = tag
            rec["_runtime"] = f"{dt:.2f}"
            all_records.append(rec)

            # Move the .cfg.out next to the .cfg in our sweep dir
            if out_path != cfg_path.with_suffix(".cfg.out"):
                shutil.move(str(out_path), str(cfg_path.with_suffix(".cfg.out")))

            # also keep a copy in outputs/<sweep>/
            shutil.copy2(cfg_path.with_suffix(".cfg.out"),
                         sweep_dir / cfg_path.with_suffix(".cfg.out").name)

            access  = rec.get("Access time (ns)",  "?")
            energy  = rec.get(" Dynamic read energy (nJ)", rec.get("Dynamic read energy (nJ)", "?"))
            area    = rec.get(" Area (mm2)", rec.get("Area (mm2)", "?"))
            print(f"  [{idx:02d}] {tag:60s}  acc={access}ns  E={energy}nJ  A={area}mm²  ({dt:.1f}s)")

    # Write the consolidated CSV
    if not all_records:
        print("\nNo records collected.")
        return 1

    import csv
    csv_path = OUT_ROOT / "all_results.csv"
    keys = sorted({k for r in all_records for k in r.keys()})
    with csv_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=keys)
        w.writeheader()
        for r in all_records:
            w.writerow(r)
    print(f"\nWrote {len(all_records)} records to {csv_path}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
