#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
import time


NAMESPACE = "reactive-mesh-authz"
APP_SELECTORS = {
    "receiver": ["receiver"],
    "baseline-control": ["opa", "baseline-authz"],
    "grpc-server": ["grpc-server"],
    "redis": ["redis"],
    "envoy-reactive": ["envoy-reactive"],
    "envoy-baseline": ["envoy-baseline"],
}


def run(cmd):
    return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL).strip()


def run_optional(cmd):
    try:
        return run(cmd)
    except subprocess.CalledProcessError:
        return ""


def pod_for_selector(selector):
    cmd = [
        "kubectl",
        "get",
        "pod",
        "-n",
        NAMESPACE,
        "-l",
        f"app={selector}",
        "-o",
        "jsonpath={.items[0].metadata.name}",
    ]
    return run_optional(cmd)


def pod_for_app(app):
    for selector in APP_SELECTORS[app]:
        value = pod_for_selector(selector)
        if value:
            return value
    raise RuntimeError(f"no pod found for logical app={app}")


def parse_cpu_to_millicores(value):
    value = value.strip()
    if not value:
        return None
    if value.endswith("m"):
        return int(value[:-1])
    return int(float(value) * 1000.0)


def parse_memory_to_mib(value):
    value = value.strip()
    if not value:
        return None
    units = {
        "Ki": 1 / 1024.0,
        "Mi": 1.0,
        "Gi": 1024.0,
    }
    for suffix, multiplier in units.items():
        if value.endswith(suffix):
            return float(value[:-len(suffix)]) * multiplier
    if value.endswith("B"):
        return float(value[:-1]) / (1024.0 * 1024.0)
    return None


def parse_top_output(text):
    metrics = {}
    if not text:
        return metrics
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        metrics[parts[0]] = {
            "cpu_millicores": parse_cpu_to_millicores(parts[1]),
            "memory_mib": parse_memory_to_mib(parts[2]),
        }
    return metrics


def top_metrics_by_pod(expected_pods=None, retries=10, delay_seconds=2.0):
    expected_pods = set(expected_pods or [])
    metrics = {}
    for attempt in range(retries):
        text = run_optional(["kubectl", "top", "pods", "-n", NAMESPACE, "--no-headers"])
        metrics = parse_top_output(text)
        missing = expected_pods.difference(metrics.keys())
        if not missing:
            return metrics
        if attempt + 1 != retries:
            time.sleep(delay_seconds)
    return metrics


def read_proc_file(pod, path):
    commands = [
        ["kubectl", "exec", "-n", NAMESPACE, pod, "--", "cat", path],
        ["kubectl", "exec", "-n", NAMESPACE, pod, "--", "/bin/sh", "-c", f"cat {path}"],
        ["kubectl", "exec", "-n", NAMESPACE, pod, "--", "sh", "-c", f"cat {path}"],
    ]
    last_error = None
    for cmd in commands:
        try:
            return run(cmd)
        except subprocess.CalledProcessError as exc:
            last_error = str(exc)
    raise RuntimeError(last_error or f"unable to read {path} from {pod}")


def parse_status(text):
    data = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        data[key.strip()] = value.strip()
    return data


def parse_stat(text):
    fields = text.split()
    if len(fields) < 17:
        raise RuntimeError("unexpected /proc/1/stat format")
    return {
        "utime_ticks": int(fields[13]),
        "stime_ticks": int(fields[14]),
        "rss_pages": int(fields[23]),
    }


def snapshot_pod(pod):
    status = parse_status(read_proc_file(pod, "/proc/1/status"))
    stat = parse_stat(read_proc_file(pod, "/proc/1/stat"))
    return status, stat


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Collect lightweight overhead snapshot from Kubernetes pods")
    parser.add_argument(
        "out_path",
        nargs="?",
        default="experiments/results/overhead-snapshot.json",
        help="Output JSON path",
    )
    parser.add_argument(
        "--apps",
        default=",".join(APP_SELECTORS.keys()),
        help="Comma-separated logical app names to collect",
    )
    return parser.parse_args(argv[1:])


def main(argv):
    args = parse_args(argv)
    out_path = args.out_path
    clk_tck = os.sysconf(os.sysconf_names["SC_CLK_TCK"])
    page_size = os.sysconf("SC_PAGE_SIZE")

    selected_apps = [app.strip() for app in args.apps.split(",") if app.strip()]
    unknown_apps = [app for app in selected_apps if app not in APP_SELECTORS]
    if unknown_apps:
        raise RuntimeError(f"unknown logical apps: {', '.join(unknown_apps)}")

    pods = {}
    pod_lookup_errors = {}
    for app in selected_apps:
        try:
            pods[app] = pod_for_app(app)
        except Exception as exc:  # noqa: BLE001
            pod_lookup_errors[app] = str(exc)
    top_required = [pod for pod in pods.values() if pod]
    top_metrics = top_metrics_by_pod(top_required)
    first = {}
    errors = {}
    for app, message in pod_lookup_errors.items():
        errors[app] = message
    for app, pod in pods.items():
        try:
            first[app] = snapshot_pod(pod)
        except Exception as exc:  # noqa: BLE001
            errors[app] = str(exc)
    time.sleep(1.0)
    second = {}
    for app, pod in pods.items():
        if app in errors:
            continue
        try:
            second[app] = snapshot_pod(pod)
        except Exception as exc:  # noqa: BLE001
            errors[app] = str(exc)

    result = {
        "namespace": NAMESPACE,
        "sampling_interval_seconds": 1.0,
        "apps": {},
    }
    for app in selected_apps:
        pod = pods.get(app, "")
        if app in errors:
            result["apps"][app] = {
                "pod": pod,
                "status": "unavailable",
                "error": errors[app],
                "kubectl_top": top_metrics.get(pod),
            }
            continue
        status1, stat1 = first[app]
        status2, stat2 = second[app]
        cpu_delta_ticks = (stat2["utime_ticks"] + stat2["stime_ticks"]) - (stat1["utime_ticks"] + stat1["stime_ticks"])
        cpu_seconds = cpu_delta_ticks / clk_tck
        result["apps"][app] = {
            "pod": pod,
            "vmrss_kb": int(status2.get("VmRSS", "0 kB").split()[0]),
            "threads": int(status2.get("Threads", "0")),
            "cpu_seconds_over_interval": cpu_seconds,
            "cpu_percent_single_core_equivalent": cpu_seconds * 100.0,
            "rss_bytes_from_stat": stat2["rss_pages"] * page_size,
            "kubectl_top": top_metrics.get(pod),
        }

    with open(out_path, "w", encoding="utf-8") as fh:
        json.dump(result, fh, indent=2)
        fh.write("\n")
    print(out_path)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
