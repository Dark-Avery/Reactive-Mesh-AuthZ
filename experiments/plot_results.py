#!/usr/bin/env python3
import argparse
import csv
from collections import defaultdict
from pathlib import Path

import matplotlib.pyplot as plt


def parse_args():
    p = argparse.ArgumentParser(description="Plot Reactive Mesh AuthZ experiment results")
    p.add_argument("csv", help="Input CSV produced by run_benchmark.py")
    p.add_argument("--outdir", default="experiments/results/plots", help="Directory for generated plots")
    return p.parse_args()


def load_rows(path):
    grouped = defaultdict(list)
    with open(path, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            grouped[row["mode"]].append(float(row["latency_to_enforce_ms"]))
    return grouped


def plot_ecdf(grouped, outdir):
    plt.figure(figsize=(8, 5))
    for mode, values in sorted(grouped.items()):
        xs = sorted(values)
        ys = [(i + 1) / len(xs) for i in range(len(xs))]
        plt.step(xs, ys, where="post", label=mode)
    plt.xlabel("Latency To Enforce (ms)")
    plt.ylabel("ECDF")
    plt.title("Reactive Mesh AuthZ ECDF")
    plt.grid(True, alpha=0.3)
    plt.legend()
    plt.tight_layout()
    plt.savefig(outdir / "latency_ecdf.png", dpi=150)
    plt.close()


def plot_boxplot(grouped, outdir):
    labels = list(sorted(grouped.keys()))
    data = [grouped[label] for label in labels]
    plt.figure(figsize=(8, 5))
    plt.boxplot(data, labels=labels, showfliers=True)
    plt.ylabel("Latency To Enforce (ms)")
    plt.title("Reactive Mesh AuthZ Latency Boxplot")
    plt.grid(True, axis="y", alpha=0.3)
    plt.tight_layout()
    plt.savefig(outdir / "latency_boxplot.png", dpi=150)
    plt.close()


def main():
    args = parse_args()
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    grouped = load_rows(args.csv)
    if not grouped:
      raise SystemExit("no rows loaded")
    plot_ecdf(grouped, outdir)
    plot_boxplot(grouped, outdir)
    print(outdir)


if __name__ == "__main__":
    main()
