import Foundation

/// How the `eddie-mcp` helper talks to the running app: one JSON object per line over a Unix socket that only
/// the user's own account can open.
///   request:  {"id": 1, "tool": "edit", "args": {…}}
///   response: {"id": 1, "ok": true, "text": "…", "image": "<base64 JPEG>"?}
enum AgentProtocol {
    static let version = "1.0"
    /// Eddie's bundle identifier (the helper finds and opens the app with it).
    static let appBundleID = "com.deadalus.eddie"

    /// `~/Library/Application Support/Eddie/agent.sock` (or `EDDIE_AGENT_SOCKET`, for tests).
    static var socketPath: String {
        if let p = ProcessInfo.processInfo.environment["EDDIE_AGENT_SOCKET"], !p.isEmpty { return p }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Eddie", isDirectory: true)
        return base.appendingPathComponent("agent.sock").path
    }

    static func encode(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    static func decode(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    // MARK: Tools offered to agents

    struct Tool {
        let name: String
        let description: String
        let input: [String: Any]
    }

    static let instructions = """
    Eddie is a video editor on this Mac. Start with get_timeline to see the edit (or list_projects / new_project \
    when nothing is open), add files with add_media, change things with edit, look at the result with get_frame, \
    and export when the user is happy. Every call is one undo step in Eddie, and the user sees changes live.
    """

    static let tools: [Tool] = [
        Tool(name: "get_timeline",
             description: "Describe the open project's edit: clips (c1, c2… in order), overlays (o1…), titles (t1…), audio (m1…), markers (k1…), grades, transitions, format and the playhead. Call this before editing; labels change after edits.",
             input: object([:])),
        Tool(name: "list_projects",
             description: "List the projects saved in Eddie (name, id, length, clip count, last edited).",
             input: object([:])),
        Tool(name: "open_project",
             description: "Open a saved project by id or name.",
             input: object(["id": string("Project id from list_projects"), "name": string("Project name (exact or partial)")])),
        Tool(name: "new_project",
             description: "Start a new, empty project and open it.",
             input: object(["name": string("Optional project name")])),
        Tool(name: "add_media",
             description: "Add files from disk to the open project. as = clip (main track; videos or photos), overlay (B-roll / picture-in-picture on top), music, effect (sound effect), voiceover, or bin (media bin only). Clips go at `at` seconds (insert) or the end; overlays and audio start at `at` or the playhead.",
             input: object(["paths": ["type": "array", "items": ["type": "string"], "description": "Absolute file paths"],
                            "as": ["type": "string", "enum": ["clip", "overlay", "music", "effect", "voiceover", "bin"]],
                            "at": number("Timeline seconds")], required: ["paths"])),
        Tool(name: "edit",
             description: "Change the edit with one or more actions, applied in order as a single undo step. Returns what happened and the new timeline.\n\n" + EditActionSchema.guide,
             input: object(["actions": ["type": "array", "items": EditActionSchema.action(strict: false)]], required: ["actions"])),
        Tool(name: "get_frame",
             description: "See the edit: an image of the finished, graded frame at a time (with overlays and titles).",
             input: object(["time": number("Timeline seconds (default: the playhead)"),
                            "width": number("Image width in pixels, 320–1920 (default 960)")])),
        Tool(name: "set_grade",
             description: "Set a clip's color grade directly. Knobs (0 = unchanged): exposure (−2…2 stops), contrast, highlights, shadows, whites, blacks, temperature, tint, vibrance, saturation (each −100…100). Only the knobs you pass change. strength scales the whole grade (0–1.5, 1 = as set).",
             input: object(["clip": string("c1, o1… or \"all\""),
                            "knobs": ["type": "object", "additionalProperties": ["type": "number"]],
                            "strength": number("0–1.5"), "reset": ["type": "boolean", "description": "Start from no grade"]],
                           required: ["clip"])),
        Tool(name: "auto_grade",
             description: "Let Eddie's own AI colorist grade a clip (or all clips) from its frames, optionally following an instruction like \"warmer\" or \"cinematic\". Uses the AI provider set in Eddie's Settings. Takes up to a minute.",
             input: object(["clip": string("c1… or \"all\" (default: c1)"), "instruction": string("Optional look to aim for")])),
        Tool(name: "control",
             description: "Playback and history: play, pause, seek (to `time`), undo, redo, save.",
             input: object(["action": ["type": "string", "enum": ["play", "pause", "seek", "undo", "redo", "save"]],
                            "time": number("Seconds, for seek")], required: ["action"])),
        Tool(name: "export",
             description: "Render the edit to a file and wait until it's done. codec: hevc (10-bit, default), h264 (.mp4, plays everywhere), prores, audio (.m4a, sound only) or gif (animated, no sound). resolution: project, 720, 1080 or 2160. fps: project, 24, 25, 30, 50 or 60.",
             input: object(["path": string("Absolute output path (.mov or .mp4)"),
                            "codec": ["type": "string", "enum": ["hevc", "h264", "prores", "audio", "gif"]],
                            "resolution": ["type": "string", "enum": ["project", "720", "1080", "2160"]],
                            "fps": ["type": "string", "enum": ["project", "24", "25", "30", "50", "60"]]],
                           required: ["path"])),
    ]

    private static func object(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        var o: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { o["required"] = required }
        return o
    }

    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private static func number(_ description: String) -> [String: Any] { ["type": "number", "description": description] }
}
