#!/usr/bin/env python3
"""
Claude Code Notification hook bridge: forwards notification events to ClaudeNotch.

This hook fires when Claude needs input, finishes a task, or requires auth.
We send it to the ClaudeNotch app so it can update the idle pill or show alerts.

Configure in ~/.claude/settings.json:
  "Notification": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "/ABSOLUTE/PATH/bridge/claude_notification_bridge.py"
        }
      ]
    }
  ]
"""
from __future__ import annotations

import json
import sys

from event_bridge import send_event


def main() -> int:
    raw = sys.stdin.read()
    if not raw.strip():
        return 0
    try:
        hook_input = json.loads(raw)
    except json.JSONDecodeError:
        return 0

    send_event({"notification": hook_input}, "claude_notification_bridge")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
