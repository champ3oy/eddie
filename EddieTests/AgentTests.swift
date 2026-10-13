import XCTest
@testable import Eddie

/// The MCP server for outside AI agents: the helper's MCP protocol, the socket bridge, and the tools.
final class AgentBridgeTests: XCTestCase {
    var helperURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/eddie-mcp") }

    /// Runs the real eddie-mcp helper like an agent would (MCP over stdio) against a test socket.
    func testHelperSpeaksMCPAndRelaysToEddie() async throws {
        // Tool calls run on the main thread in Eddie, so the waiting in this test happens off it.
        try await Task.detached { try self.runHelperConversation() }.value
    }

    nonisolated func runHelperConversation() throws {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("eddie-\(UUID().uuidString.prefix(6)).sock").path
        let calls = CallLog()
        try AgentServer.shared.start(path: socket) { tool, args in
            calls.add(tool)
            if tool == "get_frame" { return AgentTools.Reply(text: "frame", image: Data([0xFF, 0xD8, 0xFF])) }
            return AgentTools.Reply(text: "got \(tool) with \(args.keys.sorted())")
        }
        defer { AgentServer.shared.stop() }

        let p = Process()
        p.executableURL = helperURL
        p.environment = ["EDDIE_AGENT_SOCKET": socket]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        defer { p.terminate() }
        let reader = LineReader(output.fileHandleForReading)

        func send(_ m: [String: Any]) { input.fileHandleForWriting.write(AgentProtocol.encode(m)) }

        send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
              "params": ["protocolVersion": "2025-06-18", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]])
        let initResult = try XCTUnwrap(reader.next()?["result"] as? [String: Any])
        XCTAssertEqual(initResult["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual((initResult["serverInfo"] as? [String: Any])?["name"] as? String, "eddie")
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])

        send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let tools = try XCTUnwrap((reader.next()?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names), ["get_timeline", "list_projects", "open_project", "new_project", "add_media", "edit",
                                    "get_frame", "set_grade", "auto_grade", "control", "export"])
        let edit = try XCTUnwrap(tools.first { $0["name"] as? String == "edit" })
        XCTAssertTrue((edit["description"] as? String ?? "").contains("ken_burns"), "the edit tool documents every action")

        send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "edit", "arguments": ["actions": [["type": "split", "at": 1]]]]])
        let call = try XCTUnwrap(reader.next())
        XCTAssertEqual(call["id"] as? Int, 3)
        let content = try XCTUnwrap((call["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "got edit with [\"actions\"]")
        XCTAssertEqual((call["result"] as? [String: Any])?["isError"] as? Bool, false)

        send(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "get_frame", "arguments": [:]]])
        let frame = try XCTUnwrap((reader.next()?["result"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(frame.last?["type"] as? String, "image")
        XCTAssertEqual(frame.last?["mimeType"] as? String, "image/jpeg")

        send(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "rm_rf", "arguments": [:]]])
        XCTAssertNotNil(reader.next()?["error"], "unknown tools are refused by the helper")
        send(["jsonrpc": "2.0", "id": 6, "method": "ping"])
        XCTAssertEqual(reader.next()?["id"] as? Int, 6)
        XCTAssertEqual(calls.all, ["edit", "get_frame"])
    }

    func testSocketIsPrivate() throws {
        let socket = FileManager.default.temporaryDirectory.appendingPathComponent("eddie-\(UUID().uuidString.prefix(6)).sock").path
        try AgentServer.shared.start(path: socket) { _, _ in AgentTools.Reply(text: "") }
        defer { AgentServer.shared.stop() }
        let perms = try FileManager.default.attributesOfItem(atPath: socket)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600, "only this user can connect")
        AgentServer.shared.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socket), "the socket is removed when agents are turned off")
    }

    final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [String] = []
        func add(_ s: String) { lock.withLock { calls.append(s) } }
        var all: [String] { lock.withLock { calls } }
    }

    /// Reads newline-delimited JSON from the helper's stdout, with a timeout.
    final class LineReader {
        let handle: FileHandle
        var buffer = Data()
        init(_ h: FileHandle) { handle = h }
        func next(timeout: TimeInterval = 10) -> [String: Any]? {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                if let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer.removeSubrange(buffer.startIndex...nl)
                    return AgentProtocol.decode(Data(line))
                }
                let chunk = handle.availableData
                if chunk.isEmpty { return nil }
                buffer.append(chunk)
            }
            return nil
        }
    }
}

/// The tools on a real project, the way an agent would use them.
@MainActor
final class AgentToolsTests: XCTestCase {
    let blue = Bundle(for: AgentToolsTests.self).url(forResource: "normal_blue", withExtension: "mov")!
    let photo = Bundle(for: AgentToolsTests.self).url(forResource: "photo_test", withExtension: "jpg")!
    let music = Bundle(for: AgentToolsTests.self).url(forResource: "music_test", withExtension: "m4a")!

    func call(_ model: EditorModel, _ tool: String, _ args: [String: Any] = [:]) async -> AgentTools.Reply {
        await AgentTools.handle(tool, args, model: model)
    }

    func testAgentBuildsAnEdit() async throws {
        let model = EditorModel()
        var r = await call(model, "new_project", ["name": "Agent test \(UUID().uuidString.prefix(4))"])
        XCTAssertTrue(r.ok, r.text)

        r = await call(model, "add_media", ["paths": [blue.path, blue.path], "as": "clip"])
        XCTAssertTrue(r.ok, r.text)
        XCTAssertEqual(model.project.clips.count, 2)
        XCTAssertTrue(r.text.contains("c1:") && r.text.contains("c2:"), "the reply shows the new timeline")

        r = await call(model, "add_media", ["paths": [photo.path], "as": "overlay", "at": 0.5])
        XCTAssertTrue(r.ok, r.text)
        r = await call(model, "add_media", ["paths": [music.path], "as": "music", "at": 0])
        XCTAssertTrue(r.ok, r.text)
        XCTAssertEqual(model.project.music.count, 1)

        r = await call(model, "edit", ["actions": [
            ["type": "transition", "clip": "c2", "kind": "crossDissolve", "duration": 0.5],
            ["type": "add_title", "text": "Hello", "at": 0.2, "duration": 1.5, "font": "Georgia", "color": "#FFD60A"],
            ["type": "overlay", "target": "o1", "layout": "pip", "opacity": 0.8],
            ["type": "fade", "fade_in": 0.5, "fade_out": 0.5],
        ]])
        XCTAssertTrue(r.ok, r.text)
        XCTAssertEqual(model.project.clips[1].transitionIn?.kind, .crossDissolve)
        XCTAssertEqual(model.project.titles.first?.font, "Georgia")
        XCTAssertEqual(model.project.titles.first?.color, "#FFD60A")
        XCTAssertEqual(model.project.overlays.first?.opacity, 0.8)

        // Placing an overlay is one step: corner, size and tilt on the overlay action itself.
        r = await call(model, "edit", ["actions": [["type": "overlay", "target": "o1", "size": 0.2, "x": 0.35, "y": 0.3, "rotation": -8]]])
        XCTAssertTrue(r.ok, r.text)
        let t = try XCTUnwrap(model.project.overlays.first?.clip.transform)
        XCTAssertEqual(t.scale, 0.2); XCTAssertEqual(t.x, 0.35); XCTAssertEqual(t.y, 0.3); XCTAssertEqual(t.rotation, -8)
        XCTAssertTrue(r.text.contains("t1:"))

        r = await call(model, "edit", ["actions": [["type": "trim", "clip": "c9"]]])
        XCTAssertFalse(r.ok, "bad labels are reported back")
        XCTAssertTrue(r.text.contains("c9"))

        r = await call(model, "set_grade", ["clip": "c1", "knobs": ["exposure": 0.5, "temperature": 30], "strength": 0.9])
        XCTAssertTrue(r.ok, r.text)
        XCTAssertEqual(model.project.clips[0].recipe.exposure, 0.5)
        XCTAssertEqual(model.project.clips[0].intensity, 0.9)
        r = await call(model, "set_grade", ["clip": "c1", "knobs": ["sparkle": 1]])
        XCTAssertFalse(r.ok)

        for _ in 0..<50 where model.player.currentItem == nil { try await Task.sleep(for: .milliseconds(100)) }
        r = await call(model, "get_frame", ["time": 1.0, "width": 480])
        XCTAssertTrue(r.ok, r.text)
        let jpeg = try XCTUnwrap(r.image)
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8], "a JPEG")
        XCTAssertNotNil(NSImage(data: jpeg))

        let titlesBefore = model.project.titles.count
        r = await call(model, "control", ["action": "undo"])   // the grade
        r = await call(model, "control", ["action": "undo"])   // the overlay placement
        r = await call(model, "control", ["action": "undo"])   // the edit batch is one undo step
        XCTAssertTrue(r.ok, r.text)
        XCTAssertEqual(model.project.titles.count, titlesBefore - 1)
        _ = await call(model, "control", ["action": "redo"])
        XCTAssertEqual(model.project.titles.count, titlesBefore)

        let out = FileManager.default.temporaryDirectory.appendingPathComponent("agent-export-\(UUID().uuidString.prefix(6)).mp4")
        r = await call(model, "export", ["path": out.path, "codec": "h264", "resolution": "720"])
        XCTAssertTrue(r.ok, r.text)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))

        r = await call(model, "list_projects")
        XCTAssertTrue(r.text.contains("(open)"))
    }

    func testMissingFilesAndNoProject() async {
        let model = EditorModel()
        var r = await call(model, "get_timeline")
        XCTAssertTrue(r.text.contains("No project is open"))
        r = await call(model, "add_media", ["paths": ["/nope/missing.mov"]])
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.text.contains("Not found"))
    }
}
