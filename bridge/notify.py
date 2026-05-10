#!/usr/bin/env python3
"""Quick notifier: send activity to ClaudeNotch from command line.
Usage: notify.py <tool> <detail>
Example: notify.py Shell "bash build.sh"
         notify.py Edit "NotchPanelController.swift"
         notify.py Read "AppDelegate.swift"
"""
import json, os, socket, struct, sys
from pathlib import Path

SOCK = str(Path.home() / ".claude-notch" / "bridge.sock")

def main():
    tool = sys.argv[1] if len(sys.argv) > 1 else "unknown"
    detail = " ".join(sys.argv[2:]) if len(sys.argv) > 2 else ""
    if not os.path.exists(SOCK):
        return
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(2)
            s.connect(SOCK)
            msg = {"notification": {
                "hook_event_name": tool,
                "cwd": detail,
                "source": "cursor",
            }}
            payload = json.dumps(msg).encode("utf-8")
            s.sendall(struct.pack(">I", len(payload)) + payload)
            s.recv(4)
    except OSError:
        pass

if __name__ == "__main__":
    main()
