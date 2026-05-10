import Foundation
import SwiftUI

// MARK: - Agent source identification

enum AgentSource: String, CaseIterable {
    case claude = "claude"
    case cursor = "cursor"

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .cursor: return "Cursor"
        }
    }

    var color: Color {
        switch self {
        case .claude: return Color(red: 0.9, green: 0.5, blue: 0.2)
        case .cursor: return Color(red: 0.2, green: 0.6, blue: 1.0)
        }
    }

    var icon: String {
        switch self {
        case .claude: return "◆"
        case .cursor: return "▶"
        }
    }
}

// MARK: - Session state

enum SessionStatus {
    case active
    case waiting
    case idle
    case completed
}

struct AgentSession {
    let id: String
    var source: AgentSource
    var status: SessionStatus
    var cwd: String
    var lastTool: String
    var lastActivity: Date
    var emotion: PetMood
}

// MARK: - Multi-session tracker

final class SessionTracker: ObservableObject {
    @Published var sessions: [String: AgentSession] = [:]

    var activeCount: Int {
        sessions.values.filter { $0.status != .completed }.count
    }

    var activeSources: [AgentSource] {
        let set = Set(sessions.values.filter { $0.status != .completed }.map { $0.source })
        return AgentSource.allCases.filter { set.contains($0) }
    }

    var dominantEmotion: PetMood {
        let active = sessions.values.filter { $0.status != .completed }
        if active.isEmpty { return .idle }
        if active.contains(where: { $0.status == .waiting }) { return .thinking }
        let emotions = active.map { $0.emotion }
        if emotions.contains(.sad) { return .sad }
        if emotions.contains(.happy) { return .happy }
        if emotions.contains(.thinking) { return .thinking }
        return .idle
    }

    func upsert(id: String, source: AgentSource, status: SessionStatus,
                cwd: String, tool: String, emotion: PetMood) {
        sessions[id] = AgentSession(
            id: id, source: source, status: status,
            cwd: cwd, lastTool: tool, lastActivity: Date(), emotion: emotion
        )
        cleanStale()
    }


    private func cleanStale() {
        let cutoff = Date().addingTimeInterval(-300)
        sessions = sessions.filter {
            $0.value.lastActivity > cutoff || $0.value.status == .waiting
        }
    }
}

// MARK: - Emotion analysis engine

struct EmotionEngine {
    private static let sadWords = [
        "error", "fail", "bug", "crash", "exception", "panic",
        "denied", "reject", "invalid", "broken", "wrong", "abort",
        "timeout", "fatal", "permission denied", "not found",
    ]
    private static let happyWords = [
        "success", "pass", "complete", "done", "fixed", "resolved",
        "created", "built", "approved", "allow", "saved", "ok",
        "installed", "deployed", "merged",
    ]
    private static let thinkWords = [
        "search", "analy", "think", "investigat", "debug",
        "read", "scan", "check", "review", "look", "compar",
        "evaluat", "examin",
    ]

    static func analyze(toolName: String, content: String) -> PetMood {
        let lower = (content + " " + toolName).lowercased()
        let sad   = sadWords.filter   { lower.contains($0) }.count
        let happy = happyWords.filter { lower.contains($0) }.count
        let think = thinkWords.filter { lower.contains($0) }.count

        if sad > happy && sad > think { return .sad }
        if happy > sad && happy > think { return .happy }
        if think > 0 { return .thinking }
        return .idle
    }

    static func analyzeHook(toolName: String, toolInput: [String: Any]) -> PetMood {
        let pieces = toolInput.values.compactMap { $0 as? String }
        return analyze(toolName: toolName, content: pieces.joined(separator: " "))
    }
}
