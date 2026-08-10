#!/usr/bin/env python3
"""
analyze-results.py — per-sensor and per-condition range-test statistics

Reads one or more CSVs produced by `thread-range-test sample` and
emits a summary table with, per (condition, sensor):

    n samples, mean RSSI, median RSSI, stddev, min, max, mean LQI

If a label-mapping CSV is provided (typically produced by
`map-ha-devices.py`), the ext_mac is replaced by the user-friendly HA
label. Otherwise the ext_mac is shown as-is.

Usage:
    analyze-results.py [--map LABEL_CSV] [--ext_mac MAC] CSV [CSV ...]

    --map     CSV with at least 'label' and 'ext_mac' columns. Used to
              translate the 16-hex ext_mac into a human-readable name.
    --ext_mac filter to a single sensor. Useful when a condition was
              targeted at one specific device (e.g. sensor orientation).

Each input CSV is treated as its own condition; the condition name is taken
from the filename (stripping the `range_` prefix and `.csv` suffix).

Output: a fixed-width table on stdout, sorted by condition then by mean
RSSI (descending — strongest first).

Examples:

    # Quick per-sensor stats from a single 12 h soak
    analyze-results.py range_overnight_tx3.csv

    # Compare 4 orientation conditions, named by HA label, single sensor
    analyze-results.py --map labels.csv --ext_mac 563784e9bea2ed1b \\
               range_phase4_5202_orientA.csv \\
               range_phase4_5202_orientB.csv \\
               range_phase4_5202_orientC1.csv \\
               range_phase4_5202_orientC2.csv

This is a pure-stdlib script; no extra dependencies. Designed to run
on a developer machine, not on the gateway.
"""

import argparse
import csv
import math
import os
import statistics
import sys
from collections import defaultdict


def parse_args():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--map", dest="map_csv",
                   help="CSV mapping ext_mac to a human label.")
    p.add_argument("--ext_mac",
                   help="Filter to this single ext_mac (lowercase 16-hex).")
    p.add_argument("csvs", nargs="+", help="thread-range-test CSV files")
    return p.parse_args()


def load_label_map(path):
    if not path:
        return {}
    out = {}
    with open(path, newline="") as f:
        rdr = csv.DictReader(f)
        for row in rdr:
            ext = (row.get("ext_mac") or "").strip().lower()
            label = (row.get("label") or "").strip()
            if ext and label:
                out[ext] = label
    return out


def condition_from_filename(path):
    base = os.path.basename(path)
    if base.startswith("range_"):
        base = base[len("range_"):]
    if base.endswith(".csv"):
        base = base[:-len(".csv")]
    return base


def read_condition(path, ext_filter=None):
    """Return dict ext_mac -> list of (rssi, lq)."""
    out = defaultdict(list)
    with open(path) as f:
        for line in f:
            if line.startswith("#") or line.startswith("ts,"):
                continue
            parts = line.rstrip("\n").split(",")
            if len(parts) < 9:
                continue
            ext = parts[8].strip().lower()
            if ext_filter and ext != ext_filter:
                continue
            try:
                rssi = int(parts[5])
                lq = int(parts[7])
            except (ValueError, IndexError):
                continue
            out[ext].append((rssi, lq))
    return out


def stats(rows):
    rssi = [r for r, _ in rows]
    lq = [q for _, q in rows]
    n = len(rssi)
    if n == 0:
        return None
    mean = sum(rssi) / n
    sd = math.sqrt(sum((x - mean) ** 2 for x in rssi) / n) if n > 1 else 0.0
    median = statistics.median(rssi)
    return {
        "n": n,
        "mean": mean,
        "median": median,
        "stddev": sd,
        "min": min(rssi),
        "max": max(rssi),
        "mean_lq": sum(lq) / n,
    }


def main():
    args = parse_args()
    label_map = load_label_map(args.map_csv)
    ext_filter = args.ext_mac.strip().lower() if args.ext_mac else None

    rows = []
    for path in args.csvs:
        condition = condition_from_filename(path)
        per_ext = read_condition(path, ext_filter)
        for ext, samples in per_ext.items():
            s = stats(samples)
            if not s:
                continue
            label = label_map.get(ext, ext[:16])
            rows.append({"condition": condition, "label": label, "ext_mac": ext, **s})

    rows.sort(key=lambda r: (r["condition"], -r["mean"]))

    print(f"{'condition':<28} {'label':<24} {'n':>3} {'mean':>6} {'med':>5} "
          f"{'stddev':>6} {'min':>5} {'max':>5} {'lq':>5}")
    for r in rows:
        print(f"{r['condition']:<28} {r['label']:<24} "
              f"{r['n']:>3} {r['mean']:>6.2f} {r['median']:>5.0f} "
              f"{r['stddev']:>6.2f} {r['min']:>5d} {r['max']:>5d} "
              f"{r['mean_lq']:>5.2f}")


if __name__ == "__main__":
    main()
