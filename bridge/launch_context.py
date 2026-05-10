#!/usr/bin/env python3
"""Best-effort launch context detection for agent hooks.

The value is internal to ClaudeNotch. Host tools still receive their original
hook stdout contract; this marker only helps the Swift UI choose the right app
to activate from completion banners.
"""
from __future__ import annotations

import os
import subprocess

VALID_CONTEXTS = {"app", "terminal", "unknown"}

TERMINAL_MARKERS = (
    "Terminal.app",
    "iTerm.app",
    "iTerm2.app",
    "Warp.app",
    "Ghostty.app",
    "kitty.app",
    "Alacritty.app",
    "/Terminal",
    "/iTerm",
    "/Warp",
    "/ghostty",
    "/kitty",
    "/alacritty",
)

APP_MARKERS = {
    "codex": (
        "Codex.app",
        "com.openai.codex",
        "/Codex",
    ),
    "cursor": (
        "Cursor.app",
        "com.todesktop.230313mzl4w4u92",
        "/Cursor",
    ),
}


def detect_launch_context(agent: str) -> str:
    override = os.environ.get(f"CLAUDE_NOTCH_{agent.upper()}_TARGET")
    if override:
        normalized = override.strip().lower()
        if normalized in VALID_CONTEXTS:
            return normalized

    chain = "\n".join(_parent_process_chain())
    app_markers = APP_MARKERS.get(agent.lower(), ())
    if any(marker in chain for marker in app_markers):
        return "app"
    if any(marker in chain for marker in TERMINAL_MARKERS):
        return "terminal"
    return "unknown"


def _parent_process_chain(limit: int = 12) -> list[str]:
    rows: list[str] = []
    pid = os.getppid()
    for _ in range(limit):
        if pid <= 1:
            break
        try:
            out = subprocess.check_output(
                ["ps", "-o", "ppid=", "-o", "command=", "-p", str(pid)],
                text=True,
                stderr=subprocess.DEVNULL,
            ).strip()
        except (OSError, subprocess.SubprocessError):
            break
        if not out:
            break
        rows.append(out)
        parts = out.split(maxsplit=1)
        try:
            pid = int(parts[0])
        except (ValueError, IndexError):
            break
    return rows
