import Foundation

/// GIPHY search for GIFs and stickers (transparent GIFs). Needs the user's own API key (Settings → GIPHY),
/// kept in the Keychain. Only the search words and the key go to GIPHY; picked GIFs are downloaded into
/// Eddie's media folder so projects keep working offline.
enum Giphy {
    enum Kind: String, CaseIterable, Identifiable {
        case stickers, gifs
        var id: String { rawValue }
        var label: String { self == .gifs ? "GIFs" : "Stickers" }
    }

    struct Item: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        /// Small animated preview for the picker.
        let preview: URL
        /// Preview width ÷ height.
        let aspect: Double
        /// What goes into the project (under 2 MB where GIPHY has it).
        let full: URL
        /// GIPHY asks apps to report when a result is used.
        let sentPing: URL?
    }

    static let keyAccount = "giphy"
    /// Your own key (Settings) first, then GIPHY_API_KEY, then the key built into release DMGs.
    static var apiKey: String { ServiceKey.value(account: keyAccount, environment: "GIPHY_API_KEY", infoKey: "EddieGiphyKey") }
    static var hasBuiltInKey: Bool { !ServiceKey.builtIn("EddieGiphyKey").isEmpty }
    static func unscramble(_ hex: String) -> String { ServiceKey.unscramble(hex) }
    static var hasKey: Bool { !apiKey.isEmpty }

    enum Failure: LocalizedError {
        case noKey, badKey, http(Int), offline
        var errorDescription: String? {
            switch self {
            case .noKey: "Add your GIPHY API key in Settings to search GIFs and stickers."
            case .badKey: "GIPHY didn't accept the API key. Check it in Settings."
            case .http(let code): "GIPHY had a problem (error \(code)). Try again in a moment."
            case .offline: "Couldn't reach GIPHY. Check your internet connection."
            }
        }
    }

    /// Search (or trending, for an empty query). `offset` pages through more results.
    static func search(_ query: String, kind: Kind, offset: Int = 0, limit: Int = 30) async throws -> [Item] {
        let key = apiKey
        guard !key.isEmpty else { throw Failure.noKey }
        let q = query.trimmingCharacters(in: .whitespaces)
        var c = URLComponents(string: "https://api.giphy.com/v1/\(kind.rawValue)/\(q.isEmpty ? "trending" : "search")")!
        c.queryItems = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "rating", value: "pg-13"),
        ] + (q.isEmpty ? [] : [URLQueryItem(name: "q", value: q), URLQueryItem(name: "lang", value: "en")])
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(from: c.url!) } catch { throw Failure.offline }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw Failure.badKey }
        guard status == 200 else { throw Failure.http(status) }
        return try parse(data)
    }

    /// Reads GIPHY's response (results without the needed renditions are skipped).
    static func parse(_ data: Data) throws -> [Item] {
        struct Rendition: Decodable { let url: String?, width: String?, height: String? }
        struct Images: Decodable {
            let fixed_width_small: Rendition?, fixed_width: Rendition?, downsized: Rendition?, original: Rendition?
        }
        struct Ping: Decodable { let url: String? }
        struct Analytics: Decodable { let onsent: Ping? }
        struct Result: Decodable { let id: String, title: String?, images: Images, analytics: Analytics? }
        struct Response: Decodable { let data: [Result] }
        return try JSONDecoder().decode(Response.self, from: data).data.compactMap { r in
            guard let small = r.images.fixed_width_small ?? r.images.fixed_width,
                  let preview = small.url.flatMap(URL.init(string:)),
                  let full = (r.images.downsized?.url ?? r.images.original?.url).flatMap(URL.init(string:)) else { return nil }
            let w = Double(small.width ?? "") ?? 100, h = Double(small.height ?? "") ?? 100
            return Item(id: r.id, title: r.title ?? "GIPHY", preview: preview, aspect: h > 0 ? w / h : 1,
                        full: full, sentPing: r.analytics?.onsent?.url.flatMap(URL.init(string:)))
        }
    }

    /// Downloads a result into Eddie's media folder (once) and tells GIPHY it was used.
    static func download(_ item: Item) async throws -> URL {
        let folder = AudioProcessor.mediaFolder.appendingPathComponent("GIPHY", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ext = item.full.pathExtension.isEmpty ? "gif" : item.full.pathExtension
        let safeID = item.id.filter { $0.isLetter || $0.isNumber }
        let dest = folder.appendingPathComponent("\(safeID).\(ext)")
        if !FileManager.default.fileExists(atPath: dest.path) {
            let tmp: URL, response: URLResponse
            do { (tmp, response) = try await URLSession.shared.download(from: item.full) } catch { throw Failure.offline }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.http((response as? HTTPURLResponse)?.statusCode ?? 0) }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmp, to: dest)
        }
        if let ping = item.sentPing {
            if var c = URLComponents(url: ping, resolvingAgainstBaseURL: false) {
                let items = c.queryItems ?? []
                c.queryItems = items + [URLQueryItem(name: "ts", value: String(Int(Date().timeIntervalSince1970 * 1000)))]
                if let url = c.url { _ = try? await URLSession.shared.data(from: url) }
            }
        }
        return dest
    }
}
