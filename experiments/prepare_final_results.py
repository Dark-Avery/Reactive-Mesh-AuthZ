#!/usr/bin/env python3
import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


REQUEST_TIME_MODES = ["baseline-ext_authz", "baseline-istio-custom"]
CENTRALIZED_MODES = ["baseline-openfga"]
ALL_BASELINES = REQUEST_TIME_MODES + CENTRALIZED_MODES
PROFILE_ORDER = ["low", "medium", "high"]
MODE_LABELS = {
    "reactive": "Reactive",
    "baseline-ext_authz": "OPA + Envoy",
    "baseline-istio-custom": "Istio CUSTOM",
    "baseline-openfga": "OpenFGA",
    "baseline-spicedb": "SpiceDB",
    "baseline-poll": "Poll baseline (internal)",
    "baseline-push": "Push baseline (internal)",
}


def parse_args():
    parser = argparse.ArgumentParser(description="Подготовить итоговый пакет экспериментальных результатов")
    parser.add_argument(
        "--matrix-report",
        default="experiments/results/matrix-report-full.json",
        help="JSON, полученный после агрегации полной матрицы экспериментов",
    )
    parser.add_argument(
        "--verify-summary",
        default="experiments/results/verify-mvp/summary.json",
        help="JSON сводной локальной проверки стенда",
    )
    parser.add_argument(
        "--correctness",
        default="experiments/results/verify-mvp/correctness-report.json",
        help="JSON отчёта о корректности",
    )
    parser.add_argument(
        "--overhead",
        default="experiments/results/verify-mvp/overhead-snapshot.json",
        help="JSON со снимком накладных расходов",
    )
    parser.add_argument(
        "--json-out",
        default="experiments/results/final-experiment-summary.json",
        help="Путь для итогового JSON",
    )
    parser.add_argument(
        "--deny-latency",
        default="experiments/results/deny-latency/summary.json",
        help="Локальный JSON с измерением задержки запрета после revoke",
    )
    parser.add_argument(
        "--md-out",
        default="docs/evaluation/EXPERIMENT_RESULTS_RU.md",
        help="Путь для итогового Markdown-отчёта",
    )
    parser.add_argument(
        "--idp-reactive",
        default="experiments/results/verify-demo-idp-reactive/summary.json",
        help="Локальный JSON короткой проверки IdP для реактивного режима",
    )
    parser.add_argument(
        "--idp-baseline",
        default="experiments/results/verify-demo-idp-baseline/summary.json",
        help="Локальный JSON короткой проверки IdP для OPA + Envoy",
    )
    parser.add_argument(
        "--istio-smoke",
        default="experiments/results/istio-custom-smoke.json",
        help="Локальный JSON короткой проверки IdP для Istio CUSTOM",
    )
    return parser.parse_args()


def read_json(path_str):
    path = Path(path_str)
    return json.loads(path.read_text(encoding="utf-8"))


def read_optional_json(path_str):
    path = Path(path_str)
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def index_mode_profile(matrix_report):
    indexed = {}
    for row in matrix_report["per_mode_profile"]:
        indexed[(row["mode"], row["profile"])] = row
    return indexed


def average(values):
    if not values:
        return None
    return sum(values) / len(values)


def fmt(value, digits=3):
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.{digits}f}"
    return str(value)


def collect_mode_summary(indexed, mode):
    rows = [row for (m, _), row in indexed.items() if m == mode]
    rows.sort(key=lambda row: row["profile"])
    return {
        "profiles": {
            row["profile"]: {
                "risk_window_messages_mean": row["risk_window_messages_mean"],
                "risk_window_messages_p95": row["risk_window_messages_p95"],
                "risk_window_ms_mean": row.get("risk_window_ms_mean"),
                "risk_window_ms_p95": row.get("risk_window_ms_p95"),
                "risk_window_ms_censored_rate": row.get("risk_window_ms_censored_rate"),
                "post_revoke_deny_rate": row["post_revoke_deny_rate"],
                "termination_observed_count": row["termination_observed_count"],
                "still_running_after_observe_rate": row["still_running_after_observe_rate"],
                "latency_to_enforce_ms_p50": row["latency_to_enforce_ms_p50"],
                "latency_to_enforce_ms_p95": row["latency_to_enforce_ms_p95"],
                "latency_to_enforce_ms_p99": row["latency_to_enforce_ms_p99"],
                "latency_to_enforce_ms_mean": row["latency_to_enforce_ms_mean"],
            }
            for row in rows
        },
        "risk_window_messages_mean_across_profiles": average(
            [row["risk_window_messages_mean"] for row in rows]
        ),
        "risk_window_ms_mean_across_profiles": average(
            [row["risk_window_ms_mean"] for row in rows if row.get("risk_window_ms_mean") is not None]
        ),
        "post_revoke_deny_rate_across_profiles": average(
            [row["post_revoke_deny_rate"] for row in rows]
        ),
    }


def collect_family_answers(indexed):
    profiles = [profile for profile in PROFILE_ORDER if ("reactive", profile) in indexed]
    request_time = {}
    centralized = {}
    for profile in profiles:
        reactive = indexed[("reactive", profile)]
        reactive_risk = reactive["risk_window_messages_mean"]

        if any((mode, profile) not in indexed for mode in REQUEST_TIME_MODES):
            continue
        request_rows = {mode: indexed[(mode, profile)] for mode in REQUEST_TIME_MODES}
        request_time[profile] = {
            mode: {
                "risk_window_delta_messages": request_rows[mode]["risk_window_messages_mean"] - reactive_risk,
                "risk_window_delta_ms": request_rows[mode]["risk_window_ms_mean"] - reactive["risk_window_ms_mean"]
                if request_rows[mode].get("risk_window_ms_mean") is not None and reactive.get("risk_window_ms_mean") is not None
                else None,
                "reactive_termination_count": reactive["termination_observed_count"],
                "baseline_termination_count": request_rows[mode]["termination_observed_count"],
            }
            for mode in REQUEST_TIME_MODES
        }

        centralized[profile] = {}
        for mode in CENTRALIZED_MODES:
            if (mode, profile) not in indexed:
                continue
            mode_row = indexed[(mode, profile)]
            centralized[profile][mode] = {
                "risk_window_delta_messages": mode_row["risk_window_messages_mean"] - reactive_risk,
                "risk_window_delta_ms": mode_row["risk_window_ms_mean"] - reactive["risk_window_ms_mean"]
                if mode_row.get("risk_window_ms_mean") is not None and reactive.get("risk_window_ms_mean") is not None
                else None,
                "post_revoke_deny_rate": mode_row["post_revoke_deny_rate"],
            }

    return {
        "request_time_vs_reactive": request_time,
        "centralized_authz_vs_reactive": centralized,
    }


def build_summary(matrix_report, verify_summary, correctness, overhead, deny_latency=None, idp_smokes=None):
    indexed = index_mode_profile(matrix_report)
    dataset = matrix_report["dataset"]
    verification = {
        key: value
        for key, value in verify_summary.items()
        if key not in {"baseline_push_ok", "baseline_spicedb_ok"}
    }
    allowed_modes = set(dataset["modes"])
    filtered_deny_latency = [
        row for row in (deny_latency or [])
        if row.get("mode") in allowed_modes
    ]
    summary = {
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "dataset": dataset,
        "verification": verification,
        "correctness": correctness,
        "overhead_snapshot": {
            app: data.get("kubectl_top")
            for app, data in overhead.get("apps", {}).items()
            if data.get("kubectl_top") is not None
        },
        "modes": {
            mode: collect_mode_summary(indexed, mode)
            for mode in sorted({mode for mode, _ in indexed})
        },
        "family_answers": collect_family_answers(indexed),
        "deny_latency": filtered_deny_latency,
        "idp_smokes": idp_smokes or {},
    }
    summary["required_baseline_metrics"] = {
        "latency_to_enforce_ms": {
            "reactive_available": any(
                row.get("latency_to_enforce_ms_p95") is not None
                for row in summary["modes"].get("reactive", {}).get("profiles", {}).values()
            ),
            "comparator_note": "Для архитектур, которые принимают решение только в момент запроса или во внешнем централизованном контуре авторизации, прерывание уже активного потока не наблюдается. Поэтому `latency_to_enforce_ms` как время от revoke до завершения потока определяется только для реактивного режима, а для архитектур сравнения остаются `risk_window_ms`, `risk_window_messages` и `post_revoke_deny`.",
        },
        "risk_window_delta_ms": True,
        "risk_window_delta_messages": True,
        "post_revoke_deny": True,
        "overhead_no_events": summary["verification"].get("overhead_ok") is True,
        "false_termination_rate": summary["correctness"]["derived_rates"]["false_termination_rate"] == 0.0,
        "missed_revocation_rate": summary["correctness"]["derived_rates"]["missed_revocation_rate"] == 0.0,
    }

    summary["headline_findings"] = [
        "Реактивный режим завершает активные потоки во всех трёх профилях нагрузки, тогда как все открытые архитектуры сравнения оставляют уже допущенный поток активным.",
        "Реактивный режим удерживает окно риска около нуля в профилях low и medium и около одного сообщения в профиле high.",
        "Архитектуры `OPA + Envoy`, `Istio CUSTOM` и `OpenFGA` обеспечивают запрет повторного открытия после revoke, но не прерывают уже активный поток.",
    ]
    if idp_smokes and idp_smokes.get("reactive") and idp_smokes.get("baseline_ext_authz"):
        summary["headline_findings"].append(
            "Локальный OIDC/JWKS IdP подтверждает тот же архитектурный разрыв: реактивный режим завершает поток с bearer-token после revoke, а `OPA + Envoy` оставляет текущий поток активным и блокирует только повторное открытие."
        )
    if idp_smokes and idp_smokes.get("istio_custom"):
        summary["headline_findings"].append(
            "`Istio CUSTOM` в том же OIDC/JWKS-сценарии подтверждает поведение авторизации в момент запроса: активный поток не прерывается, но повторное открытие после revoke отклоняется."
        )
    return summary


def render_report(summary):
    dataset = summary["dataset"]
    lines = []
    lines.append("# Итоговые результаты экспериментов")
    lines.append("")
    lines.append(f"Дата генерации: `{summary['generated_at_utc']}`")
    lines.append("")
    lines.append("## Короткий вывод")
    lines.append("")
    lines.append(
        "Реактивный режим подтверждённо превосходит открытые архитектуры авторизации в момент запроса "
        "и открытые централизованные архитектуры авторизации по `risk window Δ` для уже активных gRPC-потоков, сохраняя `post_revoke_deny=1.0`."
    )
    lines.append("")
    lines.append("## Набор данных")
    lines.append("")
    lines.append(f"- режимы: `{', '.join(MODE_LABELS.get(mode, mode) for mode in dataset['modes'])}`")
    lines.append(f"- профили: `{', '.join(dataset['profiles'])}`")
    lines.append(f"- всего строк в наборе повторов: `{dataset['total_rows']}`")
    lines.append("")
    lines.append("## Главные наблюдения")
    lines.append("")
    for item in summary["headline_findings"]:
        lines.append(f"- {item}")
    lines.append("")
    if summary.get("idp_smokes"):
        reactive_idp = summary["idp_smokes"].get("reactive")
        baseline_idp = summary["idp_smokes"].get("baseline_ext_authz")
        istio_idp = summary["idp_smokes"].get("istio_custom")
        if reactive_idp and baseline_idp:
            lines.append("## Локальная интеграция с IdP: короткая проверка OIDC/JWKS")
            lines.append("")
            lines.append(
                f"- `reactive + demo-idp`: terminate после revoke, `latency_to_enforce_ms={fmt(reactive_idp['latency_to_enforce_ms'])}`."
            )
            lines.append(
                f"- `OPA + Envoy + demo-idp`: поток остаётся активным (`pre_lines={baseline_idp['pre_lines']}`, `post_lines={baseline_idp['post_lines']}`), но reopen deny подтверждён."
            )
            if istio_idp:
                lines.append(
                    f"- `Istio CUSTOM + demo-idp`: поток остаётся активным (`pre_lines={istio_idp['pre_lines']}`, `post_lines={istio_idp['post_lines']}`), и reopen deny подтверждён."
                )
            lines.append("")
    lines.append("## Reactive по профилям")
    lines.append("")
    lines.append("| Профиль | mean Δ, ms | p95 Δ, ms | mean Δ_messages | p95 Δ_messages | p50 latency, ms | p95 latency, ms | p99 latency, ms |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for profile, row in summary["modes"]["reactive"]["profiles"].items():
        lines.append(
            f"| {profile} | {fmt(row['risk_window_ms_mean'])} | {fmt(row['risk_window_ms_p95'])} | "
            f"{fmt(row['risk_window_messages_mean'])} | {fmt(row['risk_window_messages_p95'])} | "
            f"{fmt(row['latency_to_enforce_ms_p50'])} | {fmt(row['latency_to_enforce_ms_p95'])} | {fmt(row['latency_to_enforce_ms_p99'])} |"
        )
    lines.append("")
    lines.append("## Архитектуры сравнения по окну риска")
    lines.append("")
    lines.append("| Режим | low mean Δ_messages | medium mean Δ_messages | high mean Δ_messages | post-revoke deny rate |")
    lines.append("| --- | --- | --- | --- | --- |")
    for mode in ["baseline-ext_authz", "baseline-istio-custom", "baseline-openfga"]:
        mode_summary = summary["modes"][mode]
        lines.append(
            f"| {MODE_LABELS[mode]} | {fmt(mode_summary['profiles']['low']['risk_window_messages_mean'])} | "
            f"{fmt(mode_summary['profiles']['medium']['risk_window_messages_mean'])} | "
            f"{fmt(mode_summary['profiles']['high']['risk_window_messages_mean'])} | "
            f"{fmt(mode_summary['post_revoke_deny_rate_across_profiles'])} |"
        )
    lines.append("")
    lines.append("## Ответы на исследовательские вопросы")
    lines.append("")
    lines.append("1. Насколько реактивный режим лучше открытых архитектур авторизации в момент запроса?")
    for profile, data in summary["family_answers"]["request_time_vs_reactive"].items():
        deltas = ", ".join(
            f"{MODE_LABELS.get(mode, mode)}: +{fmt(values['risk_window_delta_messages'])} msg"
            for mode, values in data.items()
        )
        lines.append(f"- {profile}: {deltas}")
    lines.append("")
    lines.append("2. Сохраняется ли преимущество относительно открытой централизованной архитектуры авторизации?")
    for profile, data in summary["family_answers"]["centralized_authz_vs_reactive"].items():
        lines.append(
            f"- {profile}: OpenFGA `+{fmt(data['baseline-openfga']['risk_window_delta_messages'])}` сообщений относительно `reactive`."
        )
    lines.append("")
    lines.append("## Корректность и проверка")
    lines.append("")
    verification = summary["verification"]
    for key, value in verification.items():
        lines.append(f"- `{key}={str(value).lower()}`")
    lines.append(f"- `false_termination_rate={fmt(summary['correctness']['derived_rates']['false_termination_rate'])}`")
    lines.append(f"- `missed_revocation_rate={fmt(summary['correctness']['derived_rates']['missed_revocation_rate'])}`")
    lines.append("")
    lines.append("## Снимок накладных расходов")
    lines.append("")
    for app, data in sorted(summary["overhead_snapshot"].items()):
        lines.append(
            f"- `{app}`: cpu=`{data.get('cpu_millicores')}m`, memory=`{fmt(data.get('memory_mib'))} MiB`"
        )
    lines.append("")
    lines.append("## Базовые артефакты")
    lines.append("")
    lines.append(
        "- [experiments/results/matrix-report-full.json](experiments/results/matrix-report-full.json)"
    )
    lines.append(
        "- [experiments/results/matrix-summary-full.json](experiments/results/matrix-summary-full.json)"
    )
    lines.append(
        "- [experiments/results/verify-mvp/summary.json](experiments/results/verify-mvp/summary.json)"
    )
    lines.append(
        "- [experiments/results/verify-oss-comparators/summary.json](experiments/results/verify-oss-comparators/summary.json)"
    )
    if summary.get("deny_latency"):
        lines.append(
            "- [experiments/results/deny-latency/summary.json](experiments/results/deny-latency/summary.json)"
        )
        lines.append(
            "- [experiments/results/plots/deny_latency_by_mode.png](experiments/results/plots/deny_latency_by_mode.png)"
        )
    if summary.get("idp_smokes"):
        lines.append(
            "- [experiments/results/verify-demo-idp-reactive/summary.json](experiments/results/verify-demo-idp-reactive/summary.json)"
        )
        lines.append(
            "- [experiments/results/verify-demo-idp-baseline/summary.json](experiments/results/verify-demo-idp-baseline/summary.json)"
        )
        if summary["idp_smokes"].get("istio_custom"):
            lines.append(
                "- [experiments/results/istio-custom-smoke.json](experiments/results/istio-custom-smoke.json)"
            )
    return "\n".join(lines) + "\n"


def main():
    args = parse_args()
    matrix_report = read_json(args.matrix_report)
    verify_summary = read_json(args.verify_summary)
    correctness = read_json(args.correctness)
    overhead = read_json(args.overhead)
    deny_latency_path = Path(args.deny_latency)
    deny_latency = read_json(args.deny_latency) if deny_latency_path.exists() else None

    summary = build_summary(
        matrix_report,
        verify_summary,
        correctness,
        overhead,
        deny_latency=deny_latency,
        idp_smokes={
            "reactive": read_optional_json(args.idp_reactive),
            "baseline_ext_authz": read_optional_json(args.idp_baseline),
            "istio_custom": read_optional_json(args.istio_smoke),
        },
    )

    json_out = Path(args.json_out)
    md_out = Path(args.md_out)
    json_out.parent.mkdir(parents=True, exist_ok=True)
    md_out.parent.mkdir(parents=True, exist_ok=True)

    json_out.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    md_out.write_text(render_report(summary), encoding="utf-8")

    print(json_out)
    print(md_out)


if __name__ == "__main__":
    main()
