import Foundation

/// Every emoji macOS can draw, searchable by name ("fire", "red heart", "dog face") and a few everyday words.
enum EmojiCatalog {
    struct Entry: Hashable {
        let emoji: String
        /// Lowercased words to match: the Unicode name plus extra keywords.
        let words: [String]
    }

    /// Built once, the first time someone searches.
    static let all: [Entry] = {
        var seen = Set<String>()
        var out: [Entry] = []
        func add(_ emoji: String) {
            guard seen.insert(emoji).inserted, let first = emoji.unicodeScalars.first,
                  let name = first.properties.name?.lowercased() else { return }
            var words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
            for (key, extra) in keywords where extra.contains(emoji) || extra.contains(emoji.filter { $0 != "\u{FE0F}" }) {
                words.append(key)
            }
            out.append(Entry(emoji: emoji, words: words))
        }
        // The favorites first, so they lead the results.
        EditorModel.stickerEmoji.forEach(add)
        let ranges: [ClosedRange<UInt32>] = [0x2600...0x27BF, 0x2B00...0x2BFF, 0x1F300...0x1F5FF, 0x1F600...0x1F64F,
                                             0x1F680...0x1F6FF, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF]
        for range in ranges {
            for v in range {
                guard let s = Unicode.Scalar(v), s.properties.isEmoji else { continue }
                // Symbols that are text by default get the emoji style.
                add(s.properties.isEmojiPresentation ? String(s) : String(s) + "\u{FE0F}")
            }
        }
        return out
    }()

    /// Emoji whose words start with every word typed (or the emoji itself, pasted in).
    static func search(_ query: String, limit: Int = 96) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return EditorModel.stickerEmoji }
        if q.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) { return [query.trimmingCharacters(in: .whitespaces)] }
        let terms = q.split(separator: " ").map(String.init)
        return Array(all.lazy.filter { e in
            terms.allSatisfy { t in e.words.contains { $0.hasPrefix(t) } }
        }.map(\.emoji).prefix(limit))
    }

    /// Everyday words that aren't in the official names.
    private static let keywords: [String: [String]] = [
        "love": ["😍", "🥰", "😘", "❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "💕", "💖", "💘", "💝"],
        "happy": ["😀", "😃", "😄", "😁", "😊", "🙂", "🥳", "😆"],
        "laugh": ["😂", "🤣", "😆", "😹"], "lol": ["😂", "🤣"],
        "sad": ["😢", "😭", "😞", "😔", "🥹", "☹️"], "cry": ["😢", "😭", "🥹"],
        "angry": ["😡", "😠", "🤬"], "mad": ["😡", "😠", "🤬"],
        "wow": ["😮", "😲", "🤯", "😱"], "shock": ["😱", "🤯", "😲"],
        "cool": ["😎", "🆒"], "party": ["🥳", "🎉", "🎊", "🪩"], "celebrate": ["🥳", "🎉", "🎊", "🍾"],
        "yes": ["✅", "👍", "👌"], "no": ["❌", "👎", "🚫"], "ok": ["👌", "🆗", "✅"],
        "thanks": ["🙏"], "pray": ["🙏"], "strong": ["💪"], "money": ["💰", "💵", "🤑", "💸"],
        "music": ["🎵", "🎶", "🎧", "🎸", "🎹", "🎤"], "camera": ["📸", "📷", "🎥", "🎬"],
        "travel": ["✈️", "🌍", "🧳", "🗺️"], "beach": ["🏖️", "🌴", "🌊", "☀️"], "food": ["🍕", "🍔", "🍟", "🌮", "🍣", "🍿"],
        "sun": ["☀️", "🌞", "🌅"], "night": ["🌙", "🌃", "⭐️"], "win": ["🏆", "🥇", "🎯"],
        "arrow": ["➡️", "⬅️", "⬆️", "⬇️", "↗️"], "fire": ["🔥"], "red": ["❤️"], "heart": ["❤️"], "lit": ["🔥"], "eyes": ["👀"], "look": ["👀"],
    ]
}
