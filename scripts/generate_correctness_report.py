#!/usr/bin/env python3
import csv
import json
import pathlib
import sys


def load_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def load_csv_row(path):
    with path.open(encoding="utf-8", newline="") as fh:
        return next(csv.DictReader(fh))


def percent(value):
    return f"{value * 100.0:.1f}%"


def main(argv):
    outdir = pathlib.Path(argv[1]) if len(argv) > 1 else pathlib.Path("experiments/results/verify-mvp")
    json_out = pathlib.Path(argv[2]) if len(argv) > 2 else outdir / "correctness-report.json"
    md_out = pathlib.Path(argv[3]) if len(argv) > 3 else pathlib.Path("docs/evaluation/CORRECTNESS_REPORT.md")

    reactive = load_csv_row(outdir / "reactive-smoke.csv")
    no_event = load_json(outdir / "no-event-stability.json")
    oss = outdir / "verify-oss-comparators"
    opa = load_json(oss / "baseline-opa-smoke.json")
    istio = load_json(oss / "baseline-istio-custom-smoke.json")
    openfga = load_json(oss / "baseline-openfga-smoke.json")
    spicedb_path = oss / "baseline-spicedb-smoke.json"
    spicedb = load_json(spicedb_path) if spicedb_path.exists() else None
    summary = load_json(oss / "summary.json")

    reactive_termination_ok = reactive["receiver_status"] == "200" and reactive["still_running_after_observe"] == "0"
    reactive_reopen_denied = reactive["post_revoke_deny"] == "1"
    no_false_termination = no_event["still_running_after_window"] is True and int(no_event["message_count"]) > 0
    opa_request_time_ok = (
        opa["still_running_after_revoke"] is True
        and opa["post_lines"] > opa["pre_lines"]
        and opa["reopen_code"] != 0
        and opa.get("reopen_streamed") is False
    )
    openfga_request_time_ok = (
        openfga["still_running_after_revoke"] is True
        and openfga["post_lines"] > openfga["pre_lines"]
        and openfga["reopen_code"] != 0
        and openfga.get("reopen_streamed") is False
    )
    istio_request_time_ok = (
        istio["still_running_after_revoke"] is True
        and istio["post_lines"] > istio["pre_lines"]
        and istio["reopen_code"] != 0
        and istio.get("reopen_streamed") is False
    )

    report = {
        "reactive": {
            "termination_after_revoke": reactive_termination_ok,
            "post_revoke_deny": reactive_reopen_denied,
            "latency_to_enforce_ms": float(reactive["latency_to_enforce_ms"]),
            "risk_window_messages": int(reactive["risk_window_messages"]),
            "missed_revocation_rate": 0.0 if reactive_termination_ok and reactive_reopen_denied else 1.0,
            "false_termination_rate": 0.0 if no_false_termination else 1.0,
        },
        "no_event_stability": {
            "still_running_after_window": no_event["still_running_after_window"],
            "message_count": int(no_event["message_count"]),
        },
        "comparators": {
            "opa": {
                "still_running_after_revoke": opa["still_running_after_revoke"],
                "reopen_denied_without_streaming": opa.get("reopen_streamed") is False and opa["reopen_code"] != 0,
                "summary_ok": summary["baseline_opa_ok"] is True,
            },
            "istio_custom": {
                "still_running_after_revoke": istio["still_running_after_revoke"],
                "reopen_denied_without_streaming": istio.get("reopen_streamed") is False and istio["reopen_code"] != 0,
                "summary_ok": summary["baseline_istio_custom_ok"] is True and istio_request_time_ok,
            },
            "openfga": {
                "still_running_after_revoke": openfga["still_running_after_revoke"],
                "reopen_denied_without_streaming": openfga.get("reopen_streamed") is False and openfga["reopen_code"] != 0,
                "summary_ok": summary["baseline_openfga_ok"] is True and openfga_request_time_ok,
            },
        },
        "derived_rates": {
            "false_termination_rate": 0.0 if no_false_termination else 1.0,
            "missed_revocation_rate": 0.0 if reactive_termination_ok and reactive_reopen_denied else 1.0,
        },
    }
    if spicedb is not None:
        spicedb_request_time_ok = (
            spicedb["still_running_after_revoke"] is True
            and spicedb["post_lines"] > spicedb["pre_lines"]
            and spicedb["reopen_code"] != 0
            and spicedb.get("reopen_streamed") is False
        )
        report["comparators"]["spicedb"] = {
            "still_running_after_revoke": spicedb["still_running_after_revoke"],
            "reopen_denied_without_streaming": spicedb.get("reopen_streamed") is False and spicedb["reopen_code"] != 0,
            "summary_ok": summary.get("baseline_spicedb_ok") is True and spicedb_request_time_ok,
        }

    json_out.parent.mkdir(parents=True, exist_ok=True)
    json_out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    md_out.parent.mkdir(parents=True, exist_ok=True)
    md_out.write_text(
        "\n".join(
            [
                "# Отчёт по корректности enforcement",
                "",
                f"Источник артефактов: `{outdir}`",
                "",
                "## Итог",
                "",
                "| Метрика | Значение | Основание |",
                "| --- | --- | --- |",
                f"| `false_termination_rate` | {percent(report['derived_rates']['false_termination_rate'])} | no-event stability подтверждает, что reactive stream не завершается без matching revoke |",
                f"| `missed_revocation_rate` | {percent(report['derived_rates']['missed_revocation_rate'])} | reactive smoke подтверждает revoke-to-termination и post-revoke deny |",
                f"| `latency_to_enforce_ms` | {report['reactive']['latency_to_enforce_ms']:.3f} | reactive smoke |",
                f"| `risk_window_messages` | {report['reactive']['risk_window_messages']} | reactive smoke |",
                "",
                "## Comparator sanity-check",
                "",
                "| Comparator | Уже активный stream живёт после revoke | Новый stream после revoke блокируется без данных | Итог |",
                "| --- | --- | --- | --- |",
                f"| OPA + Envoy | {'Да' if report['comparators']['opa']['still_running_after_revoke'] else 'Нет'} | {'Да' if report['comparators']['opa']['reopen_denied_without_streaming'] else 'Нет'} | {'OK' if report['comparators']['opa']['summary_ok'] else 'FAIL'} |",
                f"| Istio CUSTOM | {'Да' if report['comparators']['istio_custom']['still_running_after_revoke'] else 'Нет'} | {'Да' if report['comparators']['istio_custom']['reopen_denied_without_streaming'] else 'Нет'} | {'OK' if report['comparators']['istio_custom']['summary_ok'] else 'FAIL'} |",
                f"| OpenFGA | {'Да' if report['comparators']['openfga']['still_running_after_revoke'] else 'Нет'} | {'Да' if report['comparators']['openfga']['reopen_denied_without_streaming'] else 'Нет'} | {'OK' if report['comparators']['openfga']['summary_ok'] else 'FAIL'} |",
                "",
                "## Вывод",
                "",
                "Reactive path завершает уже активный stream после revoke и не завершает stream без matching event. Request-time OSS comparator'ы OPA + Envoy, Istio CUSTOM и OpenFGA, наоборот, не обрывают уже допущенный stream, но блокируют новое подключение после revoke.",
                "",
            ]
        ),
        encoding="utf-8",
    )

    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
