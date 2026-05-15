ClaudeNotch — 灵动岛风格 AI 编码通知（macOS 11+，Apple Silicon）

【安装步骤】
1. 双击运行「Install Hooks.command」（首次可能需在右键菜单中选「打开」）。
2. 安装脚本会把 ClaudeNotch.app 复制到「应用程序」文件夹，并写入 hooks。
3. 从「应用程序」或 Spotlight 启动 ClaudeNotch（菜单栏出现 ◉ 图标）。
4. 重启 Cursor；Claude Code / Codex 在下次会话时会使用新 hooks。

【如果有 ◉ 但不弹窗】
1. 点击菜单栏 ◉ → Run Diagnostics。
2. 若提示 hooks 缺失、旧路径或 /Volumes 路径，点击 ◉ → Repair Hooks。
3. 修复后重启 Cursor，并重新开启 Claude Code / Codex 会话。

【系统要求】
• Apple Silicon (arm64)
• Python 3（系统自带即可）

【说明】
• 若仅把 .app 拷走而未运行 Install Hooks，Claude Code / Cursor / Codex 不会连到灵动岛。
• 移动或删除 /Applications/ClaudeNotch.app 后请重新运行一次 Install Hooks.command。
• hooks 必须指向 /Applications/ClaudeNotch.app/Contents/Resources/bridge；不要指向 /Volumes/...。
• 首次打开若被 macOS 拦截，请：系统设置 → 隐私与安全性 → 仍要打开。

【源码与许可】
见项目内 LICENSE / README。
