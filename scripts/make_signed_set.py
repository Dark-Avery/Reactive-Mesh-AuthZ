#!/usr/bin/env python3
import argparse
import base64
import hashlib
import hmac
import json
import sys


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def parse_args():
    p = argparse.ArgumentParser(description="Create a compact HS256-signed SET/JWS for the receiver")
    p.add_argument("--secret", required=True)
    p.add_argument("--event-type", required=True, choices=["session-revoked", "risk-deny"])
    p.add_argument("--sub", default="")
    p.add_argument("--sid", default="")
    p.add_argument("--jti", default="")
    p.add_argument("--event-id", default="")
    p.add_argument("--reason", default="signed-test")
    p.add_argument("--ts", default="")
    return p.parse_args()


def main():
    args = parse_args()
    header = {"alg": "HS256", "typ": "secevent+jwt"}
    payload = {
        "event_type": args.event_type,
        "sub": args.sub,
        "sid": args.sid,
        "jti": args.jti,
        "reason": args.reason,
    }
    if args.event_id:
        payload["event_id"] = args.event_id
    if args.ts:
        payload["ts"] = args.ts

    header_part = b64url(json.dumps(header, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))
    payload_part = b64url(json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))
    signing_input = f"{header_part}.{payload_part}".encode("ascii")
    signature = hmac.new(args.secret.encode("utf-8"), signing_input, hashlib.sha256).digest()
    token = f"{header_part}.{payload_part}.{b64url(signature)}"
    sys.stdout.write(token)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
