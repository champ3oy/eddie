import Foundation

// MARK: - Gemini

struct GeminiProvider: VisionModel {
    var apiKey: String
    var model: String
    var displayName: String { "Gemini (\(model))" }

    func body(for r: VisionRequest) -> [String: Any] {
        var parts: [[String: Any]] = r.images.map {
            ["inline_data": ["mime_type": "image/jpeg", "data": $0.base64EncodedString()]]
        }
        parts.append(["text": r.text])
        return [
            "systemInstruction": ["parts": [["text": r.system]]],
            "contents": [["role": "user", "parts": parts]],
            "generationConfig": [
                "responseMimeType": "application/json",
                "responseJsonSchema": r.schema,
                "thinkingConfig": ["thinkingLevel": "high"],
            ],
        ]
    }

    func complete(_ r: VisionRequest) async throws -> String {
        guard !apiKey.isEmpty else { throw VisionModelError.missingAPIKey("Gemini") }
        let encoded = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? model
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encoded):generateContent")!
        let json = try await HTTP.postJSON(url, headers: ["x-goog-api-key": apiKey], body: body(for: r), provider: "Gemini")
        return try Self.text(from: json)
    }

    static func text(from json: [String: Any]) throws -> String {
        if let feedback = json["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil {
            throw VisionModelError.refused("Gemini")
        }
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first else {
            throw VisionModelError.emptyResponse("Gemini")
        }
        let parts = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        // Skip thought-summary parts; keep the answer text.
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        if text.isEmpty {
            if (candidate["finishReason"] as? String) == "SAFETY" { throw VisionModelError.refused("Gemini") }
            throw VisionModelError.emptyResponse("Gemini")
        }
        return text
    }
}

// MARK: - OpenAI and OpenAI-compatible (DeepSeek)

struct OpenAICompatibleProvider: VisionModel {
    enum JSONMode { case strictSchema, jsonObject }

    var name: String
    var baseURL: URL
    var apiKey: String
    var model: String
    var jsonMode: JSONMode
    /// Extra top-level request fields (e.g. DeepSeek's reasoning switch).
    var extraBody: [String: Any] = [:]
    var displayName: String { "\(name) (\(model))" }

    static func openAI(apiKey: String, model: String) -> Self {
        Self(name: "OpenAI", baseURL: URL(string: "https://api.openai.com/v1")!, apiKey: apiKey, model: model, jsonMode: .strictSchema)
    }

    static func deepSeek(apiKey: String, model: String) -> Self {
        Self(name: "DeepSeek", baseURL: URL(string: "https://api.deepseek.com")!, apiKey: apiKey, model: model, jsonMode: .jsonObject,
             extraBody: ["thinking": ["type": "enabled"], "reasoning_effort": "high"])
    }

    func body(for r: VisionRequest) -> [String: Any] {
        var content: [[String: Any]] = r.images.map {
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\($0.base64EncodedString())"]]
        }
        content.append(["type": "text", "text": r.text])
        let format: [String: Any]
        switch jsonMode {
        case .strictSchema:
            format = ["type": "json_schema", "json_schema": ["name": r.schemaName, "strict": true, "schema": r.schema]]
        case .jsonObject:
            format = ["type": "json_object"]
        }
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": r.system],
                ["role": "user", "content": content],
            ],
            "response_format": format,
        ]
        body.merge(extraBody) { _, new in new }
        return body
    }

    func complete(_ r: VisionRequest) async throws -> String {
        guard !apiKey.isEmpty else { throw VisionModelError.missingAPIKey(name) }
        let url = baseURL.appendingPathComponent("chat/completions")
        let json = try await HTTP.postJSON(url, headers: ["Authorization": "Bearer \(apiKey)"], body: body(for: r), provider: name)
        return try Self.text(from: json, provider: name)
    }

    static func text(from json: [String: Any], provider: String) throws -> String {
        guard let message = ((json["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any] else {
            throw VisionModelError.emptyResponse(provider)
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw VisionModelError.refused(provider) }
        guard let text = message["content"] as? String, !text.isEmpty else { throw VisionModelError.emptyResponse(provider) }
        return text
    }
}

// MARK: - Claude

struct ClaudeProvider: VisionModel {
    var apiKey: String
    var model: String
    var displayName: String { "Claude (\(model))" }

    func body(for r: VisionRequest) -> [String: Any] {
        var content: [[String: Any]] = r.images.map {
            ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": $0.base64EncodedString()]]
        }
        content.append(["type": "text", "text": r.text])
        return [
            "model": model,
            "max_tokens": 16000,
            "system": r.system,
            "thinking": ["type": "adaptive"],
            "output_config": ["format": ["type": "json_schema", "schema": r.schema]],
            // Server-side fallback if a safety classifier declines the request.
            "fallbacks": "default",
            "messages": [["role": "user", "content": content]],
        ]
    }

    func complete(_ r: VisionRequest) async throws -> String {
        guard !apiKey.isEmpty else { throw VisionModelError.missingAPIKey("Claude") }
        let json = try await HTTP.postJSON(
            URL(string: "https://api.anthropic.com/v1/messages")!,
            headers: [
                "x-api-key": apiKey,
                "anthropic-version": "2023-06-01",
                "anthropic-beta": "server-side-fallback-2026-07-01",
            ],
            body: body(for: r), provider: "Claude")
        return try Self.text(from: json)
    }

    static func text(from json: [String: Any]) throws -> String {
        if (json["stop_reason"] as? String) == "refusal" { throw VisionModelError.refused("Claude") }
        let blocks = (json["content"] as? [[String: Any]]) ?? []
        let text = blocks.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw VisionModelError.emptyResponse("Claude") }
        return text
    }
}
