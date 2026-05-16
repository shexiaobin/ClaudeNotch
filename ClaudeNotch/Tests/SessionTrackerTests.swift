import Foundation

enum PetMood: Equatable {
    case idle
    case thinking
    case happy
    case sad
    case sleeping
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct SessionTrackerTests {
    static func main() {
        let tracker = SessionTracker()

        expect(
            tracker.completeIfActive(id: "orphan", source: .codex, cwd: "/tmp") == false,
            "orphan stop should be ignored"
        )

        tracker.upsert(
            id: "active-codex",
            source: .codex,
            status: .active,
            cwd: "/tmp",
            tool: "Bash",
            emotion: .idle
        )
        expect(
            tracker.completeIfActive(id: "active-codex", source: .codex, cwd: "/tmp") == true,
            "active stop should complete"
        )
        expect(
            tracker.completeIfActive(id: "active-codex", source: .codex, cwd: "/tmp") == false,
            "duplicate stop should be ignored"
        )

        tracker.upsert(
            id: "same-id",
            source: .codex,
            status: .active,
            cwd: "/tmp",
            tool: "Bash",
            emotion: .idle
        )
        tracker.upsert(
            id: "same-id",
            source: .cursor,
            status: .active,
            cwd: "/tmp",
            tool: "Bash",
            emotion: .idle
        )
        expect(
            tracker.completeIfActive(id: "same-id", source: .codex, cwd: "/tmp") == true,
            "codex session should complete independently"
        )
        expect(
            tracker.completeIfActive(id: "same-id", source: .cursor, cwd: "/tmp") == true,
            "cursor session with same id should still be active"
        )

        print("OK: SessionTracker stop gating")
    }
}
