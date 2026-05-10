import AppKit

enum AgentLaunchContext: String {
    case app
    case terminal
    case unknown

    init(rawValue: String?) {
        switch rawValue?.lowercased() {
        case "app": self = .app
        case "terminal": self = .terminal
        default: self = .unknown
        }
    }
}

enum TerminalJumper {

    enum TerminalApp: String, CaseIterable {
        case iterm2    = "com.googlecode.iterm2"
        case terminal  = "com.apple.Terminal"
        case warp      = "dev.warp.Warp-Stable"
        case ghostty   = "com.mitchellh.ghostty"
        case kitty     = "net.kovidgoyal.kitty"
        case alacritty = "org.alacritty"
        case cursor    = "com.todesktop.230313mzl4w4u92"
        case vscode    = "com.microsoft.VSCode"

        var displayName: String {
            switch self {
            case .iterm2:    return "iTerm2"
            case .terminal:  return "Terminal"
            case .warp:      return "Warp"
            case .ghostty:   return "Ghostty"
            case .kitty:     return "Kitty"
            case .alacritty: return "Alacritty"
            case .cursor:    return "Cursor"
            case .vscode:    return "VS Code"
            }
        }
    }

    static func detectRunning() -> [TerminalApp] {
        let ids = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        return TerminalApp.allCases.filter { ids.contains($0.rawValue) }
    }

    static func jump(cwd: String? = nil, source: AgentSource? = nil,
                     launchContext: AgentLaunchContext = .unknown) {
        if let source = source {
            jumpToSource(source, launchContext: launchContext)
            return
        }
        let terminals = detectRunning()
        guard let target = terminals.first else {
            NSLog("TerminalJumper: no terminal app detected")
            return
        }
        activate(target)
    }

    static func jumpToSource(_ source: AgentSource, launchContext: AgentLaunchContext = .unknown) {
        NSLog("TerminalJumper: jumpToSource(%@, %@)", source.rawValue, launchContext.rawValue)
        switch source {
        case .cursor:
            if launchContext == .terminal {
                activatePreferredTerminal(for: source)
            } else {
                activate(.cursor)
            }
        case .codex:
            switch launchContext {
            case .app:
                activateBundleIdentifier("com.openai.codex", displayName: "Codex")
            case .terminal:
                activatePreferredTerminal(for: source)
            case .unknown:
                if isBundleRunning("com.openai.codex") {
                    activateBundleIdentifier("com.openai.codex", displayName: "Codex")
                } else {
                    activatePreferredTerminal(for: source)
                }
            }
        case .claude:
            activatePreferredTerminal(for: source)
        }
    }

    static func jumpLabel(for source: AgentSource,
                          launchContext: AgentLaunchContext = .unknown) -> String {
        switch source {
        case .cursor:
            return launchContext == .terminal ? (terminalLabel() ?? "Terminal") : "Cursor"
        case .codex:
            if launchContext == .terminal { return terminalLabel() ?? "Terminal" }
            if launchContext == .app || isBundleRunning("com.openai.codex") { return "Codex" }
            return terminalLabel() ?? "Terminal"
        case .claude:
            return terminalLabel() ?? "Terminal"
        }
    }

    static func activatePreferredTerminal(for source: AgentSource) {
        let preferred: [TerminalApp] = [.iterm2, .warp, .ghostty, .kitty, .terminal, .alacritty]
        let running = detectRunning()
        if let match = preferred.first(where: { running.contains($0) }) {
            activate(match)
        } else if let any = running.first {
            activate(any)
        } else {
            NSLog("TerminalJumper: no terminal found for %@", source.displayName)
        }
    }

    static func isBundleRunning(_ bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    static func activateBundleIdentifier(_ bundleIdentifier: String, displayName: String) {
        let proc = Process()
        proc.launchPath = "/usr/bin/open"
        proc.arguments = ["-b", bundleIdentifier]
        do {
            try proc.run()
            NSLog("TerminalJumper: opened %@", displayName)
        } catch {
            NSLog("TerminalJumper: failed to open %@: %@", displayName, error.localizedDescription)
        }
    }

    static func activate(_ app: TerminalApp) {
        let proc = Process()
        proc.launchPath = "/usr/bin/open"
        proc.arguments = ["-a", app.displayName]
        do {
            try proc.run()
            NSLog("TerminalJumper: opened %@", app.displayName)
        } catch {
            NSLog("TerminalJumper: failed to open %@: %@", app.displayName, error.localizedDescription)
        }
    }

    static func terminalLabel() -> String? {
        let t = detectRunning()
        if t.isEmpty { return nil }
        if t.count == 1 { return t[0].displayName }
        return t.map { $0.displayName }.joined(separator: "/")
    }
}
