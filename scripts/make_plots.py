#!/usr/bin/env python3
"""
make_plots.py — Read CACTI sweep results and generate PNG plots into
/home/amrut/cache-run/plots/.

Reads outputs/all_results.csv produced by run_cacti_sweep.py.
"""

import os, sys
from pathlib import Path
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

CSV_PATH = Path("/home/amrut/cache-run/cacti/outputs/all_results.csv")
PLOT_DIR = Path("/home/amrut/cache-run/plots")
PLOT_DIR.mkdir(parents=True, exist_ok=True)

# CACTI column headers (note leading spaces in CSV)
COL = {
    "tech":   "Tech node (nm)",
    "cap":    "Capacity (bytes)",
    "banks":  "Number of banks",
    "assoc":  "Associativity",
    "obw":    "Output width (bits)",
    "tacc":   "Access time (ns)",
    "tcyc":   "Random cycle time (ns)",
    "esrch":  "Dynamic search energy (nJ)",
    "eread":  "Dynamic read energy (nJ)",
    "ewrite": "Dynamic write energy (nJ)",
    "leak":   "Standby leakage per bank(mW)",
    "area":   "Area (mm2)",
}

def to_num(s):
    try:
        return float(s)
    except (TypeError, ValueError):
        return float("nan")

def load():
    df = pd.read_csv(CSV_PATH)
    for k in COL.values():
        if k in df.columns:
            df[k] = df[k].apply(to_num)
    return df

def style():
    plt.rcParams.update({
        "figure.figsize":(8.0, 5.0),
        "figure.dpi":120,
        "axes.grid":True,
        "grid.alpha":0.3,
        "axes.titlesize":13,
        "axes.labelsize":11,
        "legend.fontsize":10,
        "font.family":"DejaVu Sans",
    })

# ----------------------------------------------------------------- plotters
def annotate_points(ax, xs, ys, fmt="{:.3g}"):
    for x, y in zip(xs, ys):
        ax.annotate(fmt.format(y), (x, y), textcoords="offset points",
                    xytext=(0, 6), ha="center", fontsize=8)

def plot_assoc(df):
    sub = df[df["_sweep"] == "assoc"].copy()
    sub["K"] = sub[COL["assoc"]].astype(int)
    sub = sub.sort_values("K")

    fig, axes = plt.subplots(1, 3, figsize=(15, 4.5))
    for ax, key, lbl, title in [
        (axes[0], COL["tacc"], "Access time (ns)", "Access time vs Associativity"),
        (axes[1], COL["eread"], "Read energy (nJ)", "Read energy vs Associativity"),
        (axes[2], COL["area"], "Area (mm²)", "Area vs Associativity"),
    ]:
        ax.plot(sub["K"], sub[key], marker="o", lw=2)
        ax.set_xlabel("Associativity (K)")
        ax.set_ylabel(lbl)
        ax.set_title(title)
        ax.set_xticks(sub["K"])
        annotate_points(ax, sub["K"], sub[key])
    fig.suptitle("Associativity sweep · 32 KB · 64 B line · 90 nm", y=1.02)
    fig.tight_layout()
    fig.savefig(PLOT_DIR / "01_assoc_sweep.png", bbox_inches="tight")
    plt.close(fig)

def plot_capacity(df):
    sub = df[df["_sweep"] == "capacity"].copy()
    sub["C_kB"] = sub[COL["cap"]].astype(int) // 1024
    sub = sub.sort_values("C_kB")

    fig, axes = plt.subplots(1, 3, figsize=(15, 4.5))
    for ax, key, lbl, title in [
        (axes[0], COL["tacc"], "Access time (ns)", "Access time vs Capacity"),
        (axes[1], COL["eread"], "Read energy (nJ)", "Read energy vs Capacity"),
        (axes[2], COL["area"], "Area (mm²)", "Area vs Capacity"),
    ]:
        ax.plot(sub["C_kB"], sub[key], marker="s", color="#d62728", lw=2)
        ax.set_xlabel("Capacity (KB)")
        ax.set_ylabel(lbl)
        ax.set_title(title)
        ax.set_xscale("log", base=2)
        ax.set_xticks(sub["C_kB"])
        ax.set_xticklabels([f"{x}" for x in sub["C_kB"]])
        annotate_points(ax, sub["C_kB"], sub[key])
    fig.suptitle("Capacity sweep · 4-way · 64 B line · 90 nm", y=1.02)
    fig.tight_layout()
    fig.savefig(PLOT_DIR / "02_capacity_sweep.png", bbox_inches="tight")
    plt.close(fig)

def plot_block(df):
    sub = df[df["_sweep"] == "block"].copy()
    # block size encoded only in the _variant tag, parse it
    sub["B"] = sub["_variant"].str.extract(r"_(\d+)$").astype(int)
    sub = sub.sort_values("B")

    fig, axes = plt.subplots(1, 3, figsize=(15, 4.5))
    for ax, key, lbl, title in [
        (axes[0], COL["tacc"], "Access time (ns)", "Access time vs Block size"),
        (axes[1], COL["eread"], "Read energy (nJ)", "Read energy vs Block size"),
        (axes[2], COL["area"], "Area (mm²)", "Area vs Block size"),
    ]:
        ax.plot(sub["B"], sub[key], marker="^", color="#2ca02c", lw=2)
        ax.set_xlabel("Block size (bytes)")
        ax.set_ylabel(lbl)
        ax.set_title(title)
        ax.set_xscale("log", base=2)
        ax.set_xticks(sub["B"])
        ax.set_xticklabels([str(b) for b in sub["B"]])
        annotate_points(ax, sub["B"], sub[key])
    fig.suptitle("Block size sweep · 32 KB · 4-way · 90 nm", y=1.02)
    fig.tight_layout()
    fig.savefig(PLOT_DIR / "03_block_sweep.png", bbox_inches="tight")
    plt.close(fig)

def plot_tech(df):
    sub = df[df["_sweep"] == "tech"].copy()
    sub["T_nm"] = sub[COL["tech"]].astype(int)
    sub = sub.sort_values("T_nm")

    fig, axes = plt.subplots(1, 3, figsize=(15, 4.5))
    for ax, key, lbl, title in [
        (axes[0], COL["tacc"], "Access time (ns)", "Access time vs Tech node"),
        (axes[1], COL["eread"], "Read energy (nJ)", "Read energy vs Tech node"),
        (axes[2], COL["area"], "Area (mm²)", "Area vs Tech node"),
    ]:
        ax.plot(sub["T_nm"], sub[key], marker="d", color="#9467bd", lw=2)
        ax.set_xlabel("Technology node (nm)")
        ax.set_ylabel(lbl)
        ax.set_title(title)
        ax.set_xticks(sub["T_nm"])
        annotate_points(ax, sub["T_nm"], sub[key])
    fig.suptitle("Technology node sweep · 32 KB · 4-way · 64 B line", y=1.02)
    fig.tight_layout()
    fig.savefig(PLOT_DIR / "04_tech_sweep.png", bbox_inches="tight")
    plt.close(fig)

def plot_ports(df):
    sub = df[df["_sweep"] == "ports"].copy()
    sub["P"] = sub["_variant"].str.extract(r"_(\d+)$").astype(int)
    sub = sub.sort_values("P")

    fig, axes = plt.subplots(1, 3, figsize=(15, 4.5))
    for ax, key, lbl, title in [
        (axes[0], COL["tacc"], "Access time (ns)", "Access time vs Ports"),
        (axes[1], COL["eread"], "Read energy (nJ)", "Read energy vs Ports"),
        (axes[2], COL["area"], "Area (mm²)", "Area vs Ports"),
    ]:
        ax.plot(sub["P"], sub[key], marker="P", color="#ff7f0e", lw=2)
        ax.set_xlabel("R/W ports")
        ax.set_ylabel(lbl)
        ax.set_title(title)
        ax.set_xticks(sub["P"])
        annotate_points(ax, sub["P"], sub[key])
    fig.suptitle("Port count sweep · 32 KB · 4-way · 64 B line · 90 nm", y=1.02)
    fig.tight_layout()
    fig.savefig(PLOT_DIR / "05_ports_sweep.png", bbox_inches="tight")
    plt.close(fig)

def plot_access_mode(df):
    sub = df[df["_sweep"] == "access_mode"].copy()
    sub["mode"] = sub["_variant"].str.replace('accessmodenormalsequentialfast_', '', regex=False)
    sub["mode"] = sub["mode"].str.replace('"', '', regex=False)
    order = ["normal", "fast", "sequential"]
    sub["order"] = sub["mode"].apply(lambda m: order.index(m) if m in order else 99)
    sub = sub.sort_values("order")

    fig, axes = plt.subplots(1, 3, figsize=(15, 4.5))
    colors = ["#1f77b4", "#d62728", "#2ca02c"]
    for ax, key, lbl, title in [
        (axes[0], COL["tacc"], "Access time (ns)", "Access time vs Access mode"),
        (axes[1], COL["eread"], "Read energy (nJ)", "Read energy vs Access mode"),
        (axes[2], COL["area"], "Area (mm²)", "Area vs Access mode"),
    ]:
        ax.bar(sub["mode"], sub[key], color=colors[:len(sub)], edgecolor="black")
        ax.set_xlabel("Tag/data access mode")
        ax.set_ylabel(lbl)
        ax.set_title(title)
        for x, y in zip(range(len(sub)), sub[key]):
            ax.annotate(f"{y:.3g}", (x, y), ha="center",
                        textcoords="offset points", xytext=(0, 4), fontsize=9)
    fig.suptitle("Access mode sweep · 32 KB · 4-way · 64 B line · 90 nm", y=1.02)
    fig.tight_layout()
    fig.savefig(PLOT_DIR / "06_access_mode_sweep.png", bbox_inches="tight")
    plt.close(fig)

def plot_combined(df):
    """One mega-plot summarising the headline metric (access time) across all sweeps."""
    fig, ax = plt.subplots(figsize=(11, 6))

    # Normalise each sweep to its variant index for plotting
    plotted = []
    for sweep, marker, color in [
        ("assoc", "o", "#1f77b4"),
        ("capacity", "s", "#d62728"),
        ("block", "^", "#2ca02c"),
        ("tech", "d", "#9467bd"),
        ("ports", "P", "#ff7f0e"),
    ]:
        s = df[df["_sweep"] == sweep].copy()
        # use the row order from the CSV (matches the sweep order)
        s = s.reset_index(drop=True)
        s["x"] = s.index
        ax.plot(s["x"], s[COL["tacc"]], marker=marker, color=color,
                label=sweep, lw=1.8, ms=8)

    ax.set_xlabel("Variant index within sweep")
    ax.set_ylabel("Access time (ns)")
    ax.set_title("Access time across all five sweeps  ·  90 nm baseline")
    ax.legend(loc="upper left")
    fig.tight_layout()
    fig.savefig(PLOT_DIR / "07_all_sweeps_overlay.png", bbox_inches="tight")
    plt.close(fig)

def plot_pareto_capacity_assoc(df):
    """Pareto-style: energy vs access time, points coloured by capacity & assoc."""
    fig, ax = plt.subplots(figsize=(9, 6))

    for sweep, marker in [("capacity", "s"), ("assoc", "o")]:
        s = df[df["_sweep"] == sweep].copy()
        ax.scatter(s[COL["tacc"]], s[COL["eread"]],
                   s=80, marker=marker, label=sweep, edgecolor="black")
        # Annotate
        for _, r in s.iterrows():
            label = (f"{int(r[COL['cap']]//1024)}KB"
                     if sweep == "capacity"
                     else f"K={int(r[COL['assoc']])}")
            ax.annotate(label, (r[COL["tacc"]], r[COL["eread"]]),
                        textcoords="offset points", xytext=(6, 4),
                        fontsize=8)

    ax.set_xlabel("Access time (ns)")
    ax.set_ylabel("Read energy (nJ)")
    ax.set_title("Energy vs Access time — Pareto view")
    ax.legend()
    fig.tight_layout()
    fig.savefig(PLOT_DIR / "08_energy_vs_latency_pareto.png", bbox_inches="tight")
    plt.close(fig)

def main():
    if not CSV_PATH.exists():
        print(f"Missing {CSV_PATH}.  Run run_cacti_sweep.py first.")
        return 1
    df = load()
    style()
    print(f"Loaded {len(df)} records")
    plot_assoc(df)
    plot_capacity(df)
    plot_block(df)
    plot_tech(df)
    plot_ports(df)
    plot_access_mode(df)
    plot_combined(df)
    plot_pareto_capacity_assoc(df)
    print(f"Wrote PNGs to {PLOT_DIR}")
    for p in sorted(PLOT_DIR.glob("*.png")):
        print(f"  {p.name}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
