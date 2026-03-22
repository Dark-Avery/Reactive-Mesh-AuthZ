#!/usr/bin/env python3
import argparse
import csv
import json
from pathlib import Path

import matplotlib.pyplot as plt


OSS_REQUEST_TIME_MODES = ["baseline-ext_authz", "baseline-istio-custom", "baseline-openfga"]
PROFILE_ORDER = ["low", "medium", "high"]
MODE_LABELS = {
    "reactive": "Reactive",
    "baseline-ext_authz": "OPA + Envoy",
    "baseline-istio-custom": "Istio CUSTOM",
    "baseline-openfga": "OpenFGA",
    "baseline-spicedb": "SpiceDB",
    "baseline-poll": "Локальная poll-абляция",
    "baseline-push": "Локальная push-абляция",
}


def parse_args():
    p = argparse.ArgumentParser(description="Построить основные графики по матрице экспериментов Reactive Mesh AuthZ")
    p.add_argument("--summary", required=True, help="JSON со сводкой по матрице экспериментов")
    p.add_argument(
        "--reactive-csvs",
        nargs="*",
        default=[],
        help="CSV-файлы реактивного режима для графика по задержке применения",
    )
    p.add_argument("--outdir", default="experiments/results/plots", help="Каталог для сохраняемых графиков")
    return p.parse_args()


def load_summary(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def display_label(mode):
    return MODE_LABELS.get(mode, mode)


def plot_oss_comparator_risk_window(summary, outdir):
    profiles = PROFILE_ORDER
    profile_to_rows = {(row["mode"], row["profile"]): row for row in summary}

    if not all(("reactive", profile) in profile_to_rows for profile in profiles):
        return

    family_series = {
        "Reactive": [profile_to_rows[("reactive", profile)]["risk_window_messages_mean"] for profile in profiles],
        "OPA + Envoy": [],
        "Istio CUSTOM": [],
        "OpenFGA": [],
    }
    for profile in profiles:
        if ("baseline-ext_authz", profile) in profile_to_rows:
            family_series["OPA + Envoy"].append(profile_to_rows[("baseline-ext_authz", profile)]["risk_window_messages_mean"])
        if ("baseline-istio-custom", profile) in profile_to_rows:
            family_series["Istio CUSTOM"].append(profile_to_rows[("baseline-istio-custom", profile)]["risk_window_messages_mean"])
        if ("baseline-openfga", profile) in profile_to_rows:
            family_series["OpenFGA"].append(profile_to_rows[("baseline-openfga", profile)]["risk_window_messages_mean"])
    modes = [label for label, values in family_series.items() if len(values) == len(profiles) and all(value is not None for value in values)]
    if not modes:
        return

    width = 0.8 / len(modes)
    x = list(range(len(profiles)))
    plt.figure(figsize=(9, 5))
    for offset_idx, mode in enumerate(modes):
        ys = family_series[mode]
        center_shift = offset_idx - (len(modes) - 1) / 2.0
        xs = [value + center_shift * width for value in x]
        plt.bar(xs, ys, width=width, label=mode)
    plt.xticks(x, profiles)
    plt.ylabel("Среднее окно риска, сообщений")
    plt.title("Reactive против OSS comparator-архитектур")
    plt.grid(True, axis="y", alpha=0.3)
    plt.legend()
    plt.tight_layout()
    plt.savefig(outdir / "oss_risk_window_by_profile.png", dpi=150)
    plt.close()


def plot_oss_comparator_gap(summary, outdir):
    profile_to_rows = {(row["mode"], row["profile"]): row for row in summary}
    profiles = PROFILE_ORDER
    if not all(("reactive", profile) in profile_to_rows for profile in profiles):
        return

    family_series = {
        "OPA + Envoy": [],
        "Istio CUSTOM": [],
        "OpenFGA": [],
    }
    for profile in profiles:
        reactive = profile_to_rows[("reactive", profile)]["risk_window_messages_mean"]
        opa = profile_to_rows.get(("baseline-ext_authz", profile))
        if opa is not None:
            family_series["OPA + Envoy"].append(opa["risk_window_messages_mean"] - reactive)
        istio = profile_to_rows.get(("baseline-istio-custom", profile))
        if istio is not None:
            family_series["Istio CUSTOM"].append(istio["risk_window_messages_mean"] - reactive)
        openfga = profile_to_rows.get(("baseline-openfga", profile))
        if openfga is not None:
            family_series["OpenFGA"].append(
                openfga["risk_window_messages_mean"] - reactive
            )

    modes = [label for label, values in family_series.items() if len(values) == len(profiles)]
    if not modes:
        return

    width = 0.8 / len(modes)
    x = list(range(len(profiles)))
    plt.figure(figsize=(9, 5))
    for offset_idx, mode in enumerate(modes):
        ys = family_series[mode]
        center_shift = offset_idx - (len(modes) - 1) / 2.0
        xs = [value + center_shift * width for value in x]
        plt.bar(xs, ys, width=width, label=mode)
    plt.xticks(x, profiles)
    plt.ylabel("Прирост окна риска относительно Reactive, сообщений")
    plt.title("Насколько OSS comparator'ы уступают Reactive")
    plt.grid(True, axis="y", alpha=0.3)
    plt.legend()
    plt.tight_layout()
    plt.savefig(outdir / "oss_gap_vs_reactive.png", dpi=150)
    plt.close()


def plot_reactive_latency_boxplot(summary, outdir):
    profile_to_rows = {(row["mode"], row["profile"]): row for row in summary}
    profiles = [profile for profile in PROFILE_ORDER if ("reactive", profile) in profile_to_rows]
    if not profiles:
        return

    p50 = [profile_to_rows[("reactive", profile)]["latency_to_enforce_ms_p50"] for profile in profiles]
    p95 = [profile_to_rows[("reactive", profile)]["latency_to_enforce_ms_p95"] for profile in profiles]
    x = list(range(len(profiles)))
    width = 0.35

    plt.figure(figsize=(8, 5))
    p50_bars = plt.bar([value - width / 2 for value in x], p50, width=width, label="p50")
    p95_bars = plt.bar([value + width / 2 for value in x], p95, width=width, label="p95")
    plt.xticks(x, profiles)
    plt.ylabel("Задержка применения, мс")
    plt.title("Reactive: p50 и p95 задержки применения")
    plt.grid(True, axis="y", alpha=0.3)
    for bars in (p50_bars, p95_bars):
        for bar in bars:
            value = bar.get_height()
            plt.text(
                bar.get_x() + bar.get_width() / 2,
                value + 0.4,
                f"{value:.1f}",
                ha="center",
                va="bottom",
                fontsize=8,
            )
    plt.legend()
    plt.tight_layout()
    plt.savefig(outdir / "reactive_latency_by_profile.png", dpi=150)
    plt.close()


def main():
    args = parse_args()
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    summary = load_summary(args.summary)
    plot_oss_comparator_risk_window(summary, outdir)
    plot_oss_comparator_gap(summary, outdir)
    plot_reactive_latency_boxplot(summary, outdir)
    print(outdir)


if __name__ == "__main__":
    main()
