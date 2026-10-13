import CoreText
import Foundation

/// The whole emoji set — smileys, people (with skin tones), families, flags… — with CLDR keywords, from
/// `emoji.json` (built from Unicode's emoji-test.txt and CLDR annotations; Unicode License v3).
/// Emoji this Mac's font can't draw yet are left out.
enum EmojiCatalog {
    struct Entry: Hashable {
        let emoji: String
        let name: String
        /// Lowercased search words: the name, CLDR keywords and a few everyday extras.
        let words: [String]
        let group: String
        /// A skin-tone variant (shown when searching for a tone, not when browsing).
        let toned: Bool
    }

    /// The category order of the system emoji picker.
    static let groups = ["Smileys & Emotion", "People & Body", "Animals & Nature", "Food & Drink", "Travel & Places",
                         "Activities", "Objects", "Symbols", "Flags"]

    /// Loaded once, the first time the picker opens.
    static let all: [Entry] = {
        struct Raw: Decodable { let e: String, n: String, k: String, g: String, t: Int? }
        guard let url = Bundle.main.url(forResource: "emoji", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([Raw].self, from: data) else { return [] }
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 20, nil)
        return raw.compactMap { r in
            guard drawable(r.e, font: font) else { return nil }
            var words = r.k.split(separator: " ").map(String.init)
            for (key, list) in extras where list.contains(r.e) { words.append(key) }
            return Entry(emoji: r.e, name: r.n, words: words, group: r.g, toned: r.t != nil)
        }
    }()

    /// The emoji's name ("fire", "flag: Ghana"), for tooltips.
    static func name(of emoji: String) -> String? { names[emoji] }
    private static let names: [String: String] = Dictionary(all.map { ($0.emoji, $0.name) }, uniquingKeysWith: { a, _ in a })

    /// Browsing: every emoji (without the skin-tone copies), by category.
    static let byGroup: [(group: String, emoji: [String])] = {
        groups.map { g in (g, all.filter { $0.group == g && !$0.toned }.map(\.emoji)) }.filter { !$0.emoji.isEmpty }
    }()

    /// Emoji with a word starting with each word typed ("map", "red heart", "thumbs dark").
    /// Skin-tone variants only show when the search mentions a tone. Pasting an emoji uses it.
    static func search(_ query: String, limit: Int = 400) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let q = trimmed.lowercased()
        guard !q.isEmpty else { return EditorModel.stickerEmoji }
        if q.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { return [trimmed] }
        let terms = q.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "," }).map(String.init)
        let wantsTone = terms.contains { ["skin", "tone", "light", "dark", "medium"].contains($0) }
        let hits = all.filter { e in
            (wantsTone || !e.toned) && terms.allSatisfy { t in e.words.contains { $0.hasPrefix(t) } }
        }
        // Whole-word name matches first ("map" → world map before maple leaf), then the rest in catalog order.
        let ranked = hits.enumerated().sorted { a, b in
            let sa = score(a.element, terms), sb = score(b.element, terms)
            return sa != sb ? sa > sb : a.offset < b.offset
        }
        return ranked.prefix(limit).map(\.element.emoji)
    }

    private static func score(_ e: Entry, _ terms: [String]) -> Int {
        let nameWords = e.name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        return terms.reduce(0) { sum, t in
            sum + (nameWords.contains(t) ? 3 : 0) + (e.words.contains(t) ? 2 : 0) + (nameWords.contains { $0.hasPrefix(t) } ? 1 : 0)
        }
    }

    /// True when the emoji font draws it as one picture (newer emoji show as pieces on older macOS).
    private static func drawable(_ emoji: String, font: CTFont) -> Bool {
        let text = NSAttributedString(string: emoji, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(text)
        guard CTLineGetGlyphCount(line) == 1, let run = (CTLineGetGlyphRuns(line) as? [CTRun])?.first else { return false }
        var glyph = CGGlyph()
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        return glyph != 0
    }

    /// Everyday words CLDR doesn't use.
    private static let extras: [String: [String]] = [
        "lol": ["😂", "🤣"], "sad": ["😢", "😭", "😞", "😔", "🥹"], "angry": ["😡", "😠", "🤬"], "mad": ["😡", "😠", "🤬"],
        "wow": ["😮", "😲", "🤯", "😱"], "shock": ["😱", "🤯", "😲"], "money": ["💰", "💵", "🤑", "💸"],
        "travel": ["✈️", "🌍", "🧳", "🗺️"], "food": ["🍕", "🍔", "🍟", "🌮", "🍣", "🍿"], "win": ["🏆", "🥇", "🎯"],
        "music": ["🎵", "🎶", "🎧", "🎸", "🎹", "🎤"],
    ]
}
