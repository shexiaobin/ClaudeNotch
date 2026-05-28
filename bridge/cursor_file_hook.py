#!/usr/bin/env python3
"""
Cursor `afterFileEdit` hook: notify ClaudeNotch when Cursor edits a file.

stdin: {"file_path":"...","edits":[...],"hook_event_name":"afterFileEdit",...}
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

    msg = {"notification": {
        "hook_event_name": "afterFileEdit",
        "source": "cursor",
        "launch_context": detect_launch_context("cursor"),
        "file_path": cursor_input.get("file_path", ""),
        "edits_count": len(cursor_input.get("edits", [])),
    }}
    send_event(msg, "cursor_file_hook")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
