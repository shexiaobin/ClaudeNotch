# ClaudeNotch QA Checklist

本清单用于 v1 完整 QA 与发布复盘。自动化检查先跑，手动检查再覆盖两台真机和真实 Claude Code / Cursor 集成。

## 自动化检查

在真实终端中运行：

```bash
./ClaudeNotch/build.sh
python3 -m py_compile bridge/*.py
python3 bridge/test_bridge_e2e.py
```

验收标准：

- `build.sh` 成功生成 `ClaudeNotch/.build-local/ClaudeNotch`
- Python bridge 全部通过语法编译
- bridge E2E 覆盖 allow、deny、socket missing、invalid JSON、notification、stop、Cursor shell fallback
- 如果沙盒环境运行 `test_bridge_e2e.py` 出现 Unix socket `Operation not permitted`，改在真实终端运行

## Swift App 手动 QA

启动 `ClaudeNotch/.build-local/ClaudeNotch` 后检查：

- idle pill 出现在屏幕顶部，状态栏显示 `◉`
- 状态栏菜单可打开，Pet ON/OFF、Drag ON/OFF、Reset Position、Quit 可用
- PermissionRequest 展开面板，Allow/Deny 按钮可点击
- `Cmd+Y` 允许，`Cmd+N` 拒绝，`Esc` 拒绝，`Enter` 允许
- 权限请求 5 秒无操作后自动 Allow，并写入 Recent Decisions
- Notification 更新 idle pill 或活动流
- Stop 展示完成通知、更新状态、播放音效
- Jump 能唤起 Cursor 或正在运行的终端

## 真实集成 QA

Claude Code：

- 触发 PermissionRequest，ClaudeNotch 弹出审批
- Allow 后 Claude Code 继续执行
- Deny 后 Claude Code 收到拒绝结果
- Notification hook 能更新 idle 状态
- Stop hook 能展示完成通知

Cursor：

- beforeShellExecution 触发 ClaudeNotch 审批
- Allow 后 Cursor 继续执行命令
- Deny 后 Cursor 收到 `permission: deny`
- App 未启动时，Cursor shell hook fallback 为 `permission: allow`
- afterFileEdit 更新活动状态
- stop 展示完成状态

## 两台真机矩阵

刘海屏 MacBook：

- pill 位于刘海区域，不遮挡菜单项
- 展开面板在全屏 Space 中可见
- 拖拽后位置可保存，Reset Position 可恢复

非刘海或外接屏 Mac：

- pill 位于菜单栏下方
- 多屏时跟随主屏展示
- 展开面板不超出屏幕边界

## 安装与发布验收

源码安装：

- `./install.sh` 能编译 App
- Claude Code hooks 写入 `~/.claude/settings.json`
- Cursor hooks 写入 `~/.cursor/hooks.json`
- Cursor hooks 保留用户已有 hook，只替换旧 ClaudeNotch hook

DMG 安装：

- 从 GitHub Release 下载 `ClaudeNotch-1.0-arm64.dmg`
- 挂载后包含 `ClaudeNotch.app`、`Install Hooks.command`、说明文件
- 运行 `Install Hooks.command` 后 hooks 指向 `ClaudeNotch.app/Contents/Resources/bridge`
- App 保留在 DMG 同目录或 `/Applications` 时 hooks 可用
- 删除或移动 App 后，安装脚本能给出清晰错误

已知发布限制：

- 当前使用本机 ad-hoc codesign，不做 Apple Developer ID 签名
- 当前不做 notarization，首次打开可能需要用户在 macOS 隐私与安全性中允许
- `dist/` 不提交到 Git，DMG 通过 GitHub Release 管理
