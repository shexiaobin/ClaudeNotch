# ClaudeNotch

macOS 灵动岛风格的 AI 编码助手通知中心。将 Claude Code 和 Cursor 的权限请求、通知、完成事件显示在屏幕顶部的灵动岛面板中，支持一键 Allow/Deny。

## 效果

- **权限请求** — 灵动岛展开，显示工具名、命令内容、Allow/Deny 按钮
- **空闲状态** — 缩小为顶部药丸，显示会话时长、来源标识、电子宠物
- **完成通知** — 音效提示 + 宠物表情变化
- **多来源** — 同时显示 Claude Code 和 Cursor 的会话状态

## 支持的 AI 编码工具

| 工具 | Hook 事件 |
|------|----------|
| Claude Code | PermissionRequest, Notification, Stop |
| Cursor | beforeShellExecution, afterFileEdit, stop |

## 一键安装

```bash
git clone https://github.com/shexiaobin/ClaudeNotch.git
cd ClaudeNotch
./install.sh
```

安装脚本会自动完成：
1. 编译 Swift App（需要 Xcode Command Line Tools）
2. 配置 Claude Code hooks (`~/.claude/settings.json`)
3. 配置 Cursor hooks (`~/.cursor/hooks.json`)

安装完成后启动：

```bash
open ClaudeNotch/.build-local/ClaudeNotch
```

## 系统要求

- macOS 11.0+（Big Sur 及以上）
- Apple Silicon (arm64)
- Xcode Command Line Tools (`xcode-select --install`)
- Python 3（macOS 自带）

## 架构

```
Claude Code / Cursor
    ↓ stdin JSON (hook 事件)
bridge/ (Python 桥接脚本)
    ↓ Unix Socket (bridge.sock)
ClaudeNotch (Swift macOS App)
    → 灵动岛面板 (Allow/Deny)
    → 状态栏图标 (◉)
    → 电子宠物
    → 音效反馈
```

### bridge/ — Hook 桥接脚本

| 脚本 | 工具 | 功能 |
|------|------|------|
| `claude_permission_bridge.py` | Claude Code | 权限请求（阻塞等待审批） |
| `claude_notification_bridge.py` | Claude Code | 通知事件 |
| `claude_stop_bridge.py` | Claude Code | 停止事件 |
| `cursor_shell_hook.py` | Cursor | Shell 执行审批 |
| `cursor_file_hook.py` | Cursor | 文件编辑通知 |
| `cursor_stop_hook.py` | Cursor | 停止事件 |

### ClaudeNotch/ — Swift macOS App

| 文件 | 功能 |
|------|------|
| `AppDelegate.swift` | 应用入口、Socket 服务、权限处理、状态栏 |
| `UnixSocketServer.swift` | Unix Socket 服务端 |
| `NotchPanelController.swift` | 灵动岛面板（展开/药丸动画） |
| `PetView.swift` | 像素电子宠物（情绪系统） |
| `ChatEngine.swift` | Claude CLI 对话引擎 |
| `SessionTracker.swift` | 多会话追踪 |
| `SoundPlayer.swift` | 音效播放 |
| `MarkdownView.swift` | Markdown 渲染 |
| `TerminalJumper.swift` | 跳转到终端 |

## 快捷键

在权限请求面板中：
- `Cmd+Y` — Allow
- `Cmd+N` — Deny

## 配置

### 环境变量

- `CLAUDE_NOTCH_SOCKET` — 自定义 socket 路径（默认 `~/.claude-notch/bridge.sock`）

### 自动超时

权限请求在 120 秒无操作后自动 Deny。

## 手动配置 Hooks

如果不使用 install.sh，可以手动配置：

**Claude Code** (`~/.claude/settings.json`):
```json
{
  "hooks": {
    "PermissionRequest": [
      {"matcher": ".*", "hooks": [
        {"type": "command", "command": "/path/to/bridge/claude_permission_bridge.py"}
      ]}
    ],
    "Notification": [
      {"matcher": "", "hooks": [
        {"type": "command", "command": "/path/to/bridge/claude_notification_bridge.py"}
      ]}
    ],
    "Stop": [
      {"matcher": "", "hooks": [
        {"type": "command", "command": "/path/to/bridge/claude_stop_bridge.py"}
      ]}
    ]
  }
}
```

**Cursor** (`~/.cursor/hooks.json`):
```json
{
  "version": 1,
  "hooks": {
    "beforeShellExecution": [{"command": "/path/to/bridge/cursor_shell_hook.py"}],
    "afterFileEdit": [{"command": "/path/to/bridge/cursor_file_hook.py"}],
    "stop": [{"command": "/path/to/bridge/cursor_stop_hook.py"}]
  }
}
```

## 测试

```bash
python3 bridge/test_bridge_e2e.py
```

使用 mock socket 验证桥接脚本的协议正确性，不需要启动 Swift App。

## License

[MIT](LICENSE)
