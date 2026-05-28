#!/usr/bin/env python3
"""
Cursor `stop` hook: notify ClaudeNotch when Cursor agent finishes.

stdin: {"conversation_id":"...","status":"completed","hook_event_name":"stop",...}
"""
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
        cursor_input = json.loads(raw)
    except json.JSONDecodeError:
        return 0

    cursor_input["source"] = "cursor"
    if not cursor_input.get("session_id") and cursor_input.get("conversation_id"):
        cursor_input["session_id"] = cursor_input["conversation_id"]
    cursor_input["launch_context"] = detect_launch_context("cursor")

    send_event({"stop_event": cursor_input}, "cursor_stop_hook")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
