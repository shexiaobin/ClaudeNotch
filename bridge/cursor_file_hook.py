#!/usr/bin/env python3
"""
Cursor `afterFileEdit` hook: notify ClaudeNotch when Cursor edits a file.

stdin: {"file_path":"...","edits":[...],"hook_event_name":"afterFileEdit",...}
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
        return 0
    try:
        cursor_input = json.loads(raw)
    except json.JSONDecodeError:
        return 0

    path = sock_path()
    if not os.path.exists(path):
        return 0

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(5.0)
            s.connect(path)
            msg = {"notification": {
                "hook_event_name": "afterFileEdit",
                "source": "cursor",
                "launch_context": detect_launch_context("cursor"),
                "file_path": cursor_input.get("file_path", ""),
                "edits_count": len(cursor_input.get("edits", [])),
            }}
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
