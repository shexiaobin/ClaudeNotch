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
from pathlib import Path
from typing import Any

from claude_permission_bridge import TIMEOUT_SEC, framed_send_recv, socket_path
from launch_context import detect_launch_context


BACKGROUND_MARKERS = (
    "ambient suggestion",
    "ambient-suggestions",
    "classify codex ambient",
    "analytics-default-enabled",
    "background suggestion",
)

BACKGROUND_BOOLEAN_KEYS = (
    "ambient",
    "background",
    "is_ambient",
    "is_background",
    "is_background_task",
)


def _allow_output() -> str:
    return json.dumps(
        {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": {"behavior": "allow"},
            }
        },
        ensure_ascii=False,
    )


def _payload_text(value: Any) -> str:
    try:
        return json.dumps(value, ensure_ascii=False, sort_keys=True).lower()
    except TypeError:
        return str(value).lower()


def _tool_name(hook_input: dict[str, Any]) -> str:
    return str(
        hook_input.get("tool_name")
        or hook_input.get("tool")
        or hook_input.get("toolName")
        or ""
    )


def _cwd(hook_input: dict[str, Any]) -> str:
    return str(
        hook_input.get("cwd")
        or hook_input.get("working_directory")
        or hook_input.get("workingDirectory")
        or ""
    )


def is_background_permission(hook_input: dict[str, Any]) -> bool:
    """Return True for Codex app background requests that should not interrupt.

    Codex Desktop can run ambient suggestions and analytics-adjacent background
    turns through the same PermissionRequest hook as user-visible work. The
    hook payload does not currently expose one stable "background" flag, so
    this keeps the filter intentionally narrow and explainable.
    """
    if os.environ.get("CLAUDE_NOTCH_CODEX_BACKGROUND_FILTER", "1") in {"0", "false", "False"}:
        return False

    if hook_input.get("launch_context") != "app":
        return False

    for key in BACKGROUND_BOOLEAN_KEYS:
        if hook_input.get(key) is True:
            return True

    text = _payload_text(hook_input)
    if any(marker in text for marker in BACKGROUND_MARKERS):
        return True

    cwd = _cwd(hook_input)
    tool = _tool_name(hook_input)
    home = str(Path.home())
    if cwd == "/" and tool.startswith("mcp__codex_apps__"):
        return True
    if cwd.startswith(f"{home}/.codex/ambient-suggestions"):
        return True

    return False


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

    if is_background_permission(hook_input):
        print(
            "codex_permission_bridge: allowed background Codex request without UI",
            file=sys.stderr,
        )
        sys.stdout.write(_allow_output())
        sys.stdout.flush()
        return 0

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
