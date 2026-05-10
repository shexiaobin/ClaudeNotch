#!/usr/bin/env python3
"""
向 ClaudeNotch 发送模拟 hook 权限请求（与 claude_permission_bridge 相同帧格式）。
用于手动测试灵动岛展开、Markdown 区域与 Allow/Deny。

前置：ClaudeNotch 已运行（~/.claude-notch/bridge.sock 存在）。

用法：
  ./send_test_permissions.py              # 依次弹出 10 条（每条需你在岛上点 Allow/Deny）
  ./send_test_permissions.py --index 3    # 只发第 3 条
  ./send_test_permissions.py --count 2    # 只发前 2 条

环境变量 CLAUDE_NOTCH_SOCKET 可覆盖套接字路径。
"""
from __future__ import annotations

import argparse
import json
import os
import socket
import struct
import sys
from pathlib import Path

DEFAULT_SOCK = Path.home() / ".claude-notch" / "bridge.sock"
TIMEOUT_SEC = 600.0

# 与此前对话中生成的 10 条场景一致；tool_input 使用 description，便于面板 JSON/Markdown 摘要展示
SCENARIOS: list[tuple[str, str]] = [
    (
        "麦克风",
        "「Claude Notch」想使用麦克风，以便在语音输入时捕获你的声音。",
    ),
    (
        "摄像头",
        "需要访问摄像头，用于在进行视频通话时显示画面。",
    ),
    (
        "辅助功能",
        "请在「系统设置 → 隐私与安全性 → 辅助功能」中允许本应用，以便在菜单栏与刘海区域正确显示面板。",
    ),
    (
        "屏幕录制",
        "需要「屏幕录制」权限，用于截取菜单栏区域并合成灵动岛样式预览。",
    ),
    (
        "全盘访问",
        "为读取你选择的日志与配置文件，应用请求「完全磁盘访问权限」。",
    ),
    (
        "通知",
        "是否允许发送通知？我们将在有新消息或定时提醒时提示你。",
    ),
    (
        "日历",
        "允许访问日历以在岛上显示下一场会议的开始时间与标题。",
    ),
    (
        "定位",
        "使用大致位置以在不同显示器布局下自动对齐面板位置。",
    ),
    (
        "蓝牙",
        "需要蓝牙权限以连接你配对的周边设备并显示连接状态。",
    ),
    (
        "本地网络",
        "应用希望在本地网络中发现并与同一 Wi‑Fi 下的设备通信，用于同步小组件数据。",
    ),
]


def socket_path() -> str:
    p = os.environ.get("CLAUDE_NOTCH_SOCKET", "").strip()
    return p if p else str(DEFAULT_SOCK)


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


def send_one(sock: socket.socket, index: int, tool_name: str, description: str) -> dict:
    msg = {
        "hook_input": {
            "tool_name": tool_name,
            "tool_input": {"description": description},
            "session_id": f"test-permission-{index}",
            "cwd": str(Path.home()),
            "source": "claude",
        }
    }
    return framed_send_recv(sock, msg)


def main() -> int:
    ap = argparse.ArgumentParser(description="Send test permission hooks to ClaudeNotch")
    ap.add_argument(
        "--index",
        type=int,
        metavar="N",
        help="只发送第 N 条（1–10）",
    )
    ap.add_argument(
        "--count",
        type=int,
        metavar="K",
        help="从第 1 条起连续发送 K 条",
    )
    args = ap.parse_args()

    path = socket_path()
    if not os.path.exists(path):
        print(f"错误: 找不到套接字 {path}，请先启动 ClaudeNotch。", file=sys.stderr)
        return 1

    if args.index is not None:
        if not 1 <= args.index <= len(SCENARIOS):
            print(f"--index 必须在 1–{len(SCENARIOS)}", file=sys.stderr)
            return 1
        indices = [args.index - 1]
    elif args.count is not None:
        if args.count < 1:
            print("--count 必须 >= 1", file=sys.stderr)
            return 1
        indices = list(range(min(args.count, len(SCENARIOS))))
    else:
        indices = list(range(len(SCENARIOS)))

    for ord_i, idx in enumerate(indices):
        tool_name, desc = SCENARIOS[idx]
        display_num = idx + 1
        print(
            f"\n>>> [{ord_i + 1}/{len(indices)}] 发送第 {display_num} 条: {tool_name}\n"
            f"    （请到灵动岛上点击 Allow 或 Deny；默认约 5 秒无操作可能自动 Allow）",
            file=sys.stderr,
        )
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
                sock.settimeout(TIMEOUT_SEC)
                sock.connect(path)
                resp = send_one(sock, display_num, tool_name, desc)
        except OSError as e:
            print(f"套接字错误: {e}", file=sys.stderr)
            return 1
        print(json.dumps(resp, ensure_ascii=False, indent=2))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
