#!/usr/bin/env python3
import argparse
import csv
import json
import statistics
from pathlib import Path


def parse_args():
    p = argparse.ArgumentParser(description="Summarize first-deny-after-revoke latency datasets")
    p.add_argument("csvs", nargs="+")
    p.add_argument("--output", default="experiments/results/deny-latency/summary.json")
    return p.parse_args()


def percentile(values, q):
    if not values:
        return None
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    pos = (len(ordered) - 1) * q
    lo = int(pos)
    hi = min(lo + 1, len(ordered) - 1)
    frac = pos - lo
    return ordered[lo] * (1 - frac) + ordered[hi] * frac


def summarize_file(path):
    with open(path, newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    latencies = [float(row["first_deny_after_revoke_ms"]) for row in rows if row["first_deny_after_revoke_ms"]]
    return {
        "mode": Path(path).stem,
        "rows": len(rows),
        "first_deny_count": len(latencies),
        "first_deny_after_revoke_ms_mean": statistics.mean(latencies) if latencies else None,
        "first_deny_after_revoke_ms_p50": percentile(latencies, 0.50),
        "first_deny_after_revoke_ms_p95": percentile(latencies, 0.95),
        "first_deny_after_revoke_ms_p99": percentile(latencies, 0.99),
        "active_stream_alive_after_probe_rate": statistics.mean(
            int(row["active_stream_alive_after_probe"]) for row in rows
        ) if rows else None,
    }


def main():
    args = parse_args()
    summary = [summarize_file(path) for path in args.csvs]
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(out)


if __name__ == "__main__":
    main()
