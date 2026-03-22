#!/usr/bin/env python3
import csv
import glob
import json
import math
import statistics
import sys
from pathlib import Path


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


def parse_latency(value):
    if value in ("", None):
        return None
    return float(value)


def parse_risk_window_ms(row):
    explicit = row.get("risk_window_ms")
    if explicit not in ("", None):
        return float(explicit)
    revoke_ns = row.get("revoke_sent_ns")
    termination_ns = row.get("termination_ns")
    if revoke_ns in ("", None):
        return None
    if termination_ns not in ("", None):
        return (int(termination_ns) - int(revoke_ns)) / 1_000_000
    observe_ms = row.get("observe_after_revoke_ms")
    if observe_ms not in ("", None):
        return float(observe_ms)
    return None


def parse_profile(path):
    stem = Path(path).stem
    for suffix in ("-low", "-medium", "-high"):
        if stem.endswith(suffix):
            return suffix[1:]
    return "unknown"


def summarize_file(path):
    with open(path, newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    if not rows:
        return None

    latencies = [value for value in (parse_latency(row["latency_to_enforce_ms"]) for row in rows) if value is not None]
    risk_windows_ms = [value for value in (parse_risk_window_ms(row) for row in rows) if value is not None]
    risk_windows = [int(row["risk_window_messages"]) for row in rows]
    deny_values = [int(row["post_revoke_deny"]) for row in rows]
    running_values = [int(row.get("still_running_after_observe", "0") or "0") for row in rows]
    censored_values = [int(row.get("risk_window_ms_censored", row.get("still_running_after_observe", "0")) or "0") for row in rows]

    first = rows[0]
    return {
        "mode": first["mode"],
        "profile": parse_profile(path),
        "count": len(rows),
        "termination_observed_count": len(latencies),
        "still_running_after_observe_rate": sum(running_values) / len(running_values),
        "risk_window_ms_censored_rate": sum(censored_values) / len(censored_values),
        "post_revoke_deny_rate": sum(deny_values) / len(deny_values),
        "risk_window_ms_mean": statistics.mean(risk_windows_ms) if risk_windows_ms else None,
        "risk_window_ms_p95": percentile(risk_windows_ms, 0.95),
        "risk_window_ms_p99": percentile(risk_windows_ms, 0.99),
        "risk_window_ms_ci95": ci95(risk_windows_ms) if risk_windows_ms else None,
        "risk_window_messages_mean": statistics.mean(risk_windows),
        "risk_window_messages_p95": percentile(risk_windows, 0.95),
        "latency_to_enforce_ms_p50": percentile(latencies, 0.50),
        "latency_to_enforce_ms_p95": percentile(latencies, 0.95),
        "latency_to_enforce_ms_p99": percentile(latencies, 0.99),
        "latency_to_enforce_ms_mean": statistics.mean(latencies) if latencies else None,
        "latency_to_enforce_ms_ci95": ci95(latencies) if latencies else None,
        "source_file": str(Path(path)),
    }


def main(argv):
    if len(argv) < 2:
        print("usage: summarize_matrix.py <glob-or-csv> [<glob-or-csv> ...]", file=sys.stderr)
        return 1

    paths = []
    for pattern in argv[1:]:
        matches = sorted(glob.glob(pattern))
        if matches:
            paths.extend(matches)
        elif Path(pattern).is_file():
            paths.append(pattern)

    seen = set()
    summaries = []
    for path in paths:
        if path in seen:
            continue
        seen.add(path)
        summary = summarize_file(path)
        if summary is not None:
            summaries.append(summary)

    json.dump(sorted(summaries, key=lambda x: (x["mode"], x["profile"])), sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
