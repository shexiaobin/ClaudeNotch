#!/usr/bin/env python3
"""Mock Unix socket server + run claude_permission_bridge.py (no Swift required)."""
from __future__ import annotations

import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

BRIDGE = Path(__file__).resolve().parent / "claude_permission_bridge.py"


def read_framed(conn: socket.socket) -> dict:
    hdr = conn.recv(4)
    (n,) = struct.unpack(">I", hdr)
    body = b""
    while len(body) < n:
        body += conn.recv(n - len(body))
    return json.loads(body.decode("utf-8"))


def write_framed(conn: socket.socket, obj: dict) -> None:
    payload = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    conn.sendall(struct.pack(">I", len(payload)) + payload)


def main() -> int:
    hook_sample = {
        "session_id": "test",
        "cwd": "/tmp",
        "hook_event_name": "PermissionRequest",
        "tool_name": "Bash",
        "tool_input": {"command": "echo hi"},
    }
    sock_path = tempfile.NamedTemporaryFile(delete=False).name
    os.unlink(sock_path)

    ready = threading.Event()

    def server() -> None:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(sock_path)
        s.listen(1)
        ready.set()
        conn, _ = s.accept()
        try:
            got = read_framed(conn)
            assert "hook_input" in got
            write_framed(conn, {"behavior": "allow"})
        finally:
            conn.close()
            s.close()
            try:
                os.unlink(sock_path)
            except OSError:
                pass

    t = threading.Thread(target=server, daemon=True)
    t.start()
    assert ready.wait(timeout=2.0)

    env = {**os.environ, "CLAUDE_NOTCH_SOCKET": sock_path}
    r = subprocess.run(
        [sys.executable, str(BRIDGE)],
        input=json.dumps(hook_sample),
        capture_output=True,
        text=True,
        env=env,
        timeout=10,
    )
    if r.returncode != 0:
        print("bridge stderr:", r.stderr, file=sys.stderr)
        return r.returncode
    out = json.loads(r.stdout)
    assert out["hookSpecificOutput"]["hookEventName"] == "PermissionRequest"
    assert out["hookSpecificOutput"]["decision"]["behavior"] == "allow"
    print("OK: bridge + mock socket → Claude hook JSON valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
