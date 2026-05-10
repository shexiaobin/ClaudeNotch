import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var server: UnixSocketServer?
    private var pending: PendingPrompt?
    private var statusItem: NSStatusItem?
    private var autoTimeoutSec: TimeInterval = 5
    private var timeoutTimer: Timer?
    private let socketPath: String = {
        if let e = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_SOCKET"], !e.isEmpty {
            return e
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.claude-notch/bridge.sock"
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let srv = UnixSocketServer(
            path: socketPath,
            onPermission: { [weak self] hookInput, reply in
                guard let strongSelf = self else {
                    reply(["behavior": "deny", "message": "ClaudeNotch stopped"])
                    return
                }
                strongSelf.handlePermission(hookInput: hookInput, reply: reply)
            },
            onEvent: { [weak self] msg in
                self?.handleEvent(msg)
            }
        )
        server = srv
        do {
            try srv.start()
            NSLog("ClaudeNotch listening on %@", socketPath)
        } catch {
            NSLog("ClaudeNotch failed to bind %@: %@", socketPath, String(describing: error))
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let screen = NSScreen.main {
                NotchPanelController.showIdlePill(on: screen)
                NSLog("ClaudeNotch: idle pill displayed on launch")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem?.button {
            btn.title = "◉"
            btn.toolTip = "ClaudeNotch — listening"
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "ClaudeNotch Running", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let historyItem = NSMenuItem(title: "Recent Decisions", action: nil, keyEquivalent: "")
        let histSub = NSMenu()
        historyItem.submenu = histSub
        menu.addItem(historyItem)

        menu.addItem(NSMenuItem.separator())

        let petItem = NSMenuItem(title: "Pet: ON", action: #selector(togglePet(_:)), keyEquivalent: "p")
        petItem.target = self
        menu.addItem(petItem)

        let dragItem = NSMenuItem(title: "Drag: OFF", action: #selector(toggleDrag(_:)), keyEquivalent: "d")
        dragItem.target = self
        menu.addItem(dragItem)

        let resetItem = NSMenuItem(title: "Reset Position", action: #selector(resetPosition(_:)), keyEquivalent: "r")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func togglePet(_ sender: NSMenuItem) {
        PetState.enabled.toggle()
        sender.title = PetState.enabled ? "Pet: ON" : "Pet: OFF"
        if let screen = NSScreen.main, pending == nil {
            NotchPanelController.showIdlePill(on: screen)
        }
    }

    @objc private func toggleDrag(_ sender: NSMenuItem) {
        NotchPanelController.dragEnabled.toggle()
        sender.title = NotchPanelController.dragEnabled ? "Drag: ON ✋" : "Drag: OFF"
    }

    @objc private func resetPosition(_ sender: NSMenuItem) {
        NotchPanelController.userCenterX = nil
        NotchPanelController.userY = nil
        if let screen = NSScreen.main, pending == nil {
            NotchPanelController.dismiss()
            NotchPanelController.showIdlePill(on: screen)
        }
    }

    private func appendHistory(_ tool: String, source: AgentSource, allowed: Bool) {
        guard let menu = statusItem?.menu,
              let histItem = menu.item(withTitle: "Recent Decisions"),
              let sub = histItem.submenu else { return }
        let icon = allowed ? "✓" : "✗"
        let label = "\(icon) [\(source.displayName)] \(tool) — \(allowed ? "Allowed" : "Denied")"
        let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        sub.insertItem(item, at: 0)
        if sub.items.count > 20 { sub.removeItem(at: sub.items.count - 1) }
    }

    private func updateStatusIcon(_ state: String) {
        guard let btn = statusItem?.button else { return }
        switch state {
        case "waiting": btn.title = "◉"
        case "busy": btn.title = "●"
        case "done": btn.title = "◎"
        default: btn.title = "◉"
        }
    }

    // MARK: - Permission handling

    private func handlePermission(hookInput: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        if let prev = pending {
            let prevTool = prev.hookInput["tool_name"] as? String ?? "Unknown"
            NSLog("ClaudeNotch: auto-deny previous pending request (%@) due to new request", prevTool)
            prev.completeDeny(message: "Superseded by new request")
            appendHistory(prevTool + " (superseded)", source: prev.source, allowed: false)
            cancelAutoTimeout()
            NotchPanelController.dismiss()
        }

        SoundPlayer.play(.requestArrived)
        updateStatusIcon("waiting")

        let source = detectSource(hookInput)
        let toolName = hookInput["tool_name"] as? String ?? "Unknown"
        let toolInput = hookInput["tool_input"] as? [String: Any] ?? [:]
        let sessionId = hookInput["session_id"] as? String ?? "default"
        let cwd = hookInput["cwd"] as? String ?? ""

        // Session tracking + emotion analysis
        let emotion = EmotionEngine.analyzeHook(toolName: toolName, toolInput: toolInput)
        NotchPanelController.sessionTracker.upsert(
            id: sessionId, source: source, status: .waiting,
            cwd: cwd, tool: toolName, emotion: emotion
        )
        PetState.mood = emotion == .idle ? .thinking : emotion

        // Activity log
        let detail = activityDetail(toolName: toolName, toolInput: toolInput)
        NotchPanelController.activityLog.append(tool: toolName, detail: detail, source: source)
        NotchPanelController.idleStateRef.isWorking = true
        NotchPanelController.idleStateRef.lastActivity = "$ \(detail.prefix(40))"

        let prompt = PendingPrompt(hookInput: hookInput, reply: reply, source: source)
        pending = prompt

        startAutoTimeout(reply: reply, toolName: toolName, source: source)

        NotchPanelController.present(
            hookInput: hookInput,
            source: source,
            onAllow: { [weak self] in
                NSLog("ClaudeNotch: user ALLOW for %@", toolName)
                self?.cancelAutoTimeout()
                SoundPlayer.play(.allowed)
                self?.pending?.completeAllow()
                self?.appendHistory(toolName, source: source, allowed: true)
                NotchPanelController.sessionTracker.upsert(
                    id: sessionId, source: source, status: .active,
                    cwd: cwd, tool: toolName, emotion: .happy
                )
                self?.pending = nil
                self?.updateStatusIcon("busy")
            },
            onDeny: { [weak self] in
                NSLog("ClaudeNotch: user DENY for %@", toolName)
                self?.cancelAutoTimeout()
                SoundPlayer.play(.denied)
                self?.pending?.completeDeny(message: nil)
                self?.appendHistory(toolName, source: source, allowed: false)
                NotchPanelController.sessionTracker.upsert(
                    id: sessionId, source: source, status: .active,
                    cwd: cwd, tool: toolName, emotion: .sad
                )
                self?.pending = nil
                self?.updateStatusIcon("busy")
            }
        )
    }

    // MARK: - Auto-timeout

    private func startAutoTimeout(reply: @escaping ([String: Any]) -> Void,
                                  toolName: String, source: AgentSource) {
        cancelAutoTimeout()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: autoTimeoutSec, repeats: false) { [weak self] _ in
            guard let strongSelf = self, strongSelf.pending != nil else { return }
            NSLog("ClaudeNotch: auto-allow after %.0fs for %@", strongSelf.autoTimeoutSec, toolName)
            SoundPlayer.play(.allowed)
            strongSelf.pending?.completeAllow()
            strongSelf.appendHistory(toolName + " (auto)", source: source, allowed: true)
            PetState.mood = .happy
            strongSelf.pending = nil
            if let screen = NSScreen.main {
                NotchPanelController.showIdlePill(on: screen)
            }
            strongSelf.updateStatusIcon("busy")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { PetState.mood = .idle }
        }
    }

    private func cancelAutoTimeout() {
        timeoutTimer?.invalidate()
        timeoutTimer = nil
    }

    // MARK: - Non-blocking events

    private func handleEvent(_ msg: [String: Any]) {
        if let notif = msg["notification"] as? [String: Any] {
            let source = detectSourceFromEvent(notif)
            let cwd = notif["cwd"] as? String ?? ""
            let sessionId = notif["session_id"] as? String ?? "default-\(source.rawValue)"
            let hookName = notif["hook_event_name"] as? String ?? ""

            let emotion = EmotionEngine.analyze(toolName: hookName, content: cwd)
            NotchPanelController.sessionTracker.upsert(
                id: sessionId, source: source, status: .active,
                cwd: cwd, tool: hookName, emotion: emotion
            )

            NSLog("ClaudeNotch notification [%@]: %@", source.displayName, hookName)
            NotchPanelController.activityLog.append(tool: hookName, detail: cwd, source: source)
            NotchPanelController.idleStateRef.isWorking = true
            NotchPanelController.idleStateRef.lastActivity = hookName
            updateStatusIcon("waiting")
            if NotchPanelController.currentState != .expanded, let screen = NSScreen.main {
                NotchPanelController.showIdlePill(on: screen)
            }
        } else if let stop = msg["stop_event"] as? [String: Any] {
            let source = detectSourceFromEvent(stop)
            let cwd = stop["cwd"] as? String ?? ""
            let sessionId = stop["session_id"] as? String ?? "default-\(source.rawValue)"

            NotchPanelController.sessionTracker.upsert(
                id: sessionId, source: source, status: .completed,
                cwd: cwd, tool: "stop", emotion: .happy
            )

            NSLog("ClaudeNotch [%@]: stopped", source.displayName)
            PetState.mood = .happy
            updateStatusIcon("done")
            SoundPlayer.play(.allowed)
            NotchPanelController.idleStateRef.isWorking = false
            NotchPanelController.idleStateRef.lastActivity = ""

            let stopReason = stop["stop_reason"] as? String
            let message: String
            if let reason = stopReason, !reason.isEmpty {
                message = reason
            } else {
                message = "Task completed"
            }
            NotchPanelController.showCompletion(source: source, message: message, cwd: cwd)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { PetState.mood = .idle }
        }
    }

    // MARK: - Activity detail extraction

    private func activityDetail(toolName: String, toolInput: [String: Any]) -> String {
        switch toolName.lowercased() {
        case "bash":
            return toolInput["command"] as? String ?? ""
        case "read":
            return toolInput["file_path"] as? String ?? ""
        case "edit", "write":
            return toolInput["file_path"] as? String ?? ""
        case "grep":
            let pattern = toolInput["pattern"] as? String ?? ""
            let path = toolInput["path"] as? String ?? ""
            return "\(pattern) in \(path)"
        case "glob":
            return toolInput["pattern"] as? String ?? ""
        case "agent":
            return toolInput["prompt"] as? String ?? toolInput["description"] as? String ?? ""
        default:
            let pieces = toolInput.values.compactMap { $0 as? String }
            return pieces.joined(separator: " ").prefix(80).description
        }
    }

    // MARK: - Source detection

    private func detectSource(_ hookInput: [String: Any]) -> AgentSource {
        if let name = hookInput["hook_event_name"] as? String {
            if name.lowercased().contains("cursor") { return .cursor }
        }
        if let tool = hookInput["tool_input"] as? [String: Any],
           let desc = tool["description"] as? String,
           desc.lowercased().contains("cursor") {
            return .cursor
        }
        return .claude
    }

    private func detectSourceFromEvent(_ event: [String: Any]) -> AgentSource {
        let hookName = event["hook_event_name"] as? String ?? ""
        if hookName.contains("afterFileEdit") || hookName.contains("beforeShellExecution") {
            return .cursor
        }
        if let src = event["source"] as? String, src.lowercased().contains("cursor") {
            return .cursor
        }
        return .claude
    }
}

// MARK: - Pending prompt wrapper

private final class PendingPrompt {
    let hookInput: [String: Any]
    let source: AgentSource
    private let reply: ([String: Any]) -> Void

    init(hookInput: [String: Any], reply: @escaping ([String: Any]) -> Void, source: AgentSource = .claude) {
        self.hookInput = hookInput
        self.reply = reply
        self.source = source
    }

    func completeAllow() { reply(["behavior": "allow"]) }

    func completeDeny(message: String?) {
        if let message = message {
            reply(["behavior": "deny", "message": message])
        } else {
            reply(["behavior": "deny"])
        }
    }
}
