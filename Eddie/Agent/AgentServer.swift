import Foundation

/// Listens on the agent socket while "Let AI agents control Eddie" is on. Each connection is one agent
/// (via the `eddie-mcp` helper); requests run on the main actor, one at a time.
final class AgentServer: @unchecked Sendable {
    static let shared = AgentServer()

    private var listenFD: Int32 = -1
    private(set) var path = ""
    private let lock = NSLock()
    var isRunning: Bool { lock.withLock { listenFD >= 0 } }

    /// Starts listening (replacing a stale socket file). Only this user can connect.
    func start(path: String = AgentProtocol.socketPath,
               handler: @escaping @Sendable (String, [String: Any]) async -> AgentTools.Reply) throws {
        stop()
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        lock.withLock { listenFD = fd; self.path = path }
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd: fd, handler: handler) }
    }

    func stop() {
        let fd = lock.withLock { () -> Int32 in let f = listenFD; listenFD = -1; return f }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(path)
        }
    }

    private func acceptLoop(fd: Int32, handler: @escaping @Sendable (String, [String: Any]) async -> AgentTools.Reply) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if lock.withLock({ listenFD != fd }) { return }   // stopped
                continue
            }
            Thread.detachNewThread { Self.serve(client, handler: handler) }
        }
    }

    private static func serve(_ fd: Int32, handler: @escaping @Sendable (String, [String: Any]) async -> AgentTools.Reply) {
        defer { close(fd) }
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return }
            pending.append(contentsOf: chunk[0..<n])
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<nl]
                pending.removeSubrange(pending.startIndex...nl)
                guard let request = AgentProtocol.decode(Data(line)) else { continue }
                let id = request["id"] ?? NSNull()
                let tool = request["tool"] as? String ?? ""
                let args = request["args"] as? [String: Any] ?? [:]
                let box = ReplyBox()
                let done = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    box.reply = await handler(tool, args)
                    done.signal()
                }
                done.wait()
                let reply = box.reply ?? .fail("No reply.")
                var out: [String: Any] = ["id": id, "ok": reply.ok, "text": reply.text]
                if let image = reply.image { out["image"] = image.base64EncodedString() }
                guard writeAll(fd, AgentProtocol.encode(out)) else { return }
            }
        }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    private final class ReplyBox: @unchecked Sendable { var reply: AgentTools.Reply? }
}
