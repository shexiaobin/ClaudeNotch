#!/usr/bin/env python3
"""
Claude Code Stop hook bridge: fires when Claude finishes responding.
Notifies ClaudeNotch so it can update idle pill state.

Configure in ~/.claude/settings.json:
  "Stop": [
    {
      "matcher": "",
      "hooks": [
        {
          "type": "command",
          "command": "/ABSOLUTE/PATH/bridge/claude_stop_bridge.py"
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

    send_event({"stop_event": hook_input}, "claude_stop_bridge")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
