#!/usr/bin/env python3
"""Health probe for cmux-relay: TCP connect, GET /v1/health, then a WebSocket handshake.

Exit 0 only when the handshake returns 101. The bearer comes from
~/.cmuxremote/probe-token (0600), minted on first use by registering this Mac's
own Tailscale node (it never touches a phone's bearer) and never printed.
A probe from the Mac to its own Tailscale IP short-circuits through lo0: it proves
bind and accept, not tailnet reachability from another device.
Usage: relay-probe.py HOST PORT
"""
import base64
import json
import os
import socket
import sys

HOST, PORT = sys.argv[1], int(sys.argv[2])
TOKEN_FILE = os.path.expanduser("~/.cmuxremote/probe-token")
TIMEOUT = 4


def request(raw: bytes) -> bytes:
    with socket.create_connection((HOST, PORT), timeout=TIMEOUT) as s:
        s.settimeout(TIMEOUT)
        s.sendall(raw)
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        head, _, body = data.partition(b"\r\n\r\n")
        if b"content-length" in head.lower():
            want = int(next(line.split(b":")[1] for line in head.split(b"\r\n")
                            if line.lower().startswith(b"content-length")))
            while len(body) < want:
                chunk = s.recv(4096)
                if not chunk:
                    break
                body += chunk
        return head + b"\r\n\r\n" + body


def status(resp: bytes) -> int:
    return int(resp.split(b" ", 2)[1])


def get(path: str, extra: str = "") -> bytes:
    return request(f"GET {path} HTTP/1.1\r\nHost: {HOST}:{PORT}\r\n{extra}Connection: close\r\n\r\n".encode())


def mint_token() -> str:
    resp = request(f"POST /v1/devices/me/register HTTP/1.1\r\nHost: {HOST}:{PORT}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode())
    if status(resp) != 200:
        raise RuntimeError(f"register -> {status(resp)}")
    token = json.loads(resp.split(b"\r\n\r\n", 1)[1])["token"]
    fd = os.open(TOKEN_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(token)
    return token


def ws_handshake(token: str) -> int:
    key = base64.b64encode(os.urandom(16)).decode()
    return status(get("/v1/ws", f"Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
                      f"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: cmuxremote.v1, bearer.{token}\r\n"))


def main() -> int:
    if status(get("/v1/health")) != 200:
        print("health: not 200")
        return 1
    if os.path.exists(TOKEN_FILE):
        with open(TOKEN_FILE) as f:
            token = f.read().strip()
    else:
        token = mint_token()
    code = ws_handshake(token)
    if code in (401, 403) and os.path.exists(TOKEN_FILE):  # stale token: re-mint once
        code = ws_handshake(mint_token())
    print(f"ws handshake: {code}")
    return 0 if code == 101 else 1


try:
    sys.exit(main())
except (OSError, ValueError, KeyError, IndexError, RuntimeError) as e:  # refused, timeout, malformed reply
    print(f"probe failed: {type(e).__name__}: {e}")
    sys.exit(1)
