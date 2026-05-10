import AppKit

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

    static func jump(cwd: String? = nil, source: AgentSource? = nil) {
        if let source = source {
            jumpToSource(source)
            return
        }
        let terminals = detectRunning()
        guard let target = terminals.first else {
            NSLog("TerminalJumper: no terminal app detected")
            return
        }
        activate(target)
    }

    static func jumpToSource(_ source: AgentSource) {
        NSLog("TerminalJumper: jumpToSource(%@)", source.rawValue)
        switch source {
        case .cursor:
            activate(.cursor)
        case .claude, .codex:
            // Claude Code and Codex usually run in a terminal — find the best one
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
