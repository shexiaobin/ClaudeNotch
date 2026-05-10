import AppKit
import SwiftUI

// MARK: - Adaptive theme colors

struct NotchTheme {
    let bgOverlay: Color
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let border: Color
    let subtleBg: Color
    let material: NSVisualEffectView.Material

    static func current(_ scheme: ColorScheme) -> NotchTheme {
        switch scheme {
        case .dark:
            return NotchTheme(
                bgOverlay: Color.black.opacity(0.7),
                textPrimary: .white,
                textSecondary: Color.white.opacity(0.8),
                textTertiary: Color.white.opacity(0.6),
                border: Color.white.opacity(0.15),
                subtleBg: Color.white.opacity(0.08),
                material: .hudWindow
            )
        case .light:
            return NotchTheme(
                bgOverlay: Color.white.opacity(0.85),
                textPrimary: Color.black.opacity(0.9),
                textSecondary: Color.black.opacity(0.7),
                textTertiary: Color.black.opacity(0.5),
                border: Color.black.opacity(0.12),
                subtleBg: Color.black.opacity(0.05),
                material: .popover
            )
        @unknown default:
            return current(.dark)
        }
    }
}

// MARK: - Adaptive background modifier

private struct NotchBackground<S: InsettableShape>: View {
    let shape: S
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = NotchTheme.current(scheme)
        ZStack {
            VisualEffectView(material: theme.material, blendingMode: .behindWindow)
            theme.bgOverlay
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.border, lineWidth: 0.5))
    }
}

// MARK: - Keyable panel (accepts keyboard + first-click events)

private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    private var initialMouseScreen: NSPoint = .zero
    private var initialOrigin: NSPoint = .zero
    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        if NotchPanelController.dragEnabled && NotchPanelController.currentState == .idle {
            initialMouseScreen = NSEvent.mouseLocation
            initialOrigin = frame.origin
            isDragging = false
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard NotchPanelController.dragEnabled,
              NotchPanelController.currentState == .idle,
              let screen = self.screen ?? NSScreen.main else { return }
        isDragging = true
        let current = NSEvent.mouseLocation
        let dx = current.x - initialMouseScreen.x
        let dy = current.y - initialMouseScreen.y
        var newOrigin = NSPoint(x: initialOrigin.x + dx, y: initialOrigin.y + dy)
        let sf = screen.frame
        newOrigin.x = max(sf.minX, min(newOrigin.x, sf.maxX - frame.width))
        newOrigin.y = max(sf.minY, min(newOrigin.y, sf.maxY - frame.height))
        setFrameOrigin(newOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            NotchPanelController.userCenterX = frame.midX
            NotchPanelController.userY = frame.origin.y
            isDragging = false
        }
        super.mouseUp(with: event)
    }
}

/// Wraps any SwiftUI view so that the first mouse click is not swallowed by the system.
private class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Panel lifecycle (single panel with animated transitions)

enum NotchPanelController {
    private static var mainPanel: KeyablePanel?
    private static var sessionStart: Date?
    private static var refreshTimer: Timer?
    private static var localKeyMonitor: Any?
    private static var globalKeyMonitor: Any?
    /// Called when ESC is pressed while expanded
    static var onEscAction: (() -> Void)?
    /// Called when Enter is pressed while expanded (permission allow)
    static var onEnterAction: (() -> Void)?
    /// Timestamp when the expanded panel appeared; Enter is ignored for 1s to avoid stray events
    private static var expandedAt: Date?
    private static var petAnim = PetAnimationState()
    static var sessionTracker = SessionTracker()
    private static var idleState = IdlePillState()
    static var activityLog = ActivityLog()
    static var idleStateRef: IdlePillState { idleState }

    fileprivate(set) static var currentState: PanelState = .hidden
    enum PanelState { case hidden, idle, expanded }
    private static var isAnimating = false

    /// User-dragged position; nil = default center
    static var userCenterX: CGFloat?
    static var userY: CGFloat?
    /// Drag mode — off by default, toggled from status bar menu
    static var dragEnabled = false

    /// Detect if the screen has a notch (MacBook Pro 2021+)
    /// On notch Macs, the menu bar height is taller (~38pt) vs normal (~25pt)
    private static func hasNotch(on screen: NSScreen) -> Bool {
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        // Notch Macs have a taller menu bar area (>30pt) to accommodate the notch
        return menuBarHeight > 30
    }

    /// Calculate notch-aware Y position for the pill/panel
    private static func panelY(for size: NSSize, on screen: NSScreen) -> CGFloat {
        if hasNotch(on: screen) {
            // Place inside the notch area — top of screen minus height
            return screen.frame.maxY - size.height
        } else {
            // Non-notch: below menu bar
            return screen.visibleFrame.maxY - size.height
        }
    }

    // MARK: - Expanded permission view (animated from pill)

    static func present(
        hookInput: [String: Any],
        source: AgentSource = .claude,
        onAllow: @escaping () -> Void,
        onDeny: @escaping () -> Void
    ) {
        stopRefreshTimer()
        if sessionStart == nil { sessionStart = Date() }
        guard let screen = NSScreen.main else { return }

        PetState.mood = .thinking

        let toolName = hookInput["tool_name"] as? String ?? "Permission"
        let toolInput = hookInput["tool_input"] as? [String: Any] ?? [:]
        let command = toolInput["command"] as? String
        let filePath = toolInput["file_path"] as? String

        let root = NotchExpandedView(
            toolName: toolName,
            command: command,
            filePath: filePath,
            summary: summarize(toolInput),
            elapsed: elapsedString(),
            source: source,
            petEnabled: PetState.enabled,
            petAnim: petAnim,
            onAllow: {
                onEscAction = nil; onEnterAction = nil
                PetState.mood = .happy
                animateTo(.idle, on: screen)
                onAllow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { PetState.mood = .idle }
            },
            onDeny: {
                onEscAction = nil; onEnterAction = nil
                PetState.mood = .sad
                animateTo(.idle, on: screen)
                onDeny()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { PetState.mood = .idle }
            },
            onJump: {
                TerminalJumper.jump(cwd: hookInput["cwd"] as? String, source: source)
            }
        )

        let host = FirstMouseHostingView(rootView: root)
        let w: CGFloat = 380
        let h: CGFloat = 220
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)

        onEscAction = {
            PetState.mood = .sad
            removeKeyMonitor()
            animateTo(.idle, on: screen)
            onDeny()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { PetState.mood = .idle }
        }
        onEnterAction = {
            PetState.mood = .happy
            removeKeyMonitor()
            animateTo(.idle, on: screen)
            onAllow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { PetState.mood = .idle }
        }

        transitionPanel(to: host, size: NSSize(width: w, height: h), state: .expanded, on: screen)
    }

    // MARK: - Completion notification (expanded banner, auto-dismiss)

    static func showCompletion(source: AgentSource, message: String? = nil, cwd: String? = nil) {
        stopRefreshTimer()
        guard let screen = NSScreen.main else { return }

        let root = NotchCompletionView(
            source: source,
            message: message ?? "Task completed",
            elapsed: elapsedString(),
            petEnabled: PetState.enabled,
            petAnim: petAnim,
            onJump: {
                TerminalJumper.jump(cwd: cwd, source: source)
                animateTo(.idle, on: screen)
            },
            onDismiss: {
                animateTo(.idle, on: screen)
            }
        )

        let host = FirstMouseHostingView(rootView: root)
        let w: CGFloat = 340
        let h: CGFloat = 80
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        onEscAction = {
            removeKeyMonitor()
            animateTo(.idle, on: screen)
        }

        transitionPanel(to: host, size: NSSize(width: w, height: h), state: .expanded, on: screen)
    }

    // MARK: - Activity feed (expanded live code view)

    static func showActivityFeed() {
        stopRefreshTimer()
        isAnimating = false
        guard let screen = NSScreen.main else { return }

        let root = NotchActivityFeedView(
            activityLog: activityLog,
            elapsed: elapsedString(),
            onClose: {
                animateTo(.idle, on: screen)
            }
        )

        let host = FirstMouseHostingView(rootView: root)
        let w: CGFloat = 380
        let h: CGFloat = 260
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)

        onEscAction = {
            removeKeyMonitor()
            animateTo(.idle, on: screen)
        }

        transitionPanel(to: host, size: NSSize(width: w, height: h), state: .expanded, on: screen)
    }

    // MARK: - Idle pill

    static func showIdlePill(on screen: NSScreen) {
        if sessionStart == nil { sessionStart = Date() }

        let petOn = PetState.enabled
        let sessions = sessionTracker.activeSources
        let count = sessionTracker.activeCount
        let emotion = sessionTracker.dominantEmotion
        if emotion != .idle { PetState.mood = emotion }

        idleState.update(
            elapsed: elapsedString(),
            petEnabled: petOn,
            petMood: PetState.mood,
            sessionSources: sessions,
            sessionCount: count
        )

        // Already showing idle pill or animating — just update data, don't rebuild
        if (currentState == .idle && mainPanel != nil) || isAnimating {
            startRefreshTimer()
            return
        }

        let w: CGFloat = petOn ? 240 : 160
        let h: CGFloat = petOn ? 38 : 32

        let root = NotchIdlePillView(state: idleState, petAnim: petAnim, activityLog: activityLog)
        let host = FirstMouseHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        transitionPanel(to: host, size: NSSize(width: w, height: h), state: .idle, on: screen)

        startRefreshTimer()
    }

    // MARK: - Dismiss all

    static func dismiss() {
        stopRefreshTimer()
        removeKeyMonitor()
        onEscAction = nil
        onEnterAction = nil
        fadeOutAndRemove()
        currentState = .hidden
    }

    static func dismissIdle() {
        if currentState == .idle { dismiss() }
    }

    // MARK: - Animated transitions (Dynamic Island style)

    private static func animateTo(_ target: PanelState, on screen: NSScreen) {
        guard !isAnimating else { return }
        switch target {
        case .idle:
            if currentState == .expanded, let pan = mainPanel {
                isAnimating = true
                currentState = .hidden
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.15
                    pan.animator().alphaValue = 0
                }, completionHandler: {
                    pan.orderOut(nil)
                    if mainPanel === pan { mainPanel = nil }
                    isAnimating = false
                    showIdlePill(on: screen)
                })
            } else {
                showIdlePill(on: screen)
            }
        case .expanded:
            break
        case .hidden:
            dismiss()
        }
    }

    static func closeExpanded() {
        guard currentState == .expanded else { return }
        if let esc = onEscAction {
            esc()
            onEscAction = nil
        } else if let screen = NSScreen.main {
            removeKeyMonitor()
            animateTo(.idle, on: screen)
        }
    }

    private static func handleKeyEvent(_ keyCode: UInt16) {
        guard currentState == .expanded else { return }
        switch keyCode {
        case 53: // ESC
            closeExpanded()
        case 36: // Enter
            if let t = expandedAt, Date().timeIntervalSince(t) < 1.0 { return }
            if let action = onEnterAction {
                onEnterAction = nil
                onEscAction = nil
                action()
            }
        default:
            break
        }
    }

    private static func installKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        expandedAt = Date()

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard currentState == .expanded else { return event }
            if event.keyCode == 53 || event.keyCode == 36 {
                handleKeyEvent(event.keyCode)
                return nil
            }
            return event
        }

        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard currentState == .expanded else { return }
            DispatchQueue.main.async { handleKeyEvent(event.keyCode) }
        }
    }

    private static func removeKeyMonitor() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let m = globalKeyMonitor { NSEvent.removeMonitor(m); globalKeyMonitor = nil }
    }

    private static func panelOrigin(for size: NSSize, on screen: NSScreen) -> NSPoint {
        let centerX = userCenterX ?? screen.frame.midX
        let x = max(screen.frame.minX, min(centerX - size.width / 2, screen.frame.maxX - size.width))
        let y = userY ?? panelY(for: size, on: screen)
        let clampedY = max(screen.frame.minY, min(y, screen.frame.maxY - size.height))
        return NSPoint(x: x, y: clampedY)
    }

    private static func transitionPanel(to content: NSView, size: NSSize, state: PanelState, on screen: NSScreen) {
        let origin = panelOrigin(for: size, on: screen)
        let targetFrame = NSRect(origin: origin, size: size)

        if state == .expanded {
            installKeyMonitor()
        } else {
            removeKeyMonitor()
        }

        if let existing = mainPanel {
            existing.contentView = content

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                existing.animator().setFrame(targetFrame, display: true)
                existing.animator().alphaValue = 1
            })

            currentState = state
        } else {
            let pan = createPanel(content: content, frame: targetFrame)
            let pillSize = NSSize(width: 160, height: 36)
            let pillOrigin = panelOrigin(for: pillSize, on: screen)
            let startFrame = NSRect(origin: pillOrigin, size: pillSize)
            pan.setFrame(startFrame, display: false)
            pan.alphaValue = 0
            pan.orderFrontRegardless()
            mainPanel = pan
            currentState = state

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                pan.animator().setFrame(targetFrame, display: true)
                pan.animator().alphaValue = 1
            })
        }
    }

    private static func fadeOutAndRemove() {
        guard let pan = mainPanel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            pan.animator().alphaValue = 0
        }, completionHandler: {
            pan.orderOut(nil)
            mainPanel = nil
        })
    }

    private static func createPanel(content: NSView, frame: NSRect) -> KeyablePanel {
        let pan = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: frame.size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        // Use screenSaver level on notch Macs so pill appears above menu bar in notch area
        if let screen = NSScreen.main, hasNotch(on: screen) {
            pan.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        } else {
            pan.level = .statusBar
        }
        pan.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pan.appearance = NSAppearance(named: .darkAqua)
        pan.backgroundColor = .clear
        pan.isOpaque = false
        pan.hasShadow = true
        pan.titleVisibility = .hidden
        pan.titlebarAppearsTransparent = true
        pan.isMovableByWindowBackground = false
        pan.acceptsMouseMovedEvents = true
        pan.ignoresMouseEvents = false
        pan.contentView = content
        pan.contentView?.wantsLayer = true
        pan.contentView?.layer?.masksToBounds = false
        pan.setFrame(frame, display: true)
        return pan
    }

    // MARK: - Refresh timer (updates elapsed + session info without recreating views)

    private static func startRefreshTimer() {
        stopRefreshTimer()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            DispatchQueue.main.async {
                let emotion = sessionTracker.dominantEmotion
                if emotion != .idle { PetState.mood = emotion }
                idleState.update(
                    elapsed: elapsedString(),
                    petEnabled: PetState.enabled,
                    petMood: PetState.mood,
                    sessionSources: sessionTracker.activeSources,
                    sessionCount: sessionTracker.activeCount
                )
            }
        }
    }

    private static func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - Helpers

    private static func elapsedString() -> String {
        guard let start = sessionStart else { return "" }
        let s = Int(Date().timeIntervalSince(start))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h\((s % 3600) / 60)m"
    }

    private static func summarize(_ input: [String: Any]) -> String {
        if let json = try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys]),
            let s = String(data: json, encoding: .utf8)
        {
            let maxLen = 600
            if s.count <= maxLen { return s }
            return String(s.prefix(maxLen)) + "…"
        }
        return String(describing: input)
    }
}

// MARK: - Expanded permission view (with Markdown preview + terminal jump + source badge)

private struct NotchExpandedView: View {
    let toolName: String
    let command: String?
    let filePath: String?
    let summary: String
    let elapsed: String
    let source: AgentSource
    let petEnabled: Bool
    @ObservedObject var petAnim: PetAnimationState
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onJump: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = NotchTheme.current(scheme)
        VStack(alignment: .leading, spacing: 10) {
            // Header row: source badge + tool + pet + elapsed
            HStack(spacing: 8) {
                toolIcon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(source.icon)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(source.color)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(source.color.opacity(0.15))
                            .cornerRadius(4)
                        Text(source.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.textPrimary)
                    }
                    Text(toolName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.textSecondary)
                }
                Spacer()
                if petEnabled {
                    PixelPetView(mood: .thinking, anim: petAnim, interactive: false)
                        .frame(width: 50, height: 24)
                        .scaleEffect(0.85)
                }
                if !elapsed.isEmpty {
                    Text(elapsed)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.subtleBg)
                        .cornerRadius(4)
                }
            }

            // Content preview with Markdown
            CommandPreviewView(command: command, filePath: filePath)

            if command == nil && filePath == nil {
                SimpleMarkdownView(summary, fontSize: 10)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.subtleBg)
                    .cornerRadius(8)
            }

            // Buttons row: Jump + Deny + Allow
            HStack(spacing: 8) {
                Button(action: onJump) {
                    HStack(spacing: 3) {
                        Text("↗")
                            .font(.system(size: 11, weight: .bold))
                        Text("Jump")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(theme.subtleBg)
                    .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                Button(action: onDeny) {
                    Text("Deny")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 80)
                        .padding(.vertical, 7)
                        .background(theme.subtleBg)
                        .foregroundColor(theme.textPrimary)
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                .keyboardShortcut("n", modifiers: .command)

                Button(action: onAllow) {
                    Text("Allow")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 80)
                        .padding(.vertical, 7)
                        .background(Color(red: 0.2, green: 0.6, blue: 1.0))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
                .keyboardShortcut("y", modifiers: .command)
            }
        }
        .padding(16)
        .background(NotchBackground(shape: RoundedRectangle(cornerRadius: 22)))
    }

    private var toolIcon: some View {
        let (icon, color) = iconForTool(toolName)
        return Text(icon)
            .font(.system(size: 16))
            .frame(width: 28, height: 28)
            .background(color.opacity(0.2))
            .cornerRadius(8)
    }

    private func iconForTool(_ name: String) -> (String, Color) {
        switch name.lowercased() {
        case "bash":                return (">_", Color.green)
        case "edit", "write":       return ("E", Color.orange)
        case "read":                return ("R", Color.blue)
        case "webfetch":            return ("W", Color.purple)
        case "websearch":           return ("S", Color.blue)
        case "mcp":                 return ("M", Color.purple)
        default:                    return ("?", Color.gray)
        }
    }
}

// MARK: - Observable idle state

final class IdlePillState: ObservableObject {
    @Published var elapsed: String = ""
    @Published var petEnabled: Bool = true
    @Published var petMood: PetMood = .idle
    @Published var sessionSources: [AgentSource] = []
    @Published var sessionCount: Int = 0
    @Published var lastActivity: String = ""
    @Published var isWorking: Bool = false

    func update(elapsed: String, petEnabled: Bool, petMood: PetMood,
                sessionSources: [AgentSource] = [], sessionCount: Int = 0) {
        self.elapsed = elapsed
        self.petEnabled = petEnabled
        self.petMood = petMood
        self.sessionSources = sessionSources
        self.sessionCount = sessionCount
    }
}

// MARK: - Activity log (recent tool calls for live feed)

struct ActivityEntry: Identifiable {
    let id = UUID()
    let time: Date
    let tool: String
    let detail: String
    let source: AgentSource
}

final class ActivityLog: ObservableObject {
    @Published var entries: [ActivityEntry] = []
    private let maxEntries = 50

    func append(tool: String, detail: String, source: AgentSource) {
        let cleaned = shortenDetail(detail)
        guard !cleaned.isEmpty else { return }
        let entry = ActivityEntry(time: Date(), tool: tool, detail: cleaned, source: source)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    private func shortenDetail(_ s: String) -> String {
        var result = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Shorten home path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if result.contains(home) {
            result = result.replacingOccurrences(of: home, with: "~")
        }
        // Take first line only
        if let nl = result.firstIndex(of: "\n") {
            result = String(result[result.startIndex..<nl])
        }
        return result
    }

    var recentLines: [String] {
        entries.suffix(8).map { e in
            let icon: String
            switch e.tool.lowercased() {
            case "bash": icon = "$"
            case "read": icon = "R"
            case "edit", "write": icon = "E"
            case "grep": icon = "?"
            case "glob": icon = "*"
            default: icon = ">"
            }
            let short = e.detail.count > 60 ? String(e.detail.prefix(60)) + "…" : e.detail
            return "\(icon) \(short)"
        }
    }
}

// MARK: - Idle pill (multi-session indicators + pet)

private struct NotchIdlePillView: View {
    @ObservedObject var state: IdlePillState
    @ObservedObject var petAnim: PetAnimationState
    @ObservedObject var activityLog: ActivityLog

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = NotchTheme.current(scheme)
        HStack(spacing: 6) {
            if state.petEnabled {
                PixelPetView(mood: state.petMood, anim: petAnim, interactive: true)
                    .frame(width: 60, height: 28)
                    .scaleEffect(0.9)
            } else {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            }

            // Activity ticker or session info
            if state.isWorking, !state.lastActivity.isEmpty {
                Text(state.lastActivity)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.green.opacity(0.9))
                    .lineLimit(1)
                    .frame(maxWidth: 120, alignment: .leading)
            } else if state.sessionCount > 0 {
                HStack(spacing: 3) {
                    ForEach(0..<state.sessionSources.count, id: \.self) { i in
                        let src = state.sessionSources[i]
                        Text(src.icon)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(src.color)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(src.color.opacity(0.15))
                            .cornerRadius(3)
                    }
                    if state.sessionCount > 1 {
                        Text("×\(state.sessionCount)")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.textTertiary)
                    }
                }
            }

            if !state.elapsed.isEmpty {
                Text(state.elapsed)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.textTertiary)
            }

            // Working indicator
            if state.isWorking {
                PulsingDot()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(NotchBackground(shape: Capsule()))
        .contentShape(Capsule())
        .onTapGesture {
            NotchPanelController.showActivityFeed()
        }
    }
}

// MARK: - Pulsing work indicator

private struct PulsingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 6, height: 6)
            .opacity(pulse ? 1.0 : 0.3)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - Completion notification view

private struct NotchCompletionView: View {
    let source: AgentSource
    let message: String
    let elapsed: String
    let petEnabled: Bool
    @ObservedObject var petAnim: PetAnimationState
    let onJump: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var jumpLabel: String {
        switch source {
        case .cursor: return "Cursor"
        case .claude, .codex: return "Terminal"
        }
    }

    var body: some View {
        let theme = NotchTheme.current(scheme)
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.2))
                    .frame(width: 32, height: 32)
                Text("✓")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.green)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(source.icon)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(source.color)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(source.color.opacity(0.15))
                        .cornerRadius(4)
                    Text("Done")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.textPrimary)
                }
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if petEnabled {
                PixelPetView(mood: .happy, anim: petAnim, interactive: false)
                    .frame(width: 50, height: 24)
                    .scaleEffect(0.85)
            }

            Button(action: onDismiss) {
                Text("OK")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(theme.subtleBg)
                    .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: onJump) {
                HStack(spacing: 3) {
                    Text("↗")
                        .font(.system(size: 11, weight: .bold))
                    Text(jumpLabel)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(source.color)
                .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(NotchBackground(shape: RoundedRectangle(cornerRadius: 22)))
    }
}

// MARK: - Activity feed view (hacker-style auto-scrolling terminal)

private let codeSnippets: [String] = [
    "analyzing dependencies...",
    "import Foundation",
    "func validate(_ input: [String]) -> Bool {",
    "  guard !input.isEmpty else { return false }",
    "  let result = input.filter { $0.count > 0 }",
    "  return result.count == input.count",
    "}",
    "struct Response: Codable {",
    "  let status: Int",
    "  let data: [String: Any]",
    "}",
    "compiling module 'ClaudeNotch'...",
    "linking objects...",
    "let config = ProcessInfo.processInfo.environment",
    "socket.connect(path)",
    "NSLog(\"processing request...\")",
    "reading file contents...",
    "diffing changes...",
    "applying patch to source...",
    "extension String {",
    "  var sanitized: String { trimmingCharacters(in: .whitespaces) }",
    "}",
    "class Observer: NSObject {",
    "  override func observeValue(forKeyPath kp: String?, ...) {",
    "    DispatchQueue.main.async { self.update() }",
    "  }",
    "}",
    "running static analysis...",
    "checking type constraints...",
    "resolving symbol references...",
    "optimizing IR...",
    "emitting object code...",
    "for item in entries { process(item) }",
    "let data = try JSONSerialization.data(withJSONObject: obj)",
    "if let screen = NSScreen.main { present(on: screen) }",
    "Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true)",
    "view.frame = NSRect(x: 0, y: 0, width: w, height: h)",
]

private final class CodeStreamState: ObservableObject {
    struct Line: Identifiable {
        let id = UUID()
        let text: String
        let color: Color
        let isReal: Bool
    }

    @Published var lines: [Line] = []
    private var timer: Timer?
    private var snippetIndex = 0
    private let maxLines = 30
    private weak var activityLog: ActivityLog?
    private var lastSeenCount = 0

    func start(activityLog: ActivityLog) {
        self.activityLog = activityLog
        let realEntries = activityLog.entries

        // Seed with existing real entries
        for e in realEntries.suffix(10) {
            lines.append(Line(
                text: "\(toolPrefix(e.tool)) \(e.detail)",
                color: toolColor(e.tool),
                isReal: true
            ))
        }
        lastSeenCount = realEntries.count

        snippetIndex = Int.random(in: 0..<codeSnippets.count)
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let log = activityLog else { addFakeLine(); return }
        let entries = log.entries

        if entries.count > lastSeenCount {
            // New real activity arrived — show real lines
            for e in entries[lastSeenCount...] {
                let line = Line(
                    text: "\(toolPrefix(e.tool)) \(e.detail)",
                    color: toolColor(e.tool),
                    isReal: true
                )
                lines.append(line)
                if lines.count > maxLines { lines.removeFirst() }
            }
            lastSeenCount = entries.count
        } else {
            // Idle — show fake code stream
            addFakeLine()
        }
    }

    private func addFakeLine() {
        let snippet = codeSnippets[snippetIndex % codeSnippets.count]
        snippetIndex += 1
        let brightness = Double.random(in: 0.4...1.0)
        let line = Line(
            text: snippet,
            color: Color(red: 0, green: brightness, blue: brightness * 0.3),
            isReal: false
        )
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst() }
    }

    private func toolPrefix(_ tool: String) -> String {
        switch tool.lowercased() {
        case "bash", "shell", "beforeshellexecution": return "$"
        case "read": return "📖"
        case "edit", "write", "afterfileedit": return "✏️"
        case "grep": return "🔍"
        case "glob": return "📁"
        case "stop": return "✅"
        default: return "▸"
        }
    }

    private func toolColor(_ tool: String) -> Color {
        switch tool.lowercased() {
        case "bash", "shell", "beforeshellexecution":
            return Color(red: 0.3, green: 1.0, blue: 0.3)
        case "read":
            return Color(red: 0.3, green: 0.8, blue: 1.0)
        case "edit", "write", "afterfileedit":
            return Color(red: 1.0, green: 0.7, blue: 0.2)
        case "stop":
            return Color(red: 0.5, green: 1.0, blue: 0.5)
        default:
            return Color(red: 0.2, green: 0.9, blue: 0.4)
        }
    }
}

private struct NotchActivityFeedView: View {
    @ObservedObject var activityLog: ActivityLog
    let elapsed: String
    let onClose: () -> Void

    @StateObject private var stream = CodeStreamState()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header — tap anywhere to close
            HStack {
                HStack(spacing: 5) {
                    PulsingDot()
                    Text("LIVE")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundColor(Color.green)
                }
                Spacer()
                Text(elapsed)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.green.opacity(0.5))
                Button(action: { stream.stop(); onClose() }) {
                    Text("✕")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(Color.green.opacity(0.5))
                        .frame(width: 20, height: 20)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(10)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // Streaming terminal
            ZStack {
                Color.black.opacity(0.95)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(stream.lines) { line in
                        Text(line.text)
                            .font(.system(size: 10, weight: line.isReal ? .semibold : .regular, design: .monospaced))
                            .foregroundColor(line.color.opacity(line.isReal ? 1.0 : 0.7))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 1)
                    }
                    // Cursor
                    HackerCursor()
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                // Top fade
                VStack {
                    LinearGradient(
                        gradient: Gradient(colors: [Color.black.opacity(0.95), Color.black.opacity(0)]),
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: 30)
                    Spacer()
                }
                .allowsHitTesting(false)
            }
            .frame(height: 200)
            .cornerRadius(10)
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .background(
            Color.black.opacity(0.9)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(Color.green.opacity(0.15), lineWidth: 0.5)
                )
        )
        .onAppear { stream.start(activityLog: activityLog) }
        .onDisappear { stream.stop() }
    }
}

// MARK: - Blinking cursor

private struct HackerCursor: View {
    @State private var visible = true

    var body: some View {
        Text("█")
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(Color.green)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    visible.toggle()
                }
            }
    }
}

// MARK: - NSVisualEffectView bridge

private struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
