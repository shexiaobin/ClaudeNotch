#!/usr/bin/env python3
"""Codex Stop hook bridge: notify ClaudeNotch when a Codex task finishes."""
from __future__ import annotations

import json
import sys

from event_bridge import send_event
from launch_context import detect_launch_context


def main() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        return 0
    try:
        hook_input = json.loads(raw)
    except json.JSONDecodeError:
        return 0

    hook_input["source"] = "codex"
    if not hook_input.get("session_id"):
        for key in ("conversation_id", "thread_id", "turn_id"):
            if hook_input.get(key):
                hook_input["session_id"] = hook_input[key]
                break
    hook_input["launch_context"] = detect_launch_context("codex")

    send_event({"stop_event": hook_input}, "codex_stop_bridge")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
