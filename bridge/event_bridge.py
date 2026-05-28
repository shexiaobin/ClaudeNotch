#!/usr/bin/env python3
"""Shared helpers for non-blocking ClaudeNotch event bridges."""
from __future__ import annotations

import json
import os
import socket
import struct
import sys
from pathlib import Path
from typing import Any

DEFAULT_SOCK = Path.home() / ".claude-notch" / "bridge.sock"


def socket_path() -> str:
    return os.environ.get("CLAUDE_NOTCH_SOCKET", str(DEFAULT_SOCK))


def debug_enabled() -> bool:
    return os.environ.get("CLAUDE_NOTCH_BRIDGE_DEBUG", "").lower() in {"1", "true", "yes", "on"}


def debug(message: str) -> None:
    if debug_enabled():
        print(message, file=sys.stderr)


def send_event(message: dict[str, Any], label: str, timeout: float = 5.0) -> None:
    path = socket_path()
    if not os.path.exists(path):
        debug(f"{label}: socket missing ({path})")
        return

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(timeout)
            s.connect(path)
            payload = json.dumps(message, ensure_ascii=False).encode("utf-8")
            s.sendall(struct.pack(">I", len(payload)) + payload)
            hdr = s.recv(4)
            if len(hdr) == 4:
                (n,) = struct.unpack(">I", hdr)
                s.recv(n)
    except OSError as exc:
        debug(f"{label}: {exc}")
