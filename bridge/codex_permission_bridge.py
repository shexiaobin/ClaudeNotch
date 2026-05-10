#!/usr/bin/env python3
"""Codex PermissionRequest hook bridge.

Codex currently accepts the same hook stdout shape as Claude Code. This wrapper
adds a `source=codex` marker before forwarding to ClaudeNotch so the Swift UI can
display the right source badge and session state.
"""
from __future__ import annotations

import json
import os
import socket
import sys

from claude_permission_bridge import TIMEOUT_SEC, framed_send_recv, socket_path
from launch_context import detect_launch_context


def main() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        print("codex_permission_bridge: empty stdin", file=sys.stderr)
        return 1
    try:
        hook_input = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"codex_permission_bridge: invalid JSON stdin: {e}", file=sys.stderr)
        return 1

    hook_input["source"] = "codex"
    hook_input["launch_context"] = detect_launch_context("codex")

    path = socket_path()
    if not os.path.exists(path):
        print(
            f"codex_permission_bridge: socket missing ({path}). Start ClaudeNotch first.",
            file=sys.stderr,
        )
        return 1

    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(TIMEOUT_SEC)
            s.connect(path)
            reply = framed_send_recv(s, {"hook_input": hook_input})
    except OSError as e:
        print(f"codex_permission_bridge: {e}", file=sys.stderr)
        return 1

    behavior = reply.get("behavior", "deny")
    if behavior not in ("allow", "deny"):
        print(f"codex_permission_bridge: invalid behavior {behavior!r}", file=sys.stderr)
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
