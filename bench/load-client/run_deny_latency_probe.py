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
    p = argparse.ArgumentParser(description="Measure revoke-to-first-deny latency for new stream attempts")
    p.add_argument("--client-binary", required=True)
    p.add_argument("--grpc-addr", required=True)
    p.add_argument("--receiver-url", required=True)
    p.add_argument(
        "--mode",
        required=True,
        choices=[
            "reactive",
            "baseline-ext_authz",
            "baseline-poll",
            "baseline-push",
            "baseline-openfga",
            "baseline-spicedb",
        ],
    )
    p.add_argument("--iterations", type=int, default=30)
    p.add_argument("--revoke-after-ms", type=int, default=1000)
    p.add_argument("--stream-interval-ms", type=int, default=200)
    p.add_argument("--probe-interval-ms", type=int, default=100)
    p.add_argument("--probe-stream-interval-ms", type=int, default=50)
    p.add_argument("--probe-timeout-ms", type=int, default=700)
    p.add_argument("--probe-deadline-ms", type=int, default=4000)
    p.add_argument("--sub", default="deny-probe-sub")
    p.add_argument("--sid", default="deny-probe-sid")
    p.add_argument("--jti", default="deny-probe-jti")
    p.add_argument("--token-url", default="")
    p.add_argument("--token-realm", default="reactive-mesh")
    p.add_argument("--token-client-id", default="reactive-mesh-cli")
    p.add_argument("--token-username", default="alice")
    p.add_argument("--token-password", default="alice-pass")
    p.add_argument("--event-match-fields", default="sub,sid,jti")
    p.add_argument("--output", default="experiments/results/deny-probe-latest.csv")
    return p.parse_args()


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


def send_event(receiver_url, sub, sid, jti, event_match_fields):
    payload_obj = {
        "event_type": "session-revoked",
        "reason": "deny_latency_probe",
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


def attempt_probe(client_binary, grpc_addr, sub, sid, jti, interval_ms, timeout_ms, bearer_token=""):
    try:
        proc = subprocess.run(
            client_command(client_binary, grpc_addr, interval_ms, sub, sid, jti, bearer_token),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout_ms / 1000.0,
            check=False,
            text=True,
        )
        output = proc.stdout + proc.stderr
        streamed = "seq=" in output
        denied = proc.returncode != 0 and not streamed
        return {
            "denied": denied,
            "streamed": streamed,
            "returncode": proc.returncode,
            "output": output,
        }
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout.decode(errors="replace") if isinstance(exc.stdout, bytes) else (exc.stdout or "")
        stderr = exc.stderr.decode(errors="replace") if isinstance(exc.stderr, bytes) else (exc.stderr or "")
        output = stdout + stderr
        return {
            "denied": False,
            "streamed": "seq=" in output,
            "returncode": 124,
            "output": output,
        }


def run_once(args, run_id):
    sub, sid, jti, token, token_payload = resolve_identity(args, run_id)
    out_q = queue.Queue()
    proc = subprocess.Popen(
        client_command(args.client_binary, args.grpc_addr, args.stream_interval_ms, sub, sid, jti, token),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    thread = threading.Thread(target=reader_thread, args=(proc.stdout, out_q), daemon=True)
    thread.start()

    time.sleep(args.revoke_after_ms / 1000.0)
    revoke_ns = time.time_ns()
    receiver_status, receiver_body = send_event(args.receiver_url, sub, sid, jti, args.event_match_fields)

    first_deny_ns = None
    first_deny_source = ""
    first_deny_attempt = 0
    probe_output = ""
    probe_streamed_attempts = 0
    probe_attempts = 0
    deadline = time.time() + (args.probe_deadline_ms / 1000.0)
    while time.time() < deadline:
        probe_attempts += 1
        result = attempt_probe(
            args.client_binary,
            args.grpc_addr,
            sub,
            sid,
            jti,
            args.probe_stream_interval_ms,
            args.probe_timeout_ms,
            token,
        )
        probe_output = result["output"]
        if result["streamed"]:
            probe_streamed_attempts += 1
        if result["denied"]:
            first_deny_ns = time.time_ns()
            first_deny_attempt = probe_attempts
            if "\"source\":\"" in result["output"]:
                marker = result["output"].split("\"source\":\"", 1)[1]
                first_deny_source = marker.split("\"", 1)[0]
            break
        time.sleep(args.probe_interval_ms / 1000.0)

    alive_after_probe = proc.poll() is None
    if alive_after_probe:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=3)

    latency_ms = ""
    if first_deny_ns is not None:
        latency_ms = round((first_deny_ns - revoke_ns) / 1_000_000, 3)

    streamed_messages_after_revoke = 0
    while not out_q.empty():
        ts_ns, line = out_q.get_nowait()
        if ts_ns >= revoke_ns and "seq=" in line:
            streamed_messages_after_revoke += 1

    return {
        "mode": args.mode,
        "run_id": run_id,
        "sub": sub,
        "sid": sid,
        "jti": jti,
        "revoke_sent_ns": revoke_ns,
        "first_deny_ns": first_deny_ns or "",
        "first_deny_after_revoke_ms": latency_ms,
        "first_deny_attempt": first_deny_attempt,
        "probe_attempts": probe_attempts,
        "probe_streamed_attempts": probe_streamed_attempts,
        "active_stream_alive_after_probe": int(alive_after_probe),
        "post_revoke_stream_messages_seen": streamed_messages_after_revoke,
        "first_deny_source": first_deny_source,
        "receiver_status": receiver_status,
        "receiver_body": receiver_body,
        "probe_output": probe_output,
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
