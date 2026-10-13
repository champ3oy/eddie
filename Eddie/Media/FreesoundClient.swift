import Foundation

/// Freesound.org sound effects: search, preview, add. Only sounds free for any video are offered —
/// CC0 (no strings) and CC BY (credit the author); non-commercial ones are filtered out.
/// Picked sounds are downloaded into Eddie's media folder; credits are kept with each sound.
enum Freesound {
    struct Sound: Identifiable, Hashable, Sendable {
        let id: Int
        let name: String
        let author: String
        let license: License
        let duration: Double
        /// High-quality MP3 preview (what's added to the project).
        let preview: URL
        /// A small waveform picture.
        let waveform: URL?
        let tags: [String]

        var page: URL { URL(string: "https://freesound.org/s/\(id)/")! }
        /// "“Whoosh” by someone (freesound.org/s/123/) — CC BY 4.0"
        var credit: String { "“\(name)” by \(author) (\(page.absoluteString)) — \(license.label)" }
    }

    enum License: String, Sendable {
        case cc0, by
        var label: String { self == .cc0 ? "CC0" : "CC BY 4.0" }
        /// Freesound gives a license URL; anything that isn't CC0 or plain Attribution is dropped.
        init?(url: String) {
            let u = url.lowercased()
            if u.contains("publicdomain/zero") { self = .cc0 }
            else if u.contains("/licenses/by/") { self = .by }
            else { return nil }
        }
    }

    static let keyAccount = "freesound"
    static var apiKey: String { ServiceKey.value(account: keyAccount, environment: "FREESOUND_API_KEY", infoKey: "EddieFreesoundKey") }
    static var hasKey: Bool { !apiKey.isEmpty }
    static var hasBuiltInKey: Bool { !ServiceKey.builtIn("EddieFreesoundKey").isEmpty }

    /// Ideas for an empty search box.
    static let suggestions = ["whoosh", "pop", "click", "swoosh", "ding", "impact", "applause", "laugh", "camera shutter",
                              "typing", "notification", "boom", "glitch", "riser", "rain", "crowd", "footsteps", "record scratch"]

    enum Failure: LocalizedError {
        case noKey, badKey, http(Int), offline
        var errorDescription: String? {
            switch self {
            case .noKey: "Add a Freesound API key in Settings to search sound effects."
            case .badKey: "Freesound didn't accept the API key. Check it in Settings."
            case .http(let code): "Freesound had a problem (error \(code)). Try again in a moment."
            case .offline: "Couldn't reach Freesound. Check your internet connection."
            }
        }
    }

    /// One page of results (30 s or shorter, best match first). `page` starts at 1.
    static func search(_ query: String, page: Int = 1) async throws -> (sounds: [Sound], more: Bool) {
        let key = apiKey
        guard !key.isEmpty else { throw Failure.noKey }
        var c = URLComponents(string: "https://freesound.org/apiv2/search/text/")!
        c.queryItems = [
            URLQueryItem(name: "query", value: query.trimmingCharacters(in: .whitespaces)),
            URLQueryItem(name: "filter", value: "duration:[0 TO 30]"),
            URLQueryItem(name: "fields", value: "id,name,username,license,duration,previews,images,tags"),
            URLQueryItem(name: "page_size", value: "40"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "token", value: key),
        ]
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(from: c.url!) } catch { throw Failure.offline }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw Failure.badKey }
        if status == 404 { return ([], false) }   // past the last page
        guard status == 200 else { throw Failure.http(status) }
        return try parse(data)
    }

    /// Reads Freesound's response, keeping only sounds that are free to use in any video.
    static func parse(_ data: Data) throws -> (sounds: [Sound], more: Bool) {
        struct Result: Decodable {
            let id: Int, name: String, username: String, license: String, duration: Double
            let previews: [String: String]?, images: [String: String]?, tags: [String]?
        }
        struct Response: Decodable { let next: String?, results: [Result] }
        let r = try JSONDecoder().decode(Response.self, from: data)
        let sounds = r.results.compactMap { s -> Sound? in
            guard let license = License(url: s.license),
                  let preview = (s.previews?["preview-hq-mp3"] ?? s.previews?["preview-lq-mp3"]).flatMap(URL.init(string:)) else { return nil }
            let name = s.name.replacingOccurrences(of: #"\.(wav|mp3|aiff?|flac|ogg|m4a)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            return Sound(id: s.id, name: name, author: s.username, license: license, duration: s.duration, preview: preview,
                         waveform: s.images?["waveform_m"].flatMap(URL.init(string:)), tags: s.tags ?? [])
        }
        return (sounds, r.next != nil)
    }

    /// Downloads a sound into Eddie's media folder (once). The file is named after the sound, so it
    /// reads well on the timeline.
    static func download(_ sound: Sound) async throws -> URL {
        let folder = AudioProcessor.mediaFolder.appendingPathComponent("Freesound", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = String(sound.name.map { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" ? $0 : "_" }.prefix(60))
            .trimmingCharacters(in: .whitespaces)
        let dest = folder.appendingPathComponent("\(safe.isEmpty ? "sound" : safe) (\(sound.id)).mp3")
        if !FileManager.default.fileExists(atPath: dest.path) {
            let tmp: URL, response: URLResponse
            do { (tmp, response) = try await URLSession.shared.download(from: sound.preview) } catch { throw Failure.offline }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
        return dest
    }

    /// The credits block for a project's Freesound sounds (CC0 ones included as a courtesy).
    static func credits(for project: Project) -> String? {
        let lines = Array(Set(project.music.compactMap(\.credit))).sorted()
        guard !lines.isEmpty else { return nil }
        return "Sound effects from Freesound.org:\n" + lines.map { "• " + $0 }.joined(separator: "\n")
    }
}
