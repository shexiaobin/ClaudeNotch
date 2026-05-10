#!/usr/bin/env python3
"""
Cursor `beforeShellExecution` hook: forwards to ClaudeNotch for GUI approval.

Cursor stdin:
  {"conversation_id":"...","command":"git push","hook_event_name":"beforeShellExecution",...}

Cursor expected stdout (JSON):
  {"permission":"allow"} or {"permission":"deny","agentMessage":"..."}

If ClaudeNotch is not running: prints {"permission":"allow"} so Cursor falls through to
its own UI (no blocking).
"""
from __future__ import annotations

import json
import os
import socket
import struct
import sys
from pathlib import Path

from launch_context import detect_launch_context

DEFAULT_SOCK = Path.home() / ".claude-notch" / "bridge.sock"


def sock_path() -> str:
    return os.environ.get("CLAUDE_NOTCH_SOCKET", str(DEFAULT_SOCK))


def main() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        fallback_allow()
        return 0

    try:
        cursor_input = json.loads(raw)
    except json.JSONDecodeError:
        fallback_allow()
        return 0

    path = sock_path()
    if not os.path.exists(path):
        fallback_allow()
        return 0

    hook_input = {
        "session_id": cursor_input.get("conversation_id", ""),
        "cwd": cursor_input.get("workspace_roots", ["/"])[0] if cursor_input.get("workspace_roots") else "/",
        "source": "cursor",
        "launch_context": detect_launch_context("cursor"),
        "hook_event_name": "PermissionRequest",
        "tool_name": "Bash",
        "tool_input": {
            "command": cursor_input.get("command", ""),
            "description": "Cursor shell execution",
        },
    }

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(600.0)
            s.connect(path)
            payload = json.dumps({"hook_input": hook_input}, ensure_ascii=False).encode("utf-8")
            s.sendall(struct.pack(">I", len(payload)) + payload)
            hdr = _recv_exact(s, 4)
            (n,) = struct.unpack(">I", hdr)
            body = _recv_exact(s, n)
            reply = json.loads(body.decode("utf-8"))
    except OSError:
        fallback_allow()
        return 0

    behavior = reply.get("behavior", "deny")
    if behavior == "allow":
        out = {"permission": "allow"}
    else:
        out = {"permission": "deny", "agentMessage": reply.get("message", "Denied by ClaudeNotch")}

    sys.stdout.write(json.dumps(out, ensure_ascii=False))
    sys.stdout.flush()
    return 0


def _recv_exact(s: socket.socket, n: int) -> bytes:
    parts: list[bytes] = []
    got = 0
    while got < n:
        chunk = s.recv(n - got)
        if not chunk:
            raise OSError("socket closed")
        parts.append(chunk)
        got += len(chunk)
    return b"".join(parts)


def fallback_allow():
    sys.stdout.write('{"permission":"allow"}')
    sys.stdout.flush()


if __name__ == "__main__":
    raise SystemExit(main())
