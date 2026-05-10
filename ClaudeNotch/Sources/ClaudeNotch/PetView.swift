import SwiftUI

// MARK: - Pet mood (driven by Claude state)

enum PetMood: Equatable {
    case idle
    case thinking
    case happy
    case sad
    case sleeping
}

// MARK: - Interaction reactions

enum PetReaction {
    case none
    case petted       // 摸头 → 开心眯眼
    case poked        // 戳一下 → 惊讶跳起
    case spun         // 连续点 → 转圈
    case heart        // 摸很多次 → 冒爱心
    case wave         // 挥手打招呼
}

// MARK: - Global pet state

enum PetState {
    static var enabled: Bool = true
    static var mood: PetMood = .idle
}

// MARK: - Animated pixel cat

final class PetAnimationState: ObservableObject {
    @Published var bounceOffset: CGFloat = 0
    @Published var eyesClosed: Bool = false
    @Published var tailAngle: Double = 0
    @Published var facing: CGFloat = 1
    @Published var walkOffset: CGFloat = 0
    @Published var zzz: Bool = false

    // Interaction state
    @Published var reaction: PetReaction = .none
    @Published var jumpOffset: CGFloat = 0
    @Published var rotationAngle: Double = 0
    @Published var showHeart: Bool = false
    @Published var showBubble: String = ""
    @Published var squish: CGFloat = 1.0
    @Published var isHovered: Bool = false
    @Published var hoverScale: CGFloat = 1.0

    private var bounceTimer: Timer?
    private var blinkTimer: Timer?
    private var tailTimer: Timer?
    private var walkTimer: Timer?
    private var tick: Int = 0

    var tapCount: Int = 0
    private var tapResetTimer: Timer?

    // MARK: - Hover interaction

    func handleHoverEnter() {
        isHovered = true
        hoverScale = 1.5
        if reaction == .none {
            showBubble = "Hi!"
            eyesClosed = true
            squish = 0.9
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.eyesClosed = false
                self?.squish = 1.0
            }
        }
    }

    func handleHoverExit() {
        isHovered = false
        hoverScale = 1.0
        if showBubble == "Hi!" {
            showBubble = ""
        }
    }

    // MARK: - Tap interaction

    func handleTap() {
        tapCount += 1
        tapResetTimer?.invalidate()
        tapResetTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.tapCount = 0
        }

        if tapCount >= 5 {
            triggerReaction(.heart)
            tapCount = 0
        } else if tapCount >= 3 {
            triggerReaction(.spun)
        } else if tapCount == 2 {
            triggerReaction(.poked)
        } else {
            triggerReaction(.petted)
        }
    }

    func triggerReaction(_ r: PetReaction) {
        reaction = r
        switch r {
        case .none:
            break
        case .petted:
            eyesClosed = true
            squish = 0.85
            showBubble = "♪"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.eyesClosed = false
                self?.squish = 1.0
                self?.showBubble = ""
                self?.reaction = .none
            }
        case .poked:
            jumpOffset = -8
            showBubble = "!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.jumpOffset = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showBubble = ""
                self?.reaction = .none
            }
        case .spun:
            showBubble = "~"
            spinAnimation(steps: 8, current: 0)
        case .heart:
            showHeart = true
            eyesClosed = true
            squish = 0.9
            showBubble = ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.showHeart = false
                self?.eyesClosed = false
                self?.squish = 1.0
                self?.reaction = .none
            }
        case .wave:
            showBubble = "Hi!"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showBubble = ""
                self?.reaction = .none
            }
        }
    }

    private func spinAnimation(steps: Int, current: Int) {
        guard current < steps else {
            rotationAngle = 0
            showBubble = ""
            reaction = .none
            return
        }
        rotationAngle = Double(current + 1) * (360.0 / Double(steps))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.spinAnimation(steps: steps, current: current + 1)
        }
    }

    // MARK: - Idle animation loop

    func start(mood: PetMood) {
        stop()
        tick = 0
        bounceOffset = 0
        jumpOffset = 0
        walkOffset = 0
        zzz = false

        // Skip the bounce timer for moods with no actual bounce — otherwise it
        // re-publishes bounceOffset = 0 every 0.4s, marking the SwiftUI subtree
        // dirty and forcing the idle pill to repaint forever (visible flicker
        // on macOS 26).
        if mood == .thinking || mood == .happy || mood == .sleeping {
            bounceTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
                guard let s = self else { return }
                if s.reaction != .none { return }
                s.tick += 1
                switch mood {
                case .idle, .sad:
                    break
                case .thinking:
                    s.bounceOffset = s.bounceOffset == 0 ? -2 : 0
                case .happy:
                    s.bounceOffset = s.bounceOffset == 0 ? -3 : 0
                case .sleeping:
                    s.bounceOffset = s.bounceOffset == 0 ? -1 : 0
                    s.zzz = s.tick % 4 < 2
                }
            }
        }

        // Blink + tail timers are also skipped for .idle / .sad. On macOS 26 the
        // VisualEffectView background + NSPanel at .screenSaver level repaints
        // the whole pill on every @Published willChange, producing a visible
        // 0.6s pulse that looks like the island is appearing/disappearing.
        if mood != .idle && mood != .sad {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
                guard let s = self else { return }
                if mood == .sleeping || s.reaction != .none { return }
                s.eyesClosed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if s.reaction == .none { s.eyesClosed = false }
                }
            }

            tailTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                guard let s = self else { return }
                s.tailAngle = s.tailAngle == 0 ? 20 : (s.tailAngle == 20 ? -10 : 0)
            }
        }

        if mood == .thinking {
            walkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let s = self else { return }
                if s.reaction != .none { return }
                s.walkOffset += s.facing * 2
                if s.walkOffset > 30 { s.facing = -1 }
                if s.walkOffset < -30 { s.facing = 1 }
            }
        }
    }

    func stop() {
        bounceTimer?.invalidate()
        blinkTimer?.invalidate()
        tailTimer?.invalidate()
        walkTimer?.invalidate()
        bounceTimer = nil
        blinkTimer = nil
        tailTimer = nil
        walkTimer = nil
    }
}

// MARK: - The pixel cat view

struct PixelPetView: View {
    var mood: PetMood = .idle
    @ObservedObject var anim: PetAnimationState
    var interactive: Bool = true

    var body: some View {
        ZStack {
            // Speech bubble / reaction emoji
            if !anim.showBubble.isEmpty {
                Text(anim.showBubble)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.5))
                    .cornerRadius(6)
                    .offset(x: anim.walkOffset + 14, y: -18 + anim.bounceOffset)
            }

            // Floating hearts
            if anim.showHeart {
                heartParticles
                    .offset(x: anim.walkOffset, y: -20 + anim.bounceOffset)
            }

            // Zzz for sleeping
            if mood == .sleeping && anim.zzz && anim.reaction == .none {
                Text("z")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.4))
                    .offset(x: anim.walkOffset + 12, y: -14 + anim.bounceOffset)
            }

            // The cat body
            petBody
                .offset(x: anim.walkOffset, y: anim.bounceOffset + anim.jumpOffset)
                .scaleEffect(x: anim.facing * anim.squish, y: anim.squish)
                .rotationEffect(.degrees(anim.rotationAngle))
        }
        .scaleEffect(anim.hoverScale)
        .animation(.spring(response: 0.3, dampingFraction: 0.5, blendDuration: 0), value: anim.hoverScale)
        .frame(width: 80, height: 28)
        .contentShape(Rectangle())
        .background(
            interactive
                ? AnyView(HoverTrackingView(
                    onEnter: { anim.handleHoverEnter() },
                    onExit: { anim.handleHoverExit() }
                  ))
                : AnyView(EmptyView())
        )
        .onTapGesture {
            if interactive {
                anim.handleTap()
                SoundPlayer.play(.allowed)
            }
        }
        .onAppear { anim.start(mood: mood) }
        .onChange(of: mood) { newMood in
            anim.start(mood: newMood)
        }
        .onDisappear { anim.stop() }
    }

    private var heartParticles: some View {
        HStack(spacing: 3) {
            Text("❤")
                .font(.system(size: 8))
                .offset(y: -2)
            Text("❤")
                .font(.system(size: 6))
                .offset(y: -6)
            Text("❤")
                .font(.system(size: 7))
                .offset(y: -3)
        }
    }

    private var petBody: some View {
        ZStack {
            ear.offset(x: -5, y: -8)
            ear.offset(x: 5, y: -8)

            RoundedRectangle(cornerRadius: 3)
                .fill(catColor)
                .frame(width: 14, height: 10)
                .offset(y: -3)

            if anim.eyesClosed || mood == .sleeping {
                Rectangle().fill(Color.black).frame(width: 2, height: 1).offset(x: -3, y: -4)
                Rectangle().fill(Color.black).frame(width: 2, height: 1).offset(x: 3, y: -4)
            } else if anim.reaction == .poked {
                Circle().fill(Color.black).frame(width: 3.5, height: 3.5).offset(x: -3, y: -4)
                Circle().fill(Color.black).frame(width: 3.5, height: 3.5).offset(x: 3, y: -4)
            } else {
                eye(happy: mood == .happy).offset(x: -3, y: -4)
                eye(happy: mood == .happy).offset(x: 3, y: -4)
            }

            // Blush when petted or heart
            if anim.reaction == .petted || anim.reaction == .heart {
                Circle().fill(Color.pink.opacity(0.4)).frame(width: 3, height: 2).offset(x: -5, y: -2)
                Circle().fill(Color.pink.opacity(0.4)).frame(width: 3, height: 2).offset(x: 5, y: -2)
            }

            mouthShape

            RoundedRectangle(cornerRadius: 3)
                .fill(catColor)
                .frame(width: 16, height: 8)
                .offset(y: 5)

            Circle().fill(pawColor).frame(width: 4, height: 4).offset(x: -5, y: 9)
            Circle().fill(pawColor).frame(width: 4, height: 4).offset(x: 5, y: 9)

            Capsule()
                .fill(tailColor)
                .frame(width: 10, height: 3)
                .rotationEffect(.degrees(anim.tailAngle), anchor: .leading)
                .offset(x: 12, y: 5)
        }
    }

    private var catColor: Color { Color(red: 0.95, green: 0.75, blue: 0.3) }
    private var pawColor: Color { Color(red: 0.85, green: 0.65, blue: 0.2) }
    private var tailColor: Color { Color(red: 0.90, green: 0.70, blue: 0.25) }

    private var ear: some View {
        Triangle()
            .fill(catColor)
            .frame(width: 6, height: 5)
    }

    private func eye(happy: Bool) -> some View {
        Group {
            if happy {
                Text("^")
                    .font(.system(size: 5, weight: .black))
                    .foregroundColor(.black)
            } else {
                Circle()
                    .fill(Color.black)
                    .frame(width: 2.5, height: 2.5)
            }
        }
    }

    private var mouthShape: some View {
        Group {
            if anim.reaction == .petted || anim.reaction == .heart || mood == .happy {
                Text("w")
                    .font(.system(size: 5, weight: .bold))
                    .foregroundColor(Color(red: 0.6, green: 0.3, blue: 0.2))
                    .offset(y: -1)
            } else if anim.reaction == .poked {
                Text("o")
                    .font(.system(size: 5, weight: .bold))
                    .foregroundColor(Color(red: 0.6, green: 0.3, blue: 0.2))
                    .offset(y: -1)
            } else if mood == .sad {
                Text("︵")
                    .font(.system(size: 4))
                    .foregroundColor(Color(red: 0.6, green: 0.3, blue: 0.2))
                    .offset(y: -0.5)
            } else {
                Circle()
                    .fill(Color(red: 0.6, green: 0.3, blue: 0.2))
                    .frame(width: 2, height: 1.5)
                    .offset(y: -1)
            }
        }
    }
}

// MARK: - Hover tracking (works with nonactivating NSPanel)

private struct HoverTrackingView: NSViewRepresentable {
    let onEnter: () -> Void
    let onExit: () -> Void

    func makeNSView(context: Context) -> HoverNSView {
        let v = HoverNSView()
        v.onEnter = onEnter
        v.onExit = onExit
        return v
    }

    func updateNSView(_ nsView: HoverNSView, context: Context) {
        nsView.onEnter = onEnter
        nsView.onExit = onExit
    }
}

private final class HoverNSView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        onEnter?()
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
    }
}

// MARK: - Triangle shape for ears

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
