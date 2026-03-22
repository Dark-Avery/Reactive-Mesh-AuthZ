#!/usr/bin/env python3
import argparse
import base64
import csv
import http.client
import json
import queue
import subprocess
import threading
import time
import urllib.error
import urllib.request
import urllib.parse
import uuid
from pathlib import Path


def parse_args():
    p = argparse.ArgumentParser(description="Run reactive vs baseline stream revocation benchmark")
    p.add_argument("--client-binary", required=True, help="Path to grpc-client binary")
    p.add_argument("--grpc-addr", required=True, help="Envoy listener address, e.g. localhost:8081")
    p.add_argument("--receiver-url", required=True, help="Receiver /event endpoint")
    p.add_argument(
        "--mode",
        required=True,
        choices=[
            "reactive",
            "baseline-ext_authz",
            "baseline-istio-custom",
            "baseline-poll",
            "baseline-push",
            "baseline-openfga",
            "baseline-spicedb",
        ],
    )
    p.add_argument("--iterations", type=int, default=1)
    p.add_argument("--revoke-after-ms", type=int, default=1000)
    p.add_argument("--interval-ms", type=int, default=200)
    p.add_argument("--observe-after-revoke-ms", type=int, default=2000)
    p.add_argument("--sub", default="alice")
    p.add_argument("--sid", default="demo-session")
    p.add_argument("--jti", default="demo-token")
    p.add_argument("--token-url", default="")
    p.add_argument("--token-realm", default="reactive-mesh")
    p.add_argument("--token-client-id", default="reactive-mesh-cli")
    p.add_argument("--token-username", default="alice")
    p.add_argument("--token-password", default="alice-pass")
    p.add_argument("--event-match-fields", default="sub,sid,jti")
    p.add_argument("--output", default="experiments/results/latest.csv")
    return p.parse_args()


def send_event(receiver_url, sub, sid, jti, event_match_fields):
    payload_obj = {
        "event_type": "session-revoked",
        "reason": "benchmark_revoke",
    }
    match_fields = {item.strip() for item in event_match_fields.split(",") if item.strip()}
    if "sub" in match_fields:
        payload_obj["sub"] = sub
    if "sid" in match_fields:
        payload_obj["sid"] = sid
    if "jti" in match_fields:
        payload_obj["jti"] = jti
    payload = json.dumps(payload_obj).encode()
    req = urllib.request.Request(receiver_url, data=payload, headers={"content-type": "application/json"})
    last_error = None
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                return resp.status, resp.read().decode()
        except (urllib.error.URLError, http.client.HTTPException, OSError) as exc:
            last_error = exc
            if attempt == 4:
                raise
            time.sleep(0.5)
    raise RuntimeError(f"unable to POST revoke event: {last_error}")


def iteration_ids(args, run_id):
    suffix = f"{run_id}-{uuid.uuid4().hex[:8]}"
    return (
        f"{args.sub}-{suffix}",
        f"{args.sid}-{suffix}",
        f"{args.jti}-{suffix}",
    )


def normalize_token_url(args):
    if not args.token_url:
        return ""
    if "/protocol/openid-connect/token" in args.token_url:
        return args.token_url
    return f"{args.token_url.rstrip('/')}/realms/{args.token_realm}/protocol/openid-connect/token"


def fetch_token(args):
    token_url = normalize_token_url(args)
    if not token_url:
        return ""
    payload = urllib.parse.urlencode(
        {
            "grant_type": "password",
            "client_id": args.token_client_id,
            "username": args.token_username,
            "password": args.token_password,
        }
    ).encode()
    req = urllib.request.Request(
        token_url,
        data=payload,
        headers={"content-type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = json.loads(resp.read().decode())
    return body["access_token"]


def decode_token_payload(token):
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload.encode()).decode())


def resolve_identity(args, run_id):
    if not args.token_url:
        sub, sid, jti = iteration_ids(args, run_id)
        return sub, sid, jti, "", {}
    token = fetch_token(args)
    payload = decode_token_payload(token)
    return payload["sub"], payload["sid"], payload["jti"], token, payload


def reader_thread(stream, out_queue):
    for line in iter(stream.readline, b""):
        out_queue.put((time.time_ns(), line.decode(errors="replace").rstrip()))


def client_command(client_binary, grpc_addr, interval_ms, sub, sid, jti, bearer_token=""):
    cmd = [
        client_binary,
        "--addr",
        grpc_addr,
        "--interval",
        f"{interval_ms}ms",
        "--sub",
        sub,
        "--sid",
        sid,
        "--jti",
        jti,
    ]
    if bearer_token:
        cmd.extend(["--bearer-token", bearer_token])
    return cmd


def attempt_reopen(client_binary, grpc_addr, sub, sid, jti, interval_ms, bearer_token=""):
    try:
        proc = subprocess.run(
            client_command(client_binary, grpc_addr, interval_ms, sub, sid, jti, bearer_token),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
            text=True,
        )
        output = (proc.stdout or "") + (proc.stderr or "")
        return proc.returncode != 0 and "seq=" not in output
    except subprocess.TimeoutExpired:
        return True


def run_once(args, run_id):
    sub, sid, jti, token, token_payload = resolve_identity(args, run_id)
    out_q = queue.Queue()
    proc = subprocess.Popen(
        client_command(args.client_binary, args.grpc_addr, args.interval_ms, sub, sid, jti, token),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    thread = threading.Thread(target=reader_thread, args=(proc.stdout, out_q), daemon=True)
    thread.start()

    start_ns = time.time_ns()
    time.sleep(args.revoke_after_ms / 1000.0)
    revoke_ns = time.time_ns()
    event_status, event_body = send_event(args.receiver_url, sub, sid, jti, args.event_match_fields)

    lines = []
    termination_ns = None
    observation_end_ns = None
    observe_deadline = time.time() + (args.observe_after_revoke_ms / 1000.0)
    while True:
      try:
          ts_ns, line = out_q.get(timeout=0.25)
          lines.append((ts_ns, line))
          if proc.poll() is not None:
              termination_ns = time.time_ns()
              observation_end_ns = termination_ns
              break
          if time.time() >= observe_deadline:
              observation_end_ns = time.time_ns()
              break
      except queue.Empty:
          if proc.poll() is not None:
              termination_ns = time.time_ns()
              observation_end_ns = termination_ns
              break
          if time.time() >= observe_deadline:
              observation_end_ns = time.time_ns()
              break

    still_running_after_observe = proc.poll() is None
    if still_running_after_observe:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)
    elif termination_ns is None:
        termination_ns = time.time_ns()
        observation_end_ns = termination_ns

    if observation_end_ns is None:
        observation_end_ns = time.time_ns()

    post_revoke_messages = sum(1 for ts_ns, line in lines if ts_ns >= revoke_ns and "seq=" in line)
    reopen_denied = attempt_reopen(args.client_binary, args.grpc_addr, sub, sid, jti, args.interval_ms, token)

    latency_ms = ""
    risk_window_ms = round((observation_end_ns - revoke_ns) / 1_000_000, 3)
    risk_window_ms_censored = int(still_running_after_observe)
    if termination_ns is not None:
        latency_ms = round((termination_ns - revoke_ns) / 1_000_000, 3)

    return {
        "mode": args.mode,
        "run_id": run_id,
        "sub": sub,
        "sid": sid,
        "jti": jti,
        "stream_start_ns": start_ns,
        "revoke_sent_ns": revoke_ns,
        "termination_ns": termination_ns,
        "latency_to_enforce_ms": latency_ms,
        "risk_window_ms": risk_window_ms,
        "risk_window_ms_censored": risk_window_ms_censored,
        "risk_window_messages": post_revoke_messages,
        "post_revoke_deny": int(reopen_denied),
        "still_running_after_observe": int(still_running_after_observe),
        "receiver_status": event_status,
        "receiver_body": event_body,
        "output_lines": len(lines),
        "observe_after_revoke_ms": args.observe_after_revoke_ms,
        "token_issuer": token_payload.get("iss", ""),
        "auth_flow": "demo-idp" if token else "direct-headers",
        "event_match_fields": args.event_match_fields,
    }


def ensure_parent(path):
    Path(path).parent.mkdir(parents=True, exist_ok=True)


def main():
    args = parse_args()
    ensure_parent(args.output)
    rows = [run_once(args, i + 1) for i in range(args.iterations)]
    with open(args.output, "w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {len(rows)} rows to {args.output}")


if __name__ == "__main__":
    main()
