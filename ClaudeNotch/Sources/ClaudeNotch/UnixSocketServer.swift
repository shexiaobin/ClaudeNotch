import Foundation
import Darwin

/// Length-prefixed JSON over Unix stream socket. Supports two message types:
/// 1. `hook_input` — permission request (blocks until reply)
/// 2. `notification` / `stop_event` — fire-and-forget status updates
final class UnixSocketServer {
    private let path: String
    private let onPermission: ([String: Any], @escaping ([String: Any]) -> Void) -> Void
    private let onEvent: ([String: Any]) -> Void
    private var listenFD: Int32 = -1
    private var acceptQueue: DispatchQueue
    private var connectionQueue: DispatchQueue

    init(
        path: String,
        onPermission: @escaping ([String: Any], @escaping ([String: Any]) -> Void) -> Void,
        onEvent: @escaping ([String: Any]) -> Void
    ) {
        self.path = path
        self.onPermission = onPermission
        self.onEvent = onEvent
        self.acceptQueue = DispatchQueue(label: "claude-notch.accept", qos: .userInitiated)
        self.connectionQueue = DispatchQueue(label: "claude-notch.connection", qos: .userInitiated, attributes: .concurrent)
    }

    func start() throws {
        let maxSocketPathBytes = 103
        let pathByteCount = path.lengthOfBytes(using: .utf8)
        guard pathByteCount <= maxSocketPathBytes else {
            throw NSError(
                domain: "ClaudeNotchSocket",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unix socket path is too long (\(pathByteCount) bytes, max \(maxSocketPathBytes)): \(path)"
                ]
            )
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        listenFD = fd
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let sunPathCap = maxSocketPathBytes
        withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
            var i = 0
            while i < sunPathCap && pathBytes[i] != 0 {
                ptr.advanced(by: i).pointee = pathBytes[i]
                i += 1
            }
            ptr.advanced(by: i).pointee = 0
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindErr = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                bind(fd, sap, len)
            }
        }
        guard bindErr == 0 else {
            let e = errno
            close(fd)
            listenFD = -1
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e))
        }
        guard listen(fd, 16) == 0 else {
            let e = errno
            close(fd)
            listenFD = -1
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e))
        }
        acceptLoop()
    }

    private func acceptLoop() {
        acceptQueue.async { [weak self] in
            guard let s = self else { return }
            while true {
                let conn = accept(s.listenFD, nil, nil)
                guard conn >= 0 else { break }
                s.connectionQueue.async {
                    s.handleConnection(conn)
                }
            }
        }
    }

    private func handleConnection(_ fd: Int32) {
        defer { close(fd) }
        do {
            let data = try readFramed(fd: fd)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            if let hookInput = obj["hook_input"] as? [String: Any] {
                let sem = DispatchSemaphore(value: 0)
                var response: [String: Any] = ["behavior": "deny", "message": "ClaudeNotch: no response"]
                DispatchQueue.main.async {
                    self.onPermission(hookInput) { out in
                        response = out
                        sem.signal()
                    }
                }
                _ = sem.wait(timeout: .now() + .seconds(600))
                let outData = try JSONSerialization.data(withJSONObject: response)
                try writeFramed(fd: fd, payload: outData)
            } else {
                DispatchQueue.main.async { self.onEvent(obj) }
                let ack = try JSONSerialization.data(withJSONObject: ["ok": true])
                try writeFramed(fd: fd, payload: ack)
            }
        } catch {
            NSLog("ClaudeNotch connection error: %@", String(describing: error))
        }
    }

    // MARK: - Framing

    private func readFramed(fd: Int32) throws -> Data {
        var lenBE = [UInt8](repeating: 0, count: 4)
        try readExact(fd: fd, into: &lenBE)
        let n =
            (UInt32(lenBE[0]) << 24) | (UInt32(lenBE[1]) << 16) | (UInt32(lenBE[2]) << 8)
                | UInt32(lenBE[3])
        guard n > 0, n < 50_000_000 else { throw NSError(domain: "ClaudeNotch", code: 1) }
        var buf = [UInt8](repeating: 0, count: Int(n))
        try readExact(fd: fd, into: &buf)
        return Data(buf)
    }

    private func readExact(fd: Int32, into buffer: inout [UInt8]) throws {
        var got = 0
        while got < buffer.count {
            let r = read(fd, &buffer[got], buffer.count - got)
            guard r > 0 else { throw NSError(domain: "ClaudeNotch", code: 2) }
            got += r
        }
    }

    private func writeFramed(fd: Int32, payload: Data) throws {
        var be = [UInt8](repeating: 0, count: 4)
        let n = UInt32(payload.count)
        be[0] = UInt8((n >> 24) & 0xff)
        be[1] = UInt8((n >> 16) & 0xff)
        be[2] = UInt8((n >> 8) & 0xff)
        be[3] = UInt8(n & 0xff)
        var header = Data(be)
        header.append(payload)
        try header.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            let total = header.count
            while sent < total {
                let w = write(fd, base + sent, total - sent)
                guard w > 0 else { throw NSError(domain: "ClaudeNotch", code: 3) }
                sent += w
            }
        }
    }
}
