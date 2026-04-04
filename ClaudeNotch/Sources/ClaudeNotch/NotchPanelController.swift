import AppKit
import SwiftUI

// MARK: - Panel lifecycle (single panel with animated transitions)

enum NotchPanelController {
    private static var mainPanel: NSPanel?
    private static var sessionStart: Date?
    private static var refreshTimer: Timer?
    private static var petAnim = PetAnimationState()
    static var sessionTracker = SessionTracker()
    private static var idleState = IdlePillState()

    private static var currentState: PanelState = .hidden
    enum PanelState { case hidden, idle, expanded }

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
                PetState.mood = .happy
                animateTo(.idle, on: screen)
                onAllow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { PetState.mood = .idle }
            },
            onDeny: {
                PetState.mood = .sad
                animateTo(.idle, on: screen)
                onDeny()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { PetState.mood = .idle }
            },
            onJump: {
                TerminalJumper.jump(cwd: hookInput["cwd"] as? String)
            }
        )

        let host = NSHostingView(rootView: root)
        let w: CGFloat = 380
        let h: CGFloat = 220
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        transitionPanel(to: host, size: NSSize(width: w, height: h), state: .expanded, on: screen)
    }

    // MARK: - Idle pill

    static func showIdlePill(on screen: NSScreen) {
        if currentState == .expanded { return }
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

        let w: CGFloat = petOn ? 240 : 160
        let h: CGFloat = petOn ? 38 : 32

        let root = NotchIdlePillView(state: idleState, petAnim: petAnim)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        transitionPanel(to: host, size: NSSize(width: w, height: h), state: .idle, on: screen)

        startRefreshTimer()
    }

    // MARK: - Dismiss all

    static func dismiss() {
        stopRefreshTimer()
        fadeOutAndRemove()
        currentState = .hidden
    }

    static func dismissIdle() {
        if currentState == .idle { dismiss() }
    }

    // MARK: - Animated transitions (Dynamic Island style)

    private static func animateTo(_ target: PanelState, on screen: NSScreen) {
        switch target {
        case .idle:
            showIdlePill(on: screen)
        case .expanded:
            break
        case .hidden:
            dismiss()
        }
    }

    private static func transitionPanel(to content: NSView, size: NSSize, state: PanelState, on screen: NSScreen) {
        let x = screen.frame.midX - size.width / 2
        let y = screen.visibleFrame.maxY - size.height
        let targetFrame = NSRect(x: x, y: y, width: size.width, height: size.height)

        if let existing = mainPanel {
            let oldFrame = existing.frame
            existing.contentView = content

            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                existing.animator().setFrame(targetFrame, display: true)
                existing.animator().alphaValue = 1
            })

            _ = oldFrame
            currentState = state
        } else {
            let pan = createPanel(content: content, frame: targetFrame)
            let pillW: CGFloat = 160
            let pillH: CGFloat = 36
            let startFrame = NSRect(
                x: screen.frame.midX - pillW / 2,
                y: screen.visibleFrame.maxY - pillH,
                width: pillW, height: pillH
            )
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

    private static func createPanel(content: NSView, frame: NSRect) -> NSPanel {
        let pan = NSPanel(
            contentRect: NSRect(origin: .zero, size: frame.size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        pan.level = .statusBar
        pan.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pan.backgroundColor = .clear
        pan.isOpaque = false
        pan.hasShadow = true
        pan.titleVisibility = .hidden
        pan.titlebarAppearsTransparent = true
        pan.isMovableByWindowBackground = false
        pan.acceptsMouseMovedEvents = true
        pan.ignoresMouseEvents = false
        pan.contentView = content
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

    var body: some View {
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
                            .foregroundColor(.white)
                    }
                    Text(toolName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.6))
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
                        .foregroundColor(Color.white.opacity(0.4))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(4)
                }
            }

            // Content preview with Markdown
            CommandPreviewView(command: command, filePath: filePath)

            if command == nil && filePath == nil {
                SimpleMarkdownView(summary, fontSize: 10)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06))
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
                    .foregroundColor(Color.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.06))
                    .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())

                Spacer()

                Button(action: onDeny) {
                    Text("Deny")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 80)
                        .padding(.vertical, 7)
                        .background(Color.white.opacity(0.1))
                        .foregroundColor(.white)
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
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
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

    func update(elapsed: String, petEnabled: Bool, petMood: PetMood,
                sessionSources: [AgentSource] = [], sessionCount: Int = 0) {
        self.elapsed = elapsed
        self.petEnabled = petEnabled
        self.petMood = petMood
        self.sessionSources = sessionSources
        self.sessionCount = sessionCount
    }
}

// MARK: - Idle pill (multi-session indicators + pet)

private struct NotchIdlePillView: View {
    @ObservedObject var state: IdlePillState
    @ObservedObject var petAnim: PetAnimationState

    var body: some View {
        HStack(spacing: 6) {
            if state.petEnabled {
                PixelPetView(mood: state.petMood, anim: petAnim, interactive: false)
                    .frame(width: 60, height: 28)
                    .scaleEffect(0.9)
            } else {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            }

            // Multi-session source badges
            if state.sessionCount > 0 {
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
                            .foregroundColor(Color.white.opacity(0.5))
                    }
                }
            } else {
                Text("Claude")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
            }

            if !state.elapsed.isEmpty {
                Text(state.elapsed)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .clipShape(Capsule())
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .contentShape(Capsule())
        .onTapGesture {
            if state.petEnabled {
                petAnim.handleTap()
                SoundPlayer.play(.allowed)
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
