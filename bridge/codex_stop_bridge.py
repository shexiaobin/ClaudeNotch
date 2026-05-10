#!/usr/bin/env python3
"""Codex Stop hook bridge: notify ClaudeNotch when a Codex task finishes."""
from __future__ import annotations

import json
import os
import socket
import struct
import sys
from pathlib import Path

DEFAULT_REL = Path.home() / ".claude-notch" / "bridge.sock"


def socket_path() -> str:
    return os.environ.get("CLAUDE_NOTCH_SOCKET", str(DEFAULT_REL))


def main() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        return 0
    try:
        hook_input = json.loads(raw)
    except json.JSONDecodeError:
        return 0

    hook_input["source"] = "codex"

    path = socket_path()
    if not os.path.exists(path):
        return 0

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(5.0)
            s.connect(path)
            msg = {"stop_event": hook_input}
            payload = json.dumps(msg, ensure_ascii=False).encode("utf-8")
            s.sendall(struct.pack(">I", len(payload)) + payload)
            hdr = s.recv(4)
            if len(hdr) == 4:
                (n,) = struct.unpack(">I", hdr)
                s.recv(n)
    except OSError:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
