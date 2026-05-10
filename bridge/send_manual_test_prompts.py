#!/usr/bin/env python3
"""向 ClaudeNotch 连续发送多条需确认的 PermissionRequest，每条结束后等待 N 秒再发下一条。

先启动 ClaudeNotch，再：
  python3 bridge/send_manual_test_prompts.py
  python3 bridge/send_manual_test_prompts.py --sleep 10

环境变量 CLAUDE_NOTCH_SOCKET 可覆盖默认 ~/.claude-notch/bridge.sock
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import struct
import time
from pathlib import Path


def socket_path() -> str:
    return os.environ.get("CLAUDE_NOTCH_SOCKET", str(Path.home() / ".claude-notch" / "bridge.sock"))


def framed_send_recv(sock: socket.socket, obj: dict) -> dict:
    payload = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    sock.sendall(struct.pack(">I", len(payload)) + payload)
    hdr = _recv_exact(sock, 4)
    (n,) = struct.unpack(">I", hdr)
    body = _recv_exact(sock, n)
    return json.loads(body.decode("utf-8"))


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    parts: list[bytes] = []
    got = 0
    while got < n:
        chunk = sock.recv(n - got)
        if not chunk:
            raise OSError("socket closed")
        parts.append(chunk)
        got += len(chunk)
    return b"".join(parts)


def main() -> int:
    p = argparse.ArgumentParser(description="Burst fake PermissionRequests for ClaudeNotch")
    p.add_argument("--sleep", type=float, default=10.0, metavar="SEC", help="每条回复后的间隔秒数")
    args = p.parse_args()

    path = socket_path()
    if not os.path.exists(path):
        print(f"socket 不存在: {path}\n请先启动 ClaudeNotch。", flush=True)
        return 1

    samples: list[dict] = [
        {
            "session_id": "batch-01",
            "cwd": "/tmp/claude-notch-test",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": {"command": "ls -la ~/Downloads"},
        },
        {
            "session_id": "batch-02",
            "cwd": "~/Projects/demo",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Write",
            "tool_input": {"file_path": "README.md"},
        },
        {
            "session_id": "batch-03",
            "cwd": "/var/tmp",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": {"command": "curl -fsSL https://example.com"},
        },
        {
            "session_id": "batch-04-codex",
            "cwd": "/tmp",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": {"command": "docker ps"},
            "source": "codex",
        },
        {
            "session_id": "batch-05",
            "cwd": "/srv/app",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Grep",
            "tool_input": {"pattern": "password", "path": "src"},
        },
        {
            "session_id": "batch-06",
            "cwd": "/tmp",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Glob",
            "tool_input": {"pattern": "**/*.pem"},
        },
        {
            "session_id": "batch-07",
            "cwd": "/proj",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Edit",
            "tool_input": {"file_path": "package.json"},
        },
        {
            "session_id": "batch-08",
            "cwd": "/proj",
            "hook_event_name": "PermissionRequest",
            "tool_name": "agent",
            "tool_input": {"description": "重构 auth 模块并跑测试"},
        },
        {
            "session_id": "batch-09",
            "cwd": "/tmp",
            "hook_event_name": "PermissionRequest",
            "tool_name": "Bash",
            "tool_input": {"command": "ffmpeg -i in.mkv out.mp4"},
        },
    ]

    print(f"Socket: {path}\n每条结束后等待 {args.sleep}s。\n共 {len(samples)} 条。\n", flush=True)

    for i, hook in enumerate(samples, 1):
        print(f"\n>>> [{i}/{len(samples)}] {hook.get('tool_name')}", flush=True)
        ti = hook.get("tool_input") or {}
        if "command" in ti:
            print(f"    {ti['command']}", flush=True)
        elif "file_path" in ti:
            print(f"    file: {ti['file_path']}", flush=True)
        elif "pattern" in ti:
            print(f"    pattern: {ti.get('pattern')} path: {ti.get('path')}", flush=True)

        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
                s.settimeout(600.0)
                s.connect(path)
                reply = framed_send_recv(s, {"hook_input": hook})
            print(f"<<< {reply}", flush=True)
        except OSError as e:
            print(f"失败: {e}", flush=True)
            return 1

        if i < len(samples):
            print(f"--- 等待 {args.sleep}s", flush=True)
            time.sleep(args.sleep)

    print("\n全部完成。", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
