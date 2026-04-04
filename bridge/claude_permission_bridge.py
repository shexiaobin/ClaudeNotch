#!/usr/bin/env python3
"""
Claude Code PermissionRequest hook bridge: forwards stdin JSON to ClaudeNotch via Unix socket,
blocks until the user taps Allow/Deny in the overlay, then prints hook JSON to stdout only.

Configure ~/.claude/settings.json (merge into existing "hooks"):

  "PermissionRequest": [
    {
      "matcher": ".*",
      "hooks": [
        {
          "type": "command",
          "command": "/ABSOLUTE/PATH/TO/bridge/claude_permission_bridge.py"
        }
      ]
    }
  ]

Env:
  CLAUDE_NOTCH_SOCKET — socket path (default: ~/.claude-notch/bridge.sock)

If ClaudeNotch is not running: exits 1 so Claude falls back to the normal terminal permission UI
(non-blocking hook error; see Claude Code hooks docs).
"""
from __future__ import annotations

import json
import os
import socket
import struct
import sys
from pathlib import Path

DEFAULT_REL = Path.home() / ".claude-notch" / "bridge.sock"
TIMEOUT_SEC = 600.0


def socket_path() -> str:
    return os.environ.get("CLAUDE_NOTCH_SOCKET", str(DEFAULT_REL))


def framed_send_recv(sock: socket.socket, obj: dict) -> dict:
    payload = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    sock.sendall(struct.pack(">I", len(payload)) + payload)
    hdr = _recv_exact(sock, 4)
    (n,) = struct.unpack(">I", hdr)
    body = _recv_exact(sock, n)
    return json.loads(body.decode("utf-8"))


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    parts: list[bytes] = []
    got = 0
    while got < n:
        chunk = sock.recv(n - got)
        if not chunk:
            raise OSError("socket closed")
        parts.append(chunk)
        got += len(chunk)
    return b"".join(parts)


def main() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        print(
            "claude_permission_bridge: empty stdin",
            file=sys.stderr,
        )
        return 1
    try:
        hook_input = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"claude_permission_bridge: invalid JSON stdin: {e}", file=sys.stderr)
        return 1

    path = socket_path()
    if not os.path.exists(path):
        print(
            f"claude_permission_bridge: socket missing ({path}). Start ClaudeNotch first.",
            file=sys.stderr,
        )
        return 1

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(TIMEOUT_SEC)
            s.connect(path)
            reply = framed_send_recv(s, {"hook_input": hook_input})
    except OSError as e:
        print(f"claude_permission_bridge: {e}", file=sys.stderr)
        return 1

    behavior = reply.get("behavior", "deny")
    if behavior not in ("allow", "deny"):
        print(
            f"claude_permission_bridge: invalid behavior {behavior!r}",
            file=sys.stderr,
        )
        return 1

    decision: dict = {"behavior": behavior}
    if behavior == "deny":
        msg = reply.get("message")
        if msg:
            decision["message"] = msg

    out = {
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": decision,
        }
    }
    sys.stdout.write(json.dumps(out, ensure_ascii=False))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
