#!/usr/bin/env python3
import argparse
import csv
import json
import math
import random
import statistics
from collections import defaultdict
from pathlib import Path

KNOWN_PROFILES = {"low", "medium", "high"}
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


def parse_args():
    parser = argparse.ArgumentParser(description="Собрать агрегированный отчёт по матрице экспериментов Reactive Mesh AuthZ")
    parser.add_argument("csvs", nargs="+", help="CSV-файлы, полученные после запусков bench/load-client/run_benchmark.py")
    parser.add_argument("--json-out", required=True, help="Путь для итогового JSON-отчёта")
    parser.add_argument("--md-out", required=True, help="Путь для итогового Markdown-отчёта")
    parser.add_argument("--bootstrap-samples", type=int, default=2000, help="Число bootstrap-выборок для каждого сравнения")
    return parser.parse_args()


def load_rows(paths):
    rows = []
    for path in paths:
      with open(path, newline="", encoding="utf-8") as fh:
          for row in csv.DictReader(fh):
              row["_source"] = path
              rows.append(row)
    return rows


def parse_float(value):
    if value in (None, ""):
        return None
    return float(value)


def bootstrap_mean_diff(a, b, samples):
    if not a or not b:
        return None
    rng = random.Random(42)
    diffs = []
    for _ in range(samples):
        xs = [rng.choice(a) for _ in range(len(a))]
        ys = [rng.choice(b) for _ in range(len(b))]
        diffs.append(statistics.mean(xs) - statistics.mean(ys))
    return {
        "mean_diff": statistics.mean(diffs),
        "ci95": [percentile(diffs, 0.025), percentile(diffs, 0.975)],
    }


def summarize_group(rows):
    latencies = [value for value in (parse_float(row["latency_to_enforce_ms"]) for row in rows) if value is not None]
    risk_windows_ms = [value for value in (parse_float(row.get("risk_window_ms")) for row in rows) if value is not None]
    risk_windows = [int(row["risk_window_messages"]) for row in rows]
    deny_values = [int(row["post_revoke_deny"]) for row in rows]
    still_running = [int(row["still_running_after_observe"]) for row in rows]
    risk_window_censored = [int(row.get("risk_window_ms_censored", row["still_running_after_observe"])) for row in rows]
    receiver_ok = [int(row["receiver_status"]) == 200 for row in rows]
    terminations = sum(1 for row in rows if row["termination_ns"])
    return {
        "count": len(rows),
        "termination_observed_count": terminations,
        "still_running_after_observe_rate": sum(still_running) / len(still_running),
        "risk_window_ms_censored_rate": sum(risk_window_censored) / len(risk_window_censored),
        "post_revoke_deny_rate": sum(deny_values) / len(deny_values),
        "receiver_success_rate": sum(receiver_ok) / len(receiver_ok),
        "risk_window_ms_mean": statistics.mean(risk_windows_ms) if risk_windows_ms else None,
        "risk_window_ms_p50": percentile(risk_windows_ms, 0.50),
        "risk_window_ms_p95": percentile(risk_windows_ms, 0.95),
        "risk_window_ms_p99": percentile(risk_windows_ms, 0.99),
        "risk_window_ms_ci95": ci95(risk_windows_ms) if risk_windows_ms else None,
        "risk_window_messages_mean": statistics.mean(risk_windows),
        "risk_window_messages_p50": percentile(risk_windows, 0.50),
        "risk_window_messages_p95": percentile(risk_windows, 0.95),
        "risk_window_messages_p99": percentile(risk_windows, 0.99),
        "risk_window_messages_ci95": ci95(risk_windows),
        "latency_to_enforce_ms_mean": statistics.mean(latencies) if latencies else None,
        "latency_to_enforce_ms_p50": percentile(latencies, 0.50),
        "latency_to_enforce_ms_p95": percentile(latencies, 0.95),
        "latency_to_enforce_ms_p99": percentile(latencies, 0.99),
        "latency_to_enforce_ms_ci95": ci95(latencies) if latencies else None,
    }


def build_report(rows, bootstrap_samples):
    included_rows = []
    grouped = defaultdict(list)
    by_mode_profile = defaultdict(list)
    for row in rows:
        mode = row["mode"]
        profile = Path(row["_source"]).stem.rsplit("-", 1)[-1]
        if profile not in KNOWN_PROFILES:
            continue
        included_rows.append(row)
        grouped[(mode, profile)].append(row)
        by_mode_profile[(mode, profile)].append(int(row["risk_window_messages"]))

    summaries = {}
    for key, group_rows in sorted(grouped.items()):
        mode, profile = key
        summaries[f"{mode}:{profile}"] = {
            "mode": mode,
            "profile": profile,
            **summarize_group(group_rows),
        }

    profiles = [profile for profile in PROFILE_ORDER if any(p == profile for _, p in grouped.keys())]
    comparators = ["baseline-ext_authz", "baseline-istio-custom", "baseline-openfga"]
    comparisons = []
    for profile in profiles:
        reactive_values = by_mode_profile.get(("reactive", profile), [])
        for comparator in comparators:
            other_values = by_mode_profile.get((comparator, profile), [])
            if reactive_values and other_values:
                comparisons.append({
                    "profile": profile,
                    "left_mode": "reactive",
                    "right_mode": comparator,
                    "risk_window_mean_diff_bootstrap": bootstrap_mean_diff(
                        reactive_values, other_values, bootstrap_samples
                    ),
                })

    return {
        "dataset": {
            "modes": sorted({row["mode"] for row in included_rows}),
            "profiles": profiles,
            "total_rows": len(included_rows),
        },
        "per_mode_profile": list(summaries.values()),
        "bootstrap_comparisons": comparisons,
    }


def format_num(value):
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.3f}"
    return str(value)


def mode_label(mode):
    return MODE_LABELS.get(mode, mode)


def render_markdown(report):
    lines = []
    lines.append("# Агрегированный отчёт по матрице экспериментов")
    lines.append("")
    dataset = report["dataset"]
    lines.append(f"Набор данных: `{len(dataset['modes'])} режима x {len(dataset['profiles'])} профиля x 30 повторов`")
    lines.append("")
    lines.append("## Сводка по режимам и профилям")
    lines.append("")
    lines.append("| Режим | Профиль | N | Завершения | Доля живых stream после revoke | Доля post-revoke deny | mean Δ, ms | p95 Δ, ms | mean Δ_messages | p95 Δ_messages | p50 latency | p95 latency |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    for row in report["per_mode_profile"]:
        lines.append(
            f"| {mode_label(row['mode'])} | {row['profile']} | {row['count']} | {row['termination_observed_count']} | "
            f"{format_num(row['still_running_after_observe_rate'])} | {format_num(row['post_revoke_deny_rate'])} | "
            f"{format_num(row['risk_window_ms_mean'])} | {format_num(row['risk_window_ms_p95'])} | "
            f"{format_num(row['risk_window_messages_mean'])} | {format_num(row['risk_window_messages_p95'])} | "
            f"{format_num(row['latency_to_enforce_ms_p50'])} | {format_num(row['latency_to_enforce_ms_p95'])} |"
        )
    lines.append("")
    lines.append("## Bootstrap-сравнение")
    lines.append("")
    lines.append("| Профиль | Левый режим | Правый режим | Разница средних по окну риска | 95% CI |")
    lines.append("| --- | --- | --- | --- | --- |")
    for row in report["bootstrap_comparisons"]:
        comp = row["risk_window_mean_diff_bootstrap"]
        ci = comp["ci95"] if comp else None
        ci_text = "n/a" if ci is None else f"[{format_num(ci[0])}, {format_num(ci[1])}]"
        lines.append(
            f"| {row['profile']} | {mode_label(row['left_mode'])} | {mode_label(row['right_mode'])} | "
            f"{format_num(comp['mean_diff'] if comp else None)} | {ci_text} |"
        )
    lines.append("")
    lines.append("## Примечания")
    lines.append("")
    lines.append("- `termination_observed_count` показывает число прогонов, где stream завершился в окне наблюдения.")
    lines.append("- `risk_window_ms_censored_rate` в JSON показывает долю прогонов, где `Δ` в миллисекундах зацензурирована по окну наблюдения, а не завершением потока.")
    lines.append("- Для архитектур сравнения, которые принимают решение только в момент запроса, ожидаемое поведение: `termination_observed_count=0`, `still_running_after_observe_rate=1.0`, `post_revoke_deny_rate=1.0`.")
    lines.append("- Для `reactive` ожидаемое поведение: `termination_observed_count=count`, низкий `risk_window_messages`, `post_revoke_deny_rate=1.0`.")
    return "\n".join(lines) + "\n"


def main():
    args = parse_args()
    rows = load_rows(args.csvs)
    report = build_report(rows, args.bootstrap_samples)

    json_out = Path(args.json_out)
    md_out = Path(args.md_out)
    json_out.parent.mkdir(parents=True, exist_ok=True)
    md_out.parent.mkdir(parents=True, exist_ok=True)

    json_out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    md_out.write_text(render_markdown(report), encoding="utf-8")
    print(json_out)
    print(md_out)


if __name__ == "__main__":
    main()
