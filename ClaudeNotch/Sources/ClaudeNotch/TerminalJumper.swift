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

    static func jump(cwd: String? = nil) {
        let terminals = detectRunning()
        guard let target = terminals.first else {
            NSLog("TerminalJumper: no terminal app detected")
            return
        }
        activate(target)
    }

    static func activate(_ app: TerminalApp) {
        guard let running = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == app.rawValue })
        else { return }
        running.activate(options: [.activateAllWindows])
        NSLog("TerminalJumper: activated %@", app.displayName)
    }

    static func terminalLabel() -> String? {
        let t = detectRunning()
        if t.isEmpty { return nil }
        if t.count == 1 { return t[0].displayName }
        return t.map { $0.displayName }.joined(separator: "/")
    }
}
