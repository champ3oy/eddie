import AppKit
import Foundation

/// eddie-mcp — the MCP server AI agents run (stdio). It relays tool calls to the running Eddie app over a
/// private local socket, so every edit happens in Eddie where the user can see and undo it.
///
///   Claude Code:     claude mcp add eddie -- /Applications/Eddie.app/Contents/MacOS/eddie-mcp
///   Claude Desktop:  {"mcpServers": {"eddie": {"command": "/Applications/Eddie.app/Contents/MacOS/eddie-mcp"}}}

let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
let stdout = FileHandle.standardOutput

func send(_ message: [String: Any]) {
    stdout.write(AgentProtocol.encode(message))
}

func respond(_ id: Any, result: [String: Any]) {
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

func respondError(_ id: Any, code: Int, _ message: String) {
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

func log(_ text: String) {
    FileHandle.standardError.write(Data("eddie-mcp: \(text)\n".utf8))
}

// MARK: Connection to Eddie

final class EddieConnection {
    private var fd: Int32 = -1
    private var buffer = Data()
    private var nextID = 1

    private func connectOnce() -> Bool {
        let path = AgentProtocol.socketPath
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(s); return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
        if ok { fd = s } else { close(s) }
        return ok
    }

    private var eddieRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: AgentProtocol.appBundleID).isEmpty
    }

    /// Connects, opening Eddie first if it isn't running.
    func ensureConnected() -> String? {
        if fd >= 0 { return nil }
        if connectOnce() { return nil }
        if !eddieRunning, ProcessInfo.processInfo.environment["EDDIE_AGENT_SOCKET"] == nil {
            log("opening Eddie")
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", "-b", AgentProtocol.appBundleID]
            try? open.run()
            open.waitUntilExit()
            for _ in 0..<60 {
                Thread.sleep(forTimeInterval: 0.25)
                if connectOnce() { return nil }
            }
        }
        return "Eddie isn't accepting AI agents. Open Eddie → Settings (⌘,) → AI Agents and turn on “Let AI agents control Eddie”, then try again."
    }

    func call(_ tool: String, _ args: [String: Any]) -> [String: Any] {
        if let problem = ensureConnected() { return ["ok": false, "text": problem] }
        let id = nextID
        nextID += 1
        let data = AgentProtocol.encode(["id": id, "tool": tool, "args": args])
        let sent = data.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return false }
                off += n
            }
            return true
        }
        guard sent, let line = readLine() else {
            close(fd)
            fd = -1
            return ["ok": false, "text": "Lost the connection to Eddie (was it quit?). Try again."]
        }
        return AgentProtocol.decode(line) ?? ["ok": false, "text": "Eddie sent something unreadable."]
    }

    private func readLine() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return Data(line)
            }
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

let eddie = EddieConnection()

// MARK: MCP over stdio

func handle(_ message: [String: Any]) {
    guard let method = message["method"] as? String else { return }   // a response from the client; ignore
    let id = message["id"]
    let params = message["params"] as? [String: Any] ?? [:]
    switch method {
    case "initialize":
        let asked = params["protocolVersion"] as? String ?? supportedVersions[0]
        respond(id ?? NSNull(), result: [
            "protocolVersion": supportedVersions.contains(asked) ? asked : supportedVersions[0],
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "eddie", "title": "Eddie video editor", "version": AgentProtocol.version],
            "instructions": AgentProtocol.instructions,
        ])
    case "ping":
        if let id { respond(id, result: [:]) }
    case "tools/list":
        let tools = AgentProtocol.tools.map { ["name": $0.name, "description": $0.description, "inputSchema": $0.input] as [String: Any] }
        if let id { respond(id, result: ["tools": tools]) }
    case "tools/call":
        guard let id else { return }
        guard let name = params["name"] as? String, AgentProtocol.tools.contains(where: { $0.name == name }) else {
            respondError(id, code: -32602, "Unknown tool \(params["name"] ?? "")")
            return
        }
        let reply = eddie.call(name, params["arguments"] as? [String: Any] ?? [:])
        var content: [[String: Any]] = [["type": "text", "text": reply["text"] as? String ?? ""]]
        if let image = reply["image"] as? String { content.append(["type": "image", "data": image, "mimeType": "image/jpeg"]) }
        respond(id, result: ["content": content, "isError": !(reply["ok"] as? Bool ?? false)])
    default:
        if method.hasPrefix("notifications/") { return }
        if let id { respondError(id, code: -32601, "Method not found: \(method)") }
    }
}

setvbuf(Darwin.stdout, nil, _IOLBF, 0)
while let line = readLine(strippingNewline: true) {
    if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
    guard let message = AgentProtocol.decode(Data(line.utf8)) else {
        respondError(NSNull(), code: -32700, "Parse error")
        continue
    }
    handle(message)
}
