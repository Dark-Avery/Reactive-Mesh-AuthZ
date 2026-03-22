#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

import matplotlib.pyplot as plt


MODE_ORDER = ["reactive", "baseline-ext_authz", "baseline-push", "baseline-poll"]
MODE_LABELS = {
    "reactive": "Reactive",
    "baseline-ext_authz": "OPA + Envoy ext_authz",
    "baseline-push": "Push baseline (internal)",
    "baseline-poll": "Poll baseline (internal)",
}


def parse_args():
    p = argparse.ArgumentParser(description="Plot first-deny-after-revoke latency summary")
    p.add_argument("--summary", required=True)
    p.add_argument("--output", default="experiments/results/plots/deny_latency_by_mode.png")
    return p.parse_args()


def main():
    args = parse_args()
    rows = json.loads(Path(args.summary).read_text(encoding="utf-8"))
    indexed = {row["mode"]: row for row in rows}
    modes = [mode for mode in MODE_ORDER if mode in indexed]
    labels = [MODE_LABELS.get(mode, mode) for mode in modes]
    values = [indexed[mode]["first_deny_after_revoke_ms_mean"] for mode in modes]

    plt.figure(figsize=(8, 5))
    bars = plt.bar(labels, values)
    for bar, value in zip(bars, values):
        plt.text(bar.get_x() + bar.get_width() / 2.0, value, f"{value:.1f}", ha="center", va="bottom", fontsize=9)
    plt.ylabel("Mean first deny after revoke (ms)")
    plt.title("Control-Plane Revoke Propagation for New Streams")
    plt.grid(True, axis="y", alpha=0.3)
    plt.xticks(rotation=12, ha="right")
    plt.tight_layout()

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    plt.savefig(out, dpi=150)
    plt.close()
    print(out)


if __name__ == "__main__":
    main()
