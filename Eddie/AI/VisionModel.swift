import Foundation

/// One request to a vision-capable model: instructions, text, frames, and the JSON shape we want back.
struct VisionRequest {
    var system: String
    var text: String
    /// JPEG-encoded frames.
    var images: [Data]
    /// JSON Schema of the answer (plain subset: objects, strings, numbers, booleans; no numeric bounds).
    var schema: [String: Any]
    var schemaName: String = "grade_response"
}

/// The only thing the grading logic knows about AI. Each provider turns a `VisionRequest`
/// into its own HTTP call and returns the model's JSON answer as text.
protocol VisionModel {
    var displayName: String { get }
    func complete(_ request: VisionRequest) async throws -> String
}

enum VisionModelError: LocalizedError {
    case missingAPIKey(String)
    case http(provider: String, status: Int, message: String)
    case refused(String)
    case emptyResponse(String)
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case let .missingAPIKey(p): return "No API key for \(p). Add one in Settings (⌘,)."
        case let .http(p, status, message): return "\(p) returned HTTP \(status): \(message)"
        case let .refused(p): return "\(p) declined to answer this request."
        case let .emptyResponse(p): return "\(p) returned no answer."
        case let .invalidJSON(text): return "The AI's answer wasn't valid JSON: \(text.prefix(300))"
        }
    }
}

enum JSONExtraction {
    /// Returns the outermost `{...}` object in `text` (tolerates code fences or prose around it).
    static func object(in text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return String(text[start...end]).data(using: .utf8)
    }
}

/// Shared HTTP plumbing for providers.
enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    static func postJSON(_ url: URL, headers: [String: String], body: [String: Any], provider: String) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            throw VisionModelError.http(provider: provider, status: status, message: errorMessage(json) ?? String(decoding: data.prefix(500), as: UTF8.self))
        }
        guard let json else { throw VisionModelError.emptyResponse(provider) }
        return json
    }

    /// Pulls the human-readable message out of the usual `{"error": {"message": ...}}` shapes.
    private static func errorMessage(_ json: [String: Any]?) -> String? {
        if let err = json?["error"] as? [String: Any] { return err["message"] as? String }
        if let err = json?["error"] as? String { return err }
        return json?["message"] as? String
    }
}
