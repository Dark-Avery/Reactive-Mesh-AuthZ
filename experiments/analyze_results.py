#!/usr/bin/env python3
import csv
import json
import math
import statistics
import sys
from collections import defaultdict


def percentile(values, pct):
    if not values:
        return None
    xs = sorted(values)
    if len(xs) == 1:
        return xs[0]
    pos = (len(xs) - 1) * pct
    lo = math.floor(pos)
    hi = math.ceil(pos)
    if lo == hi:
        return xs[lo]
    return xs[lo] + (xs[hi] - xs[lo]) * (pos - lo)


def ci95(values):
    if len(values) < 2:
        return None
    mean = statistics.mean(values)
    stdev = statistics.stdev(values)
    margin = 1.96 * stdev / math.sqrt(len(values))
    return [mean - margin, mean + margin]


def main(path):
    grouped = defaultdict(list)
    with open(path, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            grouped[row["mode"]].append(float(row["latency_to_enforce_ms"]))

    summary = {}
    for mode, values in grouped.items():
        summary[mode] = {
            "count": len(values),
            "p50_ms": percentile(values, 0.50),
            "p95_ms": percentile(values, 0.95),
            "p99_ms": percentile(values, 0.99),
            "mean_ms": statistics.mean(values),
            "ci95_ms": ci95(values),
        }

    json.dump(summary, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: analyze_results.py <csv>", file=sys.stderr)
        sys.exit(1)
    main(sys.argv[1])
