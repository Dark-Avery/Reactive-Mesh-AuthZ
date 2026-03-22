from __future__ import annotations

import base64
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
import subprocess
import time
import urllib.parse
import uuid


ISSUER = os.environ.get("DEMO_IDP_ISSUER", "http://demo-idp:8080/realms/reactive-mesh")
REALM = os.environ.get("DEMO_IDP_REALM", "reactive-mesh")
CLIENT_ID = os.environ.get("DEMO_IDP_CLIENT_ID", "reactive-mesh-cli")
TOKEN_TTL_SECONDS = int(os.environ.get("DEMO_IDP_TOKEN_TTL_SECONDS", "600"))

PRIVATE_KEY_PEM = """-----BEGIN PRIVATE KEY-----
MIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDCVVuUQkPwqXPm
H7R0nbUhIk2rWC8w4ODJlfRBI9HP/CEGUvRK5j9lbpWKomluzQN0PS8Dhr5VDw+R
EdVZfv8ZqKa3PebA64c4ys7ZTVV09PNE7DbpYl402ef1jtQTDKmcP4dHWdO4Gfit
tglAws0nS9V4zVW+qN46/LDhCEyh1tiALi4aHdU+PfE0vwSNRSA3Chf/ZBIGXnMe
Sbc26GYXhRRkzww4vGHYTutFI7ma9f53Mn+jT1EQIQpDIG+8jvluowijwSCjPXwD
zIvGwMspm47lGvtLD3yy4pJbErM5NtJXU5WagGnqDX58ok4ARLnhMt6zTOK1oYxK
6/MAmMJ5AgMBAAECggEAFdYh0t5h1D10QaHjJP3yJBGe1N+1OMqyE5DDKB0qZrKj
8toYK4DlE4SaLuBqVLoaduGnol+uDDCDrSdJ+BMcPuG7rwg4gUnN8WCfnt0Q2tIp
8j8ROgcUwx9PsGDu3V+dQOqGDMtQDiYz8nALqOBizVU4/Oikx4Zh51Ks3PJx6vbf
TyLPAipH2I8EAXtA0gcbqg7l5QXorsHSRMFRyX+M/RiFKVHNhiB9AxWGfpKe1isp
plhQvsyBmw2ACLZJFHL9k6nKeEXXcSCknz4wpamR4Jju3WYYk6EVvuBt+KRxEWpT
zadoq3ThRxe22xThpUGkFl9iGyKpagU7dJSaR8434QKBgQDgnAVWsTx+PugcxkaI
Tw4l++sP7k0Ze5wSc5C2kI7eRGEqXnwGIkQ88Lbqb/iiIK5HGYPm+r/LZYLSZoD7
9LZVCe1/+OBDE7T54kQ+fVwgIOAEw01hni8L/M+5GBkYrP+UV+ixXRpScpyRktt2
mvpDIfZocTghFVC8f8tzhYFd2QKBgQDdfiJlhJXII7uUSPPFXKFxCW30QkTdNCjs
cCTME7CS05ijyXs8s/1Cp7Br7zlAjIbGMk2d+kId3bdV/V4H7JsWu4+JmF6FuVmu
smoOtaI7coX6x3NmR2SoUPENGYFxJlm1/fM63808AgZLspYbzx4EFJOKO7XKW8VO
4GeAjHOFoQKBgQDdNozDfzeXFxnADT+2TDYhDuXKAOeKa4WhXpRuWh17p1kTQ49e
8yzF4EYmyzTTaOB8QhL40IlJJ6ca1b2/aJqTUn3JBjLJnYUmfsS7zveG5Rn9VuTF
eefYJJvpLmS5OtlVHuecl5evEBZIAZ2ISMami7KF1sxzOO0VWb/k/N4WsQKBgFRC
Ho2l8WDQjxQq6GklAtlAcA6igxXvOL4xLx5fQyWnzwJHrFT8V5Tau9djitEOZFrT
WgmF4U8BQDQ7DWFQVfNA6Kq8RwDx8Lbvcj8kQ5H/0A4Ff9XhxN3u5LRKBp7nqur7
r2KvLqDsWD7FsirkEJQWy8WjT1WqsZV+8oDJbUzhAoGBAIxhRivaP7xTJegq/BPJ
1MmvIDIwNX0OyVC/MzF56TtUoy0lOn0IHAJXqrsat1Wqs6joU4Q83jNecEVcpfN2
wwGL3WCzpwm8DofWRpZimJR9dn4Wp/EsqC60YAFipnF7HaZmG9CjQaHqz6tGJdws
ZaFYM2l30VJAwludVS9N7wXL
-----END PRIVATE KEY-----
"""

PUBLIC_JWK = {
    "kty": "RSA",
    "use": "sig",
    "alg": "RS256",
    "kid": "demo-idp-key-1",
    "n": "wlVblEJD8Klz5h-0dJ21ISJNq1gvMODgyZX0QSPRz_whBlL0SuY_ZW6ViqJpbs0DdD0vA4a-VQ8PkRHVWX7_Gaimtz3mwOuHOMrO2U1VdPTzROw26WJeNNnn9Y7UEwypnD-HR1nTuBn4rbYJQMLNJ0vVeM1VvqjeOvyw4QhModbYgC4uGh3VPj3xNL8EjUUgNwoX_2QSBl5zHkm3NuhmF4UUZM8MOLxh2E7rRSO5mvX-dzJ_o09RECEKQyBvvI75bqMIo8Egoz18A8yLxsDLKZuO5Rr7Sw98suKSWxKzOTbSV1OVmoBp6g1-fKJOAES54TLes0zitaGMSuvzAJjCeQ",
    "e": "AQAB",
}

USERS = {
    "alice": {
        "password": "alice-pass",
        "sub": "user-alice",
        "email": "alice@example.local",
        "name": "Alice",
    },
    "bob": {
        "password": "bob-pass",
        "sub": "user-bob",
        "email": "bob@example.local",
        "name": "Bob",
    },
}

PRIVATE_KEY_PATH = "/tmp/demo-idp-private.pem"


def b64url_encode(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def sign_rs256(message: bytes) -> bytes:
    result = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", PRIVATE_KEY_PATH],
        input=message,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return result.stdout


def build_access_token(username: str, client_id: str) -> str:
    user = USERS[username]
    now = int(time.time())
    payload = {
        "iss": ISSUER,
        "sub": f"{user['sub']}-{uuid.uuid4()}",
        "aud": client_id,
        "azp": client_id,
        "preferred_username": username,
        "email": user["email"],
        "name": user["name"],
        "scope": "openid profile email",
        "iat": now,
        "nbf": now,
        "exp": now + TOKEN_TTL_SECONDS,
        "auth_time": now,
        "sid": str(uuid.uuid4()),
        "jti": str(uuid.uuid4()),
    }
    header = {"alg": "RS256", "typ": "JWT", "kid": PUBLIC_JWK["kid"]}
    signing_input = (
        f"{b64url_encode(json.dumps(header, separators=(',', ':')).encode())}."
        f"{b64url_encode(json.dumps(payload, separators=(',', ':')).encode())}"
    ).encode()
    signature = b64url_encode(sign_rs256(signing_input))
    return f"{signing_input.decode()}.{signature}"


class Handler(BaseHTTPRequestHandler):
    server_version = "demo-idp/1.0"

    def _write_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/healthz":
            self._write_json(200, {"status": "ok"})
            return
        if self.path == f"/realms/{REALM}":
            self._write_json(200, {"realm": REALM, "issuer": ISSUER})
            return
        if self.path == f"/realms/{REALM}/.well-known/openid-configuration":
            self._write_json(
                200,
                {
                    "issuer": ISSUER,
                    "jwks_uri": f"{ISSUER}/protocol/openid-connect/certs",
                    "token_endpoint": f"{ISSUER}/protocol/openid-connect/token",
                    "grant_types_supported": ["password"],
                    "token_endpoint_auth_methods_supported": ["none"],
                },
            )
            return
        if self.path == f"/realms/{REALM}/protocol/openid-connect/certs":
            self._write_json(200, {"keys": [PUBLIC_JWK]})
            return
        self._write_json(404, {"error": "not_found"})

    def do_POST(self) -> None:
        if self.path != f"/realms/{REALM}/protocol/openid-connect/token":
            self._write_json(404, {"error": "not_found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode()
        form = urllib.parse.parse_qs(raw, keep_blank_values=True)
        grant_type = form.get("grant_type", [""])[0]
        client_id = form.get("client_id", [CLIENT_ID])[0]
        username = form.get("username", [""])[0]
        password = form.get("password", [""])[0]

        if grant_type != "password":
            self._write_json(400, {"error": "unsupported_grant_type"})
            return
        if username not in USERS or USERS[username]["password"] != password:
            self._write_json(401, {"error": "invalid_grant"})
            return

        access_token = build_access_token(username, client_id)
        self._write_json(
            200,
            {
                "access_token": access_token,
                "expires_in": TOKEN_TTL_SECONDS,
                "refresh_expires_in": 0,
                "refresh_token": "",
                "token_type": "Bearer",
                "not-before-policy": 0,
                "scope": "openid profile email",
            },
        )


if __name__ == "__main__":
    with open(PRIVATE_KEY_PATH, "w", encoding="utf-8") as f:
        f.write(PRIVATE_KEY_PEM)
    server = HTTPServer(("0.0.0.0", 8080), Handler)
    server.serve_forever()
