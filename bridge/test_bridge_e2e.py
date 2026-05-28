#!/usr/bin/env python3
"""End-to-end bridge checks using a mock Unix socket server.

These tests do not require the Swift app. They validate the hook scripts'
stdin/stdout contracts and the length-prefixed JSON socket protocol.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
CLAUDE_PERMISSION = ROOT / "claude_permission_bridge.py"
CLAUDE_NOTIFICATION = ROOT / "claude_notification_bridge.py"
CLAUDE_STOP = ROOT / "claude_stop_bridge.py"
CURSOR_SHELL = ROOT / "cursor_shell_hook.py"
CURSOR_FILE = ROOT / "cursor_file_hook.py"
CURSOR_STOP = ROOT / "cursor_stop_hook.py"
CODEX_PERMISSION = ROOT / "codex_permission_bridge.py"
CODEX_STOP = ROOT / "codex_stop_bridge.py"
INSTALL_HOOKS = ROOT / "install_hooks.py"


def read_exact(conn: socket.socket, n: int) -> bytes:
    parts: list[bytes] = []
    got = 0
    while got < n:
        chunk = conn.recv(n - got)
        if not chunk:
            raise OSError("socket closed")
        parts.append(chunk)
        got += len(chunk)
    return b"".join(parts)


def read_framed(conn: socket.socket) -> dict[str, Any]:
    (n,) = struct.unpack(">I", read_exact(conn, 4))
    body = read_exact(conn, n)
    return json.loads(body.decode("utf-8"))


def write_framed(conn: socket.socket, obj: dict[str, Any]) -> None:
    payload = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    conn.sendall(struct.pack(">I", len(payload)) + payload)


class MockServer:
    def __init__(self, replies: list[dict[str, Any]] | None = None) -> None:
        self.replies = replies or [{"ok": True}]
        self.messages: list[dict[str, Any]] = []
        self.ready = threading.Event()
        self.error: BaseException | None = None
        self.tmp = tempfile.TemporaryDirectory()
        self.sock_path = str(Path(self.tmp.name) / "bridge.sock")
        self.thread = threading.Thread(target=self._run, daemon=True)

    def __enter__(self) -> "MockServer":
        self.thread.start()
        assert self.ready.wait(timeout=2.0), "mock socket server did not start"
        return self

    def __exit__(self, *_exc: object) -> None:
        self.thread.join(timeout=2.0)
        self.tmp.cleanup()
        if self.error:
            raise self.error

    def _run(self) -> None:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.bind(self.sock_path)
                s.listen(len(self.replies))
                self.ready.set()
                for reply in self.replies:
                    conn, _ = s.accept()
                    with conn:
                        self.messages.append(read_framed(conn))
                        write_framed(conn, reply)
        except BaseException as exc:
            self.error = exc
            self.ready.set()


def run_hook(
    script: Path,
    stdin_obj: Any,
    sock_path: str | None = None,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    env = {**os.environ}
    if sock_path is not None:
        env["CLAUDE_NOTCH_SOCKET"] = sock_path
    if extra_env:
        env.update(extra_env)
    stdin_text = stdin_obj if isinstance(stdin_obj, str) else json.dumps(stdin_obj)
    return subprocess.run(
        [sys.executable, str(script)],
        input=stdin_text,
        capture_output=True,
        text=True,
        env=env,
        timeout=10,
    )


def sample_permission() -> dict[str, Any]:
    return {
        "session_id": "test",
        "cwd": "/tmp",
        "hook_event_name": "PermissionRequest",
        "tool_name": "Bash",
        "tool_input": {"command": "echo hi"},
    }


def assert_json(stdout: str) -> dict[str, Any]:
    assert stdout, "expected JSON stdout"
    return json.loads(stdout)


def run_installer(mode: str, home: Path, bridge: Path = ROOT) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(INSTALL_HOOKS),
            mode,
            "--bridge",
            str(bridge),
            "--home",
            str(home),
            "--no-socket-check",
            "--json",
        ],
        capture_output=True,
        text=True,
        timeout=10,
    )


def run_diagnose_with_socket(home: Path, socket_path: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(INSTALL_HOOKS),
            "diagnose",
            "--bridge",
            str(ROOT),
            "--home",
            str(home),
            "--socket",
            str(socket_path),
            "--json",
        ],
        capture_output=True,
        text=True,
        timeout=10,
    )


def test_claude_permission_allow() -> None:
    with MockServer([{"behavior": "allow"}]) as server:
        result = run_hook(CLAUDE_PERMISSION, sample_permission(), server.sock_path)
        assert result.returncode == 0, result.stderr
        out = assert_json(result.stdout)
        decision = out["hookSpecificOutput"]["decision"]
        assert decision["behavior"] == "allow"
        assert "hook_input" in server.messages[0]


def test_claude_permission_deny_message() -> None:
    with MockServer([{"behavior": "deny", "message": "Nope"}]) as server:
        result = run_hook(CLAUDE_PERMISSION, sample_permission(), server.sock_path)
        assert result.returncode == 0, result.stderr
        decision = assert_json(result.stdout)["hookSpecificOutput"]["decision"]
        assert decision == {"behavior": "deny", "message": "Nope"}


def test_claude_permission_socket_missing() -> None:
    result = run_hook(CLAUDE_PERMISSION, sample_permission(), "/tmp/claude-notch-missing.sock")
    assert result.returncode != 0
    assert result.stdout == ""


def test_invalid_json_fallbacks() -> None:
    assert run_hook(CLAUDE_PERMISSION, "{", "/tmp/unused.sock").returncode != 0
    assert run_hook(CLAUDE_NOTIFICATION, "{", "/tmp/unused.sock").returncode == 0
    assert run_hook(CLAUDE_STOP, "{", "/tmp/unused.sock").returncode == 0
    cursor = run_hook(CURSOR_SHELL, "{", "/tmp/unused.sock")
    assert cursor.returncode == 0
    assert assert_json(cursor.stdout) == {"permission": "allow"}


def test_notification_and_stop_ack() -> None:
    with MockServer([{"ok": True}, {"ok": True}, {"ok": True}, {"ok": True}]) as server:
        assert run_hook(CLAUDE_NOTIFICATION, {"hook_event_name": "Notification"}, server.sock_path).returncode == 0
        assert run_hook(CLAUDE_STOP, {"hook_event_name": "Stop"}, server.sock_path).returncode == 0
        assert run_hook(CURSOR_FILE, {"file_path": "a.swift", "edits": [1]}, server.sock_path).returncode == 0
        assert run_hook(CURSOR_STOP, {"hook_event_name": "stop"}, server.sock_path).returncode == 0
        assert "notification" in server.messages[0]
        assert "stop_event" in server.messages[1]
        assert server.messages[2]["notification"]["hook_event_name"] == "afterFileEdit"
        assert "stop_event" in server.messages[3]


def test_nonblocking_bridge_debug_reports_socket_failure() -> None:
    missing = run_hook(
        CLAUDE_NOTIFICATION,
        {"hook_event_name": "Notification"},
        "/tmp/claude-notch-missing.sock",
    )
    assert missing.returncode == 0
    assert missing.stderr == ""

    debug = run_hook(
        CLAUDE_NOTIFICATION,
        {"hook_event_name": "Notification"},
        "/tmp/claude-notch-missing.sock",
        {"CLAUDE_NOTCH_BRIDGE_DEBUG": "1"},
    )
    assert debug.returncode == 0
    assert "socket missing" in debug.stderr


def test_cursor_shell_allow_deny_and_missing_socket() -> None:
    cursor_input = {
        "conversation_id": "cursor-test",
        "workspace_roots": ["/tmp/project"],
        "command": "git status",
    }

    missing = run_hook(CURSOR_SHELL, cursor_input, "/tmp/claude-notch-missing.sock")
    assert missing.returncode == 0
    assert assert_json(missing.stdout) == {"permission": "allow"}

    with MockServer([{"behavior": "allow"}]) as server:
        allowed = run_hook(
            CURSOR_SHELL,
            cursor_input,
            server.sock_path,
            {"CLAUDE_NOTCH_CURSOR_TARGET": "app"},
        )
        assert allowed.returncode == 0
        assert assert_json(allowed.stdout) == {"permission": "allow"}
        hook_input = server.messages[0]["hook_input"]
        assert hook_input["source"] == "cursor"
        assert hook_input["launch_context"] == "app"
        assert hook_input["tool_input"]["description"] == "Cursor shell execution"

    with MockServer([{"behavior": "deny", "message": "Blocked"}]) as server:
        denied = run_hook(CURSOR_SHELL, cursor_input, server.sock_path)
        assert denied.returncode == 0
        assert assert_json(denied.stdout) == {"permission": "deny", "agentMessage": "Blocked"}


def test_codex_permission_and_stop_source_marker() -> None:
    with MockServer([{"behavior": "allow"}, {"ok": True}]) as server:
        permission = run_hook(
            CODEX_PERMISSION,
            sample_permission(),
            server.sock_path,
            {"CLAUDE_NOTCH_CODEX_TARGET": "app"},
        )
        assert permission.returncode == 0, permission.stderr
        decision = assert_json(permission.stdout)["hookSpecificOutput"]["decision"]
        assert decision["behavior"] == "allow"
        assert server.messages[0]["hook_input"]["source"] == "codex"
        assert server.messages[0]["hook_input"]["launch_context"] == "app"

        stop = run_hook(
            CODEX_STOP,
            {"hook_event_name": "Stop", "thread_id": "codex-thread"},
            server.sock_path,
            {"CLAUDE_NOTCH_CODEX_TARGET": "terminal"},
        )
        assert stop.returncode == 0
        assert server.messages[1]["stop_event"]["source"] == "codex"
        assert server.messages[1]["stop_event"]["launch_context"] == "terminal"
        assert server.messages[1]["stop_event"]["session_id"] == "codex-thread"


def test_codex_background_permission_is_suppressed() -> None:
    background = {
        "session_id": "ambient-meta-ads",
        "cwd": "/",
        "hook_event_name": "PermissionRequest",
        "tool_name": "mcp__codex_apps__meta_ads_mcp_mayer._ads_get_ad_entities",
        "tool_input": {
            "fields": ["delivery", "objective", "amount_spent", "results", "cost_per_result"],
            "filtering": [{"field": "campaign.delivery", "operator": "IN", "value": ["active"]}],
        },
    }

    result = run_hook(
        CODEX_PERMISSION,
        background,
        "/tmp/claude-notch-missing.sock",
        {"CLAUDE_NOTCH_CODEX_TARGET": "app"},
    )
    assert result.returncode == 0, result.stderr
    decision = assert_json(result.stdout)["hookSpecificOutput"]["decision"]
    assert decision == {"behavior": "allow"}


def test_codex_project_permission_still_reaches_ui() -> None:
    project = {
        **sample_permission(),
        "cwd": "/tmp/project",
        "tool_name": "mcp__codex_apps__meta_ads_mcp_mayer._ads_get_ad_entities",
        "tool_input": {"fields": ["delivery"]},
    }

    with MockServer([{"behavior": "deny", "message": "Review first"}]) as server:
        result = run_hook(
            CODEX_PERMISSION,
            project,
            server.sock_path,
            {"CLAUDE_NOTCH_CODEX_TARGET": "app"},
        )
        assert result.returncode == 0, result.stderr
        decision = assert_json(result.stdout)["hookSpecificOutput"]["decision"]
        assert decision == {"behavior": "deny", "message": "Review first"}
        assert server.messages[0]["hook_input"]["source"] == "codex"


def test_codex_background_filter_can_be_disabled() -> None:
    background = {
        "cwd": "/",
        "hook_event_name": "PermissionRequest",
        "tool_name": "mcp__codex_apps__meta_ads_mcp_mayer._ads_get_ad_entities",
        "tool_input": {"fields": ["amount_spent"]},
    }

    result = run_hook(
        CODEX_PERMISSION,
        background,
        "/tmp/claude-notch-missing.sock",
        {
            "CLAUDE_NOTCH_CODEX_TARGET": "app",
            "CLAUDE_NOTCH_CODEX_BACKGROUND_FILTER": "0",
        },
    )
    assert result.returncode != 0


def test_cursor_stop_source_and_launch_context() -> None:
    with MockServer([{"ok": True}]) as server:
        stop = run_hook(
            CURSOR_STOP,
            {"conversation_id": "cursor-test", "hook_event_name": "stop"},
            server.sock_path,
            {"CLAUDE_NOTCH_CURSOR_TARGET": "terminal"},
        )
        assert stop.returncode == 0
        event = server.messages[0]["stop_event"]
        assert event["source"] == "cursor"
        assert event["launch_context"] == "terminal"
        assert event["session_id"] == "cursor-test"


def test_install_hooks_repairs_stale_paths_and_preserves_user_hooks() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        cursor_dir = home / ".cursor"
        cursor_dir.mkdir()
        cursor_hooks = cursor_dir / "hooks.json"
        cursor_hooks.write_text(json.dumps({
            "version": 1,
            "hooks": {
                "beforeShellExecution": [
                    {"command": "/Volumes/ClaudeNotch 1.0.1/ClaudeNotch.app/Contents/Resources/bridge/cursor_shell_hook.py"},
                    {"command": "/usr/local/bin/my-cursor-hook"},
                ],
            },
        }))

        repaired = run_installer("repair", home)
        assert repaired.returncode == 0, repaired.stderr or repaired.stdout
        report = assert_json(repaired.stdout)
        assert report["tools"]["claude"]["ok"]
        assert report["tools"]["cursor"]["ok"]
        assert report["tools"]["codex"]["ok"]

        after = json.loads(cursor_hooks.read_text())
        commands = [item["command"] for item in after["hooks"]["beforeShellExecution"]]
        assert "/usr/local/bin/my-cursor-hook" in commands
        assert str(ROOT / "cursor_shell_hook.py") in commands
        assert all("/Volumes/ClaudeNotch" not in command for command in commands)

        diagnosed = run_installer("diagnose", home)
        assert diagnosed.returncode == 0, diagnosed.stderr or diagnosed.stdout
        diag = assert_json(diagnosed.stdout)
        assert diag["ok"]


def test_diagnose_requires_connectable_socket() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        repaired = run_installer("repair", home)
        assert repaired.returncode == 0, repaired.stderr or repaired.stdout

        stale_socket = home / ".claude-notch" / "bridge.sock"
        stale_socket.parent.mkdir(parents=True)
        stale_socket.write_text("stale")

        diagnosed = run_diagnose_with_socket(home, stale_socket)
        assert diagnosed.returncode == 1
        report = assert_json(diagnosed.stdout)
        assert report["socket"]["exists"]
        assert not report["socket"]["connectable"]
        assert not report["ok"]


def test_repair_backs_up_invalid_json_before_overwrite() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp)
        cursor_dir = home / ".cursor"
        cursor_dir.mkdir()
        cursor_hooks = cursor_dir / "hooks.json"
        cursor_hooks.write_text("{ broken")

        repaired = run_installer("repair", home)
        assert repaired.returncode == 0, repaired.stderr or repaired.stdout
        backups = list(cursor_dir.glob("hooks.json.claudenotch-bak-*"))
        assert len(backups) == 1
        assert backups[0].read_text() == "{ broken"
        repaired_hooks = json.loads(cursor_hooks.read_text())
        commands = [item["command"] for item in repaired_hooks["hooks"]["beforeShellExecution"]]
        assert str(ROOT / "cursor_shell_hook.py") in commands


def test_diagnose_requires_executable_bridge_files() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp) / "home"
        bridge = Path(tmp) / "bridge"
        shutil.copytree(ROOT, bridge)
        (bridge / "claude_notification_bridge.py").chmod(0o644)

        repaired = run_installer("repair", home, bridge)
        assert repaired.returncode == 0, repaired.stderr or repaired.stdout

        (bridge / "claude_notification_bridge.py").chmod(0o644)
        diagnosed = run_installer("diagnose", home, bridge)
        assert diagnosed.returncode == 1
        report = assert_json(diagnosed.stdout)
        assert not report["bridge_files"]["claude_notification_bridge.py"]["executable"]
        assert not report["ok"]


def test_repair_returns_nonzero_when_bridge_is_incomplete() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        home = Path(tmp) / "home"
        bridge = Path(tmp) / "bridge"
        bridge.mkdir()
        repaired = run_installer("repair", home, bridge)
        assert repaired.returncode == 1
        report = assert_json(repaired.stdout)
        assert not report["ok"]


def main() -> int:
    tests = [
        test_claude_permission_allow,
        test_claude_permission_deny_message,
        test_claude_permission_socket_missing,
        test_invalid_json_fallbacks,
        test_notification_and_stop_ack,
        test_nonblocking_bridge_debug_reports_socket_failure,
        test_cursor_shell_allow_deny_and_missing_socket,
        test_codex_permission_and_stop_source_marker,
        test_codex_background_permission_is_suppressed,
        test_codex_project_permission_still_reaches_ui,
        test_codex_background_filter_can_be_disabled,
        test_cursor_stop_source_and_launch_context,
        test_install_hooks_repairs_stale_paths_and_preserves_user_hooks,
        test_diagnose_requires_connectable_socket,
        test_repair_backs_up_invalid_json_before_overwrite,
        test_diagnose_requires_executable_bridge_files,
        test_repair_returns_nonzero_when_bridge_is_incomplete,
    ]
    for test in tests:
        test()
        print(f"OK: {test.__name__}")
    print("OK: bridge E2E suite passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
