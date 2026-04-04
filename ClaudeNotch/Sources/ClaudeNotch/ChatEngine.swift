import Foundation

struct ChatMessage {
    let role: String   // "user" or "assistant"
    let text: String
    let time: Date
}

final class ChatEngine: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isLoading: Bool = false

    private var lastCwd: String = NSHomeDirectory()
    private let claudePath: String

    init() {
        let candidates = [
            "/Users/\(NSUserName())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        claudePath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            ?? "claude"
    }

    func updateCwd(_ cwd: String) {
        if !cwd.isEmpty { lastCwd = cwd }
    }

    func send(_ text: String) {
        let userMsg = ChatMessage(role: "user", text: text, time: Date())
        messages.append(userMsg)
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let reply = self.callClaude(text)
            DispatchQueue.main.async {
                self.isLoading = false
                let assistantMsg = ChatMessage(role: "assistant", text: reply, time: Date())
                self.messages.append(assistantMsg)
            }
        }
    }

    func clear() {
        messages.removeAll()
    }

    private let processTimeoutSec: TimeInterval = 60

    private func callClaude(_ prompt: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: claudePath)
        proc.arguments = ["-p", prompt, "--output-format", "text"]
        proc.currentDirectoryURL = URL(fileURLWithPath: lastCwd)

        var env = ProcessInfo.processInfo.environment
        env["NO_COLOR"] = "1"
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = stdout
        proc.standardError = stderr

        do {
            try proc.run()
        } catch {
            return "(claude CLI 启动失败: \(error.localizedDescription))"
        }

        // Read pipes BEFORE waitUntilExit to avoid deadlock when output exceeds pipe buffer
        var outData = Data()
        var errData = Data()
        let readGroup = DispatchGroup()

        readGroup.enter()
        DispatchQueue.global().async {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global().async {
            errData = stderr.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        let deadline = Date().addingTimeInterval(processTimeoutSec)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if proc.isRunning {
            proc.terminate()
            _ = readGroup.wait(timeout: .now() + .seconds(2))
            return "(超时: claude 未在\(Int(processTimeoutSec))秒内响应)"
        }
        _ = readGroup.wait(timeout: .now() + .seconds(5))

        if let text = String(data: outData, encoding: .utf8), !text.isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let errText = String(data: errData, encoding: .utf8), !errText.isEmpty {
            return "(错误: \(errText.trimmingCharacters(in: .whitespacesAndNewlines)))"
        }
        return "(无响应)"
    }
}
