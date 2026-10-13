import Foundation

/// API keys for the online libraries (GIPHY, Freesound). Your own key from Settings comes first, then an
/// environment variable, then the key scripts/release.sh builds into release DMGs (lightly scrambled in
/// Info.plist; empty in builds from source, so keys never live in the repo).
enum ServiceKey {
    static func value(account: String, environment: String, infoKey: String) -> String {
        let own = (Keychain.read(account: account) ?? ProcessInfo.processInfo.environment[environment] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? builtIn(infoKey) : own
    }

    static func builtIn(_ infoKey: String) -> String {
        unscramble(Bundle.main.object(forInfoDictionaryKey: infoKey) as? String ?? "")
    }

    /// Reverses release.sh's XOR-with-"eddie-giphy" hex. An unfilled "$(…)" placeholder means no key.
    static func unscramble(_ hex: String) -> String {
        guard hex.count.isMultiple(of: 2), !hex.isEmpty, !hex.hasPrefix("$(") else { return "" }
        let mask = Array("eddie-giphy".utf8)
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return "" }
            bytes.append(b ^ mask[bytes.count % mask.count])
            i = j
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
