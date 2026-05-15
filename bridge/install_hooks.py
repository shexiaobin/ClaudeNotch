#!/usr/bin/env python3
"""Install and diagnose ClaudeNotch hooks for Claude Code, Cursor, and Codex."""
from __future__ import annotations

import argparse
import json
import os
import socket
import sys
from pathlib import Path
from typing import Any

CLAUDE_MANAGED = {
    "claude_permission_bridge.py",
    "claude_notification_bridge.py",
    "claude_stop_bridge.py",
}
CURSOR_MANAGED = {
    "cursor_shell_hook.py",
    "cursor_file_hook.py",
    "cursor_stop_hook.py",
}
CODEX_MANAGED = {
    "codex_permission_bridge.py",
    "codex_stop_bridge.py",
    "claude_permission_bridge.py",
    "claude_stop_bridge.py",
}

REQUIRED_BRIDGE = sorted(
    CLAUDE_MANAGED
    | CURSOR_MANAGED
    | {"codex_permission_bridge.py", "codex_stop_bridge.py", "install_hooks.py", "launch_context.py"}
)


def infer_bridge() -> Path:
    return Path(__file__).resolve().parent


def default_home() -> Path:
    return Path.home()


def default_socket(home: Path) -> Path:
    return Path(os.environ.get("CLAUDE_NOTCH_SOCKET", str(home / ".claude-notch" / "bridge.sock")))


def read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        with path.open() as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def command_basename(command: str) -> str:
    return Path(command).name


def is_managed_command(command: str, managed_names: set[str]) -> bool:
    return command_basename(command) in managed_names


def nested_commands(item: Any) -> list[str]:
    if not isinstance(item, dict):
        return []
    nested = item.get("hooks")
    if not isinstance(nested, list):
        return []
    return [
        h.get("command", "")
        for h in nested
        if isinstance(h, dict) and isinstance(h.get("command"), str)
    ]


def repair_claude(home: Path, bridge: Path) -> None:
    path = home / ".claude" / "settings.json"
    cfg = read_json(path)
    hooks = cfg.setdefault("hooks", {})

    def merge(event: str, entry: dict[str, Any]) -> None:
        existing = hooks.get(event, [])
        if not isinstance(existing, list):
            existing = []
        kept = [
            item
            for item in existing
            if not any(is_managed_command(command, CLAUDE_MANAGED) for command in nested_commands(item))
        ]
        kept.append(entry)
        hooks[event] = kept

    merge("PermissionRequest", {"matcher": ".*", "hooks": [
        {"type": "command", "command": str(bridge / "claude_permission_bridge.py")}
    ]})
    merge("Notification", {"matcher": "", "hooks": [
        {"type": "command", "command": str(bridge / "claude_notification_bridge.py")}
    ]})
    merge("Stop", {"matcher": "", "hooks": [
        {"type": "command", "command": str(bridge / "claude_stop_bridge.py")}
    ]})
    write_json(path, cfg)


def repair_cursor(home: Path, bridge: Path) -> None:
    path = home / ".cursor" / "hooks.json"
    cfg = read_json(path)
    cfg.setdefault("version", 1)
    hooks = cfg.setdefault("hooks", {})

    def merge(event: str, command: str) -> None:
        existing = hooks.get(event, [])
        if not isinstance(existing, list):
            existing = []
        kept = []
        for item in existing:
            item_command = item.get("command") if isinstance(item, dict) else None
            if isinstance(item_command, str) and is_managed_command(item_command, CURSOR_MANAGED):
                continue
            kept.append(item)
        kept.append({"command": command})
        hooks[event] = kept

    merge("beforeShellExecution", str(bridge / "cursor_shell_hook.py"))
    merge("afterFileEdit", str(bridge / "cursor_file_hook.py"))
    merge("stop", str(bridge / "cursor_stop_hook.py"))
    write_json(path, cfg)


def repair_codex(home: Path, bridge: Path) -> None:
    path = home / ".codex" / "hooks.json"
    cfg = read_json(path)
    hooks = cfg.setdefault("hooks", {})

    def merge(event: str, entry: dict[str, Any]) -> None:
        existing = hooks.get(event, [])
        if not isinstance(existing, list):
            existing = []
        kept = [
            item
            for item in existing
            if not any(is_managed_command(command, CODEX_MANAGED) for command in nested_commands(item))
        ]
        kept.append(entry)
        hooks[event] = kept

    merge("PermissionRequest", {"matcher": ".*", "hooks": [
        {"type": "command", "command": str(bridge / "codex_permission_bridge.py")}
    ]})
    merge("Stop", {"hooks": [
        {"type": "command", "command": str(bridge / "codex_stop_bridge.py")}
    ]})
    write_json(path, cfg)


def repair_all(home: Path, bridge: Path) -> None:
    repair_claude(home, bridge)
    repair_cursor(home, bridge)
    repair_codex(home, bridge)
    for script in bridge.glob("*.py"):
        try:
            script.chmod(script.stat().st_mode | 0o111)
        except OSError:
            pass


def diagnose(home: Path, bridge: Path, socket_path: Path, check_socket: bool = True) -> dict[str, Any]:
    expected = expected_commands(bridge)
    result: dict[str, Any] = {
        "bridge": str(bridge),
        "python": sys.executable,
        "socket": {
            "path": str(socket_path),
            "checked": check_socket,
            "exists": socket_path.exists(),
            "connectable": socket_connectable(socket_path) if check_socket else False,
        },
        "bridge_files": {},
        "tools": {},
    }
    for name in REQUIRED_BRIDGE:
        path = bridge / name
        result["bridge_files"][name] = {
            "exists": path.exists(),
            "executable": os.access(path, os.X_OK),
        }

    result["tools"]["claude"] = diagnose_nested(
        home / ".claude" / "settings.json",
        {
            "PermissionRequest": expected["claude_permission_bridge.py"],
            "Notification": expected["claude_notification_bridge.py"],
            "Stop": expected["claude_stop_bridge.py"],
        },
        CLAUDE_MANAGED,
    )
    result["tools"]["cursor"] = diagnose_flat(
        home / ".cursor" / "hooks.json",
        {
            "beforeShellExecution": expected["cursor_shell_hook.py"],
            "afterFileEdit": expected["cursor_file_hook.py"],
            "stop": expected["cursor_stop_hook.py"],
        },
        CURSOR_MANAGED,
    )
    result["tools"]["codex"] = diagnose_nested(
        home / ".codex" / "hooks.json",
        {
            "PermissionRequest": expected["codex_permission_bridge.py"],
            "Stop": expected["codex_stop_bridge.py"],
        },
        CODEX_MANAGED,
    )

    ok = all(info["exists"] for info in result["bridge_files"].values())
    if check_socket:
        ok = ok and result["socket"]["exists"]
    ok = ok and all(tool["ok"] for tool in result["tools"].values())
    result["ok"] = ok
    return result


def expected_commands(bridge: Path) -> dict[str, str]:
    return {name: str(bridge / name) for name in REQUIRED_BRIDGE}


def diagnose_nested(path: Path, expected: dict[str, str], managed_names: set[str]) -> dict[str, Any]:
    cfg = read_json(path)
    hooks = cfg.get("hooks", {}) if isinstance(cfg.get("hooks"), dict) else {}
    issues: list[str] = []
    actual: dict[str, list[str]] = {}
    for event, command in expected.items():
        items = hooks.get(event, [])
        if not isinstance(items, list):
            issues.append(f"{event}: invalid hook list")
            items = []
        commands = [cmd for item in items for cmd in nested_commands(item)]
        actual[event] = commands
        if command not in commands:
            issues.append(f"{event}: missing {command}")
        for cmd in commands:
            if is_managed_command(cmd, managed_names) and cmd != command:
                issues.append(f"{event}: stale path {cmd}")
    return {"path": str(path), "ok": not issues, "issues": issues, "commands": actual}


def diagnose_flat(path: Path, expected: dict[str, str], managed_names: set[str]) -> dict[str, Any]:
    cfg = read_json(path)
    hooks = cfg.get("hooks", {}) if isinstance(cfg.get("hooks"), dict) else {}
    issues: list[str] = []
    actual: dict[str, list[str]] = {}
    for event, command in expected.items():
        items = hooks.get(event, [])
        if not isinstance(items, list):
            issues.append(f"{event}: invalid hook list")
            items = []
        commands = [
            item.get("command", "")
            for item in items
            if isinstance(item, dict) and isinstance(item.get("command"), str)
        ]
        actual[event] = commands
        if command not in commands:
            issues.append(f"{event}: missing {command}")
        for cmd in commands:
            if is_managed_command(cmd, managed_names) and cmd != command:
                issues.append(f"{event}: stale path {cmd}")
    return {"path": str(path), "ok": not issues, "issues": issues, "commands": actual}


def socket_connectable(path: Path) -> bool:
    if not path.exists():
        return False
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(0.2)
            s.connect(str(path))
        return True
    except OSError:
        return False


def render_text(report: dict[str, Any]) -> str:
    lines = ["ClaudeNotch Diagnostics", ""]
    lines.append(f"Bridge: {report['bridge']}")
    lines.append(f"Python: {report['python']}")
    socket_info = report["socket"]
    if not socket_info["checked"]:
        socket_status = "SKIPPED"
    elif socket_info["exists"]:
        socket_status = "OK"
    else:
        socket_status = "MISSING"
    if socket_info["checked"] and socket_info["exists"] and not socket_info["connectable"]:
        socket_status = "PRESENT, NOT CONNECTABLE"
    lines.append(f"Socket: {socket_status} ({socket_info['path']})")
    lines.append("")

    missing = [name for name, info in report["bridge_files"].items() if not info["exists"]]
    if missing:
        lines.append("Bridge files: MISSING " + ", ".join(missing))
    else:
        lines.append("Bridge files: OK")

    for name, tool in report["tools"].items():
        lines.append("")
        lines.append(f"{name.title()}: {'OK' if tool['ok'] else 'NEEDS REPAIR'}")
        lines.append(f"  Config: {tool['path']}")
        if tool["issues"]:
            for issue in tool["issues"]:
                lines.append(f"  - {issue}")
        else:
            lines.append("  Hooks point to the current bridge.")

    lines.append("")
    if report["ok"]:
        lines.append("Overall: OK")
    else:
        lines.append("Overall: NEEDS REPAIR")
        lines.append("Run Repair Hooks, then restart Cursor, Claude Code, and Codex sessions.")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Install or diagnose ClaudeNotch hooks")
    parser.add_argument("mode", choices=["diagnose", "repair"])
    parser.add_argument("--bridge", default=str(infer_bridge()))
    parser.add_argument("--home", default=str(default_home()))
    parser.add_argument("--socket", default=None)
    parser.add_argument("--no-socket-check", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    home = Path(args.home).expanduser()
    bridge = Path(args.bridge).expanduser().resolve()
    socket_path = Path(args.socket).expanduser() if args.socket else default_socket(home)

    if args.mode == "repair":
        repair_all(home, bridge)

    report = diagnose(home, bridge, socket_path, check_socket=not args.no_socket_check)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print(render_text(report))
    return 0 if report["ok"] or args.mode == "repair" else 1


if __name__ == "__main__":
    raise SystemExit(main())
