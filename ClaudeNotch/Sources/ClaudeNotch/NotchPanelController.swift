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

/// Panel background: solid-black notch-extension shape when fused with a
/// physical notch (topInset > 0), frosted rounded rect otherwise.
private struct FusableBackground: View {
    let topInset: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        if topInset > 0 {
            NotchFusionShape(bottomRadius: cornerRadius).fill(Color.black)
        } else {
            NotchBackground(shape: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

// MARK: - Notch geometry (exact hardware cutout via safeAreaInsets)

struct NotchGeometry {
    let screen: NSScreen
    let hasNotch: Bool
    let isFakeNotch: Bool
    /// Physical cutout size in points; zero on screens without a notch.
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    /// Outward fillet where the fusion shape meets the screen's top edge.
    static let topFillet: CGFloat = 6
    /// Visible strip below the notch that holds idle pill content.
    static let idleStripHeight: CGFloat = 34

    init(screen: NSScreen) {
        self.screen = screen
        // Debug aid for developing on non-notch Macs: simulate a notch on any
        // screen, e.g. CLAUDE_NOTCH_FAKE_NOTCH=200x32 (width x height in points).
        if let fake = ProcessInfo.processInfo.environment["CLAUDE_NOTCH_FAKE_NOTCH"],
           !fake.isEmpty,
           let main = NSScreen.main,
           main === screen {
            let parts = fake.lowercased().split(separator: "x").compactMap { Double($0) }
            hasNotch = true
            isFakeNotch = true
            notchWidth = parts.count == 2 ? CGFloat(parts[0]) : 200
            notchHeight = parts.count == 2 ? CGFloat(parts[1]) : 32
            return
        }
        let safeTop = Self.runtimeSafeAreaTop(for: screen)
        if safeTop > 0 {
            hasNotch = true
            isFakeNotch = false
            notchHeight = safeTop
            let left = Self.runtimeAuxiliaryTopWidth(for: screen, key: "auxiliaryTopLeftArea")
            let right = Self.runtimeAuxiliaryTopWidth(for: screen, key: "auxiliaryTopRightArea")
            let width = (left > 0 || right > 0) ? screen.frame.width - left - right : 200
            notchWidth = width > 0 && width < screen.frame.width ? width : 200
        } else {
            // Notch hardware ships with macOS 12+, so pre-12 systems never have one.
            hasNotch = false
            isFakeNotch = false
            notchWidth = 0
            notchHeight = 0
        }
    }

    private static func runtimeSafeAreaTop(for screen: NSScreen) -> CGFloat {
        let selector = NSSelectorFromString("safeAreaInsets")
        guard screen.responds(to: selector),
              let value = screen.value(forKey: "safeAreaInsets") as? NSValue else {
            return 0
        }
        return value.edgeInsetsValue.top
    }

    private static func runtimeAuxiliaryTopWidth(for screen: NSScreen, key: String) -> CGFloat {
        let selector = NSSelectorFromString(key)
        guard screen.responds(to: selector),
              let value = screen.value(forKey: key) as? NSValue else {
            return 0
        }
        return value.rectValue.width
    }

    func idleSize(petEnabled: Bool) -> NSSize {
        if hasNotch {
            return NSSize(width: notchWidth + 2 * Self.topFillet,
                          height: notchHeight + Self.idleStripHeight)
        }
        return NSSize(width: petEnabled ? 240 : 160, height: petEnabled ? 38 : 32)
    }

    /// Window size for an expanded panel whose visible content is `content` points tall.
    func expandedSize(content: NSSize) -> NSSize {
        guard hasNotch else { return content }
        return NSSize(width: max(content.width, notchWidth + 2 * Self.topFillet),
                      height: content.height + notchHeight)
    }

    func origin(for size: NSSize) -> NSPoint {
        if hasNotch {
            // Fusion: glued to the physical top edge, centered on the notch.
            // User drag offsets are ignored — the shape must stay attached.
            return NSPoint(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.maxY - size.height)
        }
        let centerX = NotchPanelController.userCenterX ?? screen.frame.midX
        let x = max(screen.frame.minX, min(centerX - size.width / 2, screen.frame.maxX - size.width))
        let y = NotchPanelController.userY ?? (screen.visibleFrame.maxY - size.height)
        let clampedY = max(screen.frame.minY, min(y, screen.frame.maxY - size.height))
        return NSPoint(x: x, y: clampedY)
    }
}

/// Black shape that extends the physical notch downward: outward fillets at the
/// screen's top edge, rounded corners at the bottom — same silhouette as the
/// hardware cutout, so the panel reads as the notch itself growing taller.
struct NotchFusionShape: Shape {
    var topFillet: CGFloat = NotchGeometry.topFillet
    var bottomRadius: CGFloat = 12

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + topFillet, y: rect.minY + topFillet),
                       control: CGPoint(x: rect.minX + topFillet, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + topFillet, y: rect.maxY - bottomRadius))
        p.addQuadCurve(to: CGPoint(x: rect.minX + topFillet + bottomRadius, y: rect.maxY),
                       control: CGPoint(x: rect.minX + topFillet, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - topFillet - bottomRadius, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - topFillet, y: rect.maxY - bottomRadius),
                       control: CGPoint(x: rect.maxX - topFillet, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - topFillet, y: rect.minY + topFillet))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - topFillet, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Keyable panel (accepts keyboard + first-click events)

private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }

    private var initialMouseScreen: NSPoint = .zero
    private var initialOrigin: NSPoint = .zero
    private var isDragging = false

    override func mouseDown(with event: NSEvent) {
        if NotchPanelController.dragEnabled && NotchPanelController.currentState == .idle
            && !NotchPanelController.fusionActive {
            initialMouseScreen = NSEvent.mouseLocation
            initialOrigin = frame.origin
            isDragging = false
        }
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard NotchPanelController.dragEnabled,
              NotchPanelController.currentState == .idle,
              !NotchPanelController.fusionActive,
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

    static func settlePetToIdle() {
        // If a new permission popped the panel back open during the 1.2s settle delay,
        // leave that .thinking mood alone — the new request still wants attention.
        guard currentState != .expanded else { return }

        PetState.mood = .idle
        idleState.update(
            elapsed: elapsedString(),
            petEnabled: PetState.enabled,
            petMood: .idle,
            sessionSources: sessionTracker.activeSources,
            sessionCount: sessionTracker.activeCount
        )
        // Clear the "working" flag so PulsingDot (which loops a forever
        // withAnimation on opacity) and the lingering lastActivity text both
        // disappear — otherwise the idle pill keeps repainting and visibly
        // flashes on macOS 26.
        idleState.isWorking = false
        idleState.lastActivity = ""

        // Hard-freeze: kill ALL pet timers (bounce, blink, tail, walk). Each of
        // those triggers a @Published change that marks the SwiftUI subtree
        // dirty; combined with the visual-effect blur background and an NSPanel
        // at .maximumWindow level on macOS 26, the redraws were visible as a
        // full-island flicker after auto-allow. We accept losing the tail wag /
        // blink during idle in exchange for a stable pill.
        petAnim.stop()
    }

    fileprivate(set) static var currentState: PanelState = .hidden
    enum PanelState { case hidden, idle, expanded }
    private static var isAnimating = false

    /// User-dragged position; nil = default center
    static var userCenterX: CGFloat?
    static var userY: CGFloat?
    /// Drag mode — off by default, toggled from status bar menu
    static var dragEnabled = false

    /// True while the visible panel is fused with a physical notch (drag disabled).
    private(set) static var fusionActive = false

    private struct PermissionPresentation {
        let hookInput: [String: Any]
        let source: AgentSource
        let onAllow: () -> Void
        let onDeny: () -> Void
    }

    private struct CompletionPresentation {
        let source: AgentSource
        let message: String?
        let cwd: String?
        let launchContext: AgentLaunchContext
    }

    private enum ExpandedPresentation {
        case permission(PermissionPresentation)
        case completion(CompletionPresentation)
        case activityFeed
    }

    private static var activePresentation: ExpandedPresentation?

    /// Screen the panel should live on: prefer the built-in notch display,
    /// fall back to the focused screen.
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first {
            let geo = NotchGeometry(screen: $0)
            return geo.hasNotch && !geo.isFakeNotch
        }
            ?? NSScreen.screens.first { NotchGeometry(screen: $0).hasNotch }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    // MARK: - Screen change handling (dock/undock, resolution switch)

    private static var screenObserver: NSObjectProtocol?

    private static func installScreenObserverIfNeeded() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { _ in
            handleScreenParametersChange()
        }
    }

    private static func handleScreenParametersChange() {
        guard let screen = targetScreen() else { return }
        switch currentState {
        case .idle:
            // Geometry may have changed entirely — rebuild the pill from scratch.
            mainPanel?.orderOut(nil)
            mainPanel = nil
            currentState = .hidden
            showIdlePill(on: screen)
        case .expanded:
            rebuildExpandedPresentation(on: screen)
        case .hidden:
            break
        }
    }

    private static func rebuildExpandedPresentation(on screen: NSScreen) {
        isAnimating = false
        switch activePresentation {
        case .permission(let presentation):
            present(
                hookInput: presentation.hookInput,
                source: presentation.source,
                onAllow: presentation.onAllow,
                onDeny: presentation.onDeny
            )
        case .completion(let presentation):
            showCompletion(
                source: presentation.source,
                message: presentation.message,
                cwd: presentation.cwd,
                launchContext: presentation.launchContext
            )
        case .activityFeed:
            showActivityFeed()
        case nil:
            collapseExpandedToIdle(on: screen)
        }
    }

    private static func collapseExpandedToIdle(on screen: NSScreen) {
        removeKeyMonitor()
        onEscAction = nil
        onEnterAction = nil
        activePresentation = nil
        mainPanel?.orderOut(nil)
        mainPanel = nil
        currentState = .hidden
        fusionActive = false
        showIdlePill(on: screen)
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
        guard let screen = targetScreen() else { return }
        let geo = NotchGeometry(screen: screen)
        activePresentation = .permission(PermissionPresentation(
            hookInput: hookInput,
            source: source,
            onAllow: onAllow,
            onDeny: onDeny
        ))

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
            topInset: geo.notchHeight,
            onAllow: {
                onEscAction = nil; onEnterAction = nil
                PetState.mood = .happy
                animateTo(.idle)
                onAllow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { PetState.mood = .idle }
            },
            onDeny: {
                onEscAction = nil; onEnterAction = nil
                PetState.mood = .sad
                animateTo(.idle)
                onDeny()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { PetState.mood = .idle }
            },
            onJump: {
                TerminalJumper.jump(cwd: hookInput["cwd"] as? String, source: source)
            }
        )

        let host = FirstMouseHostingView(rootView: root)
        let size = geo.expandedSize(content: NSSize(width: 380, height: 220))
        host.frame = NSRect(origin: .zero, size: size)

        onEscAction = {
            PetState.mood = .sad
            removeKeyMonitor()
            animateTo(.idle)
            onDeny()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { PetState.mood = .idle }
        }
        onEnterAction = {
            PetState.mood = .happy
            removeKeyMonitor()
            animateTo(.idle)
            onAllow()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { PetState.mood = .idle }
        }

        transitionPanel(to: host, size: size, state: .expanded, on: screen)
    }

    // MARK: - Completion notification (expanded banner, auto-dismiss)

    static func showCompletion(source: AgentSource, message: String? = nil, cwd: String? = nil,
                               launchContext: AgentLaunchContext = .unknown) {
        stopRefreshTimer()
        guard let screen = targetScreen() else { return }
        let geo = NotchGeometry(screen: screen)
        activePresentation = .completion(CompletionPresentation(
            source: source,
            message: message,
            cwd: cwd,
            launchContext: launchContext
        ))

        let root = NotchCompletionView(
            source: source,
            launchContext: launchContext,
            message: message ?? "Task completed",
            elapsed: elapsedString(),
            petEnabled: PetState.enabled,
            petAnim: petAnim,
            topInset: geo.notchHeight,
            onJump: {
                TerminalJumper.jump(cwd: cwd, source: source, launchContext: launchContext)
                animateTo(.idle)
            },
            onDismiss: {
                animateTo(.idle)
            }
        )

        let host = FirstMouseHostingView(rootView: root)
        let size = geo.expandedSize(content: NSSize(width: 340, height: 80))
        host.frame = NSRect(origin: .zero, size: size)
        onEscAction = {
            removeKeyMonitor()
            animateTo(.idle)
        }

        transitionPanel(to: host, size: size, state: .expanded, on: screen)
    }

    // MARK: - Activity feed (expanded live code view)

    static func showActivityFeed() {
        stopRefreshTimer()
        isAnimating = false
        guard let screen = targetScreen() else { return }
        let geo = NotchGeometry(screen: screen)
        activePresentation = .activityFeed

        let root = NotchActivityFeedView(
            activityLog: activityLog,
            elapsed: elapsedString(),
            topInset: geo.notchHeight,
            onClose: {
                animateTo(.idle)
            }
        )

        let host = FirstMouseHostingView(rootView: root)
        let size = geo.expandedSize(content: NSSize(width: 380, height: 260))
        host.frame = NSRect(origin: .zero, size: size)

        onEscAction = {
            removeKeyMonitor()
            animateTo(.idle)
        }

        transitionPanel(to: host, size: size, state: .expanded, on: screen)
    }

    // MARK: - Idle pill

    static func showIdlePill(on screen: NSScreen) {
        activePresentation = nil
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

        let geo = NotchGeometry(screen: screen)
        let idleSize = geo.idleSize(petEnabled: petOn)

        let root = NotchIdlePillView(
            state: idleState,
            petAnim: petAnim,
            activityLog: activityLog,
            compact: geo.hasNotch,
            topInset: geo.notchHeight
        )
        let host = FirstMouseHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: idleSize)
        transitionPanel(to: host, size: idleSize, state: .idle, on: screen)

        startRefreshTimer()
    }

    // MARK: - Dismiss all

    static func dismiss() {
        stopRefreshTimer()
        removeKeyMonitor()
        onEscAction = nil
        onEnterAction = nil
        activePresentation = nil
        fadeOutAndRemove()
        currentState = .hidden
    }

    static func dismissIdle() {
        if currentState == .idle { dismiss() }
    }

    // MARK: - Animated transitions (Dynamic Island style)

    private static func animateTo(_ target: PanelState, on screen: NSScreen? = nil) {
        guard !isAnimating else { return }
        switch target {
        case .idle:
            guard let screen = screen ?? targetScreen() else { return }
            activePresentation = nil
            if currentState == .expanded, let pan = mainPanel, !fusionActive {
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
                // Fusion: morph the notch shape directly back into the pill
                // (Dynamic Island contraction) instead of fading out.
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
        } else if let screen = targetScreen() {
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

    }

    private static func removeKeyMonitor() {
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
    }

    private static func transitionPanel(to content: NSView, size: NSSize, state: PanelState, on screen: NSScreen) {
        installScreenObserverIfNeeded()
        let geo = NotchGeometry(screen: screen)
        fusionActive = geo.hasNotch
        let targetFrame = NSRect(origin: geo.origin(for: size), size: size)

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
            let pan = createPanel(content: content, frame: targetFrame, on: screen)
            let pillSize = geo.idleSize(petEnabled: PetState.enabled)
            let startFrame = NSRect(origin: geo.origin(for: pillSize), size: pillSize)
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

    private static func createPanel(content: NSView, frame: NSRect, on screen: NSScreen) -> KeyablePanel {
        let pan = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: frame.size),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        // Use screenSaver level on notch Macs so pill appears above menu bar in
        // notch area — but NOT .maximumWindow (= CGShieldingWindowLevel ~8500),
        // which is reserved for system shielding (login / lock screen) and on
        // macOS 26 fights with the window server, causing the panel to be
        // periodically hidden/shown by the system.
        if NotchGeometry(screen: screen).hasNotch {
            pan.level = .screenSaver
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
    /// Physical notch height; > 0 switches to the fused (notch-extension) look.
    let topInset: CGFloat
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onJump: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = NotchTheme.current(topInset > 0 ? .dark : scheme)
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
        .padding(.top, topInset)
        .background(FusableBackground(topInset: topInset, cornerRadius: 22))
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
    let compact: Bool
    /// Physical notch height; > 0 switches to the fused (notch-extension) look.
    let topInset: CGFloat

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if topInset > 0 {
            // Fused: content lives in the visible strip below the hardware notch,
            // drawn on a solid black notch-extension shape.
            pillRow
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: NotchGeometry.idleStripHeight)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .background(NotchFusionShape(bottomRadius: 12).fill(Color.black))
                .contentShape(Rectangle())
                .onTapGesture {
                    NotchPanelController.showActivityFeed()
                }
        } else {
            pillRow
                .padding(.horizontal, compact ? 10 : 12)
                .padding(.vertical, compact ? 3 : 4)
                .background(NotchBackground(shape: Capsule()))
                .contentShape(Capsule())
                .onTapGesture {
                    NotchPanelController.showActivityFeed()
                }
        }
    }

    private var pillRow: some View {
        let theme = NotchTheme.current(topInset > 0 ? .dark : scheme)
        return HStack(spacing: compact ? 4 : 6) {
            if state.petEnabled {
                // Fused pill has a taller strip on solid black — let the pet
                // render at its natural size instead of the compact downscale.
                PixelPetView(mood: state.petMood, anim: petAnim, interactive: true)
                    .frame(width: topInset > 0 ? 56 : (compact ? 44 : 60),
                           height: topInset > 0 ? 28 : (compact ? 24 : 28))
                    .scaleEffect(topInset > 0 ? 1.0 : (compact ? 0.74 : 0.9))
            } else {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
            }

            // Activity ticker or session info
            if state.isWorking, !state.lastActivity.isEmpty {
                Text(state.lastActivity)
                    .font(.system(size: compact ? 8 : 9, weight: .medium, design: .monospaced))
                    .foregroundColor(Color.green.opacity(0.9))
                    .lineLimit(1)
                    .frame(maxWidth: compact ? 86 : 120, alignment: .leading)
            } else if state.sessionCount > 0 {
                HStack(spacing: compact ? 2 : 3) {
                    ForEach(0..<state.sessionSources.count, id: \.self) { i in
                        let src = state.sessionSources[i]
                        Text(src.icon)
                            .font(.system(size: compact ? 7 : 8, weight: .bold))
                            .foregroundColor(src.color)
                            .padding(.horizontal, compact ? 2 : 3)
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
                    .font(.system(size: compact ? 9 : 10, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.textTertiary)
            }

            // Working indicator
            if state.isWorking {
                PulsingDot()
            }
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
            // Use value-driven animation so the repeatForever cycle
            // attaches to `pulse` and is torn down cleanly when the
            // view leaves the hierarchy. Using `withAnimation` inside
            // `.onAppear` leaks the animation context into the parent
            // and keeps re-rendering the entire pill on macOS 26.
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                       value: pulse)
            .onAppear { pulse = true }
            .onDisappear { pulse = false }
    }
}

// MARK: - Completion notification view

private struct NotchCompletionView: View {
    let source: AgentSource
    let launchContext: AgentLaunchContext
    let message: String
    let elapsed: String
    let petEnabled: Bool
    @ObservedObject var petAnim: PetAnimationState
    /// Physical notch height; > 0 switches to the fused (notch-extension) look.
    let topInset: CGFloat
    let onJump: () -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var jumpLabel: String {
        TerminalJumper.jumpLabel(for: source, launchContext: launchContext)
    }

    var body: some View {
        let theme = NotchTheme.current(topInset > 0 ? .dark : scheme)
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
        .padding(.top, topInset)
        .background(FusableBackground(topInset: topInset, cornerRadius: 22))
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
    /// Physical notch height; > 0 switches to the fused (notch-extension) look.
    let topInset: CGFloat
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
        .padding(.top, topInset)
        .background(feedBackground)
        .onAppear { stream.start(activityLog: activityLog) }
        .onDisappear { stream.stop() }
    }

    @ViewBuilder private var feedBackground: some View {
        if topInset > 0 {
            NotchFusionShape(bottomRadius: 22).fill(Color.black)
        } else {
            Color.black.opacity(0.9)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .strokeBorder(Color.green.opacity(0.15), lineWidth: 0.5)
                )
        }
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
