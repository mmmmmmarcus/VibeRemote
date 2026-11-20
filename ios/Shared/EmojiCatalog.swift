import Foundation

struct KeyboardEmoji: Decodable, Equatable {
    let glyph: String
    let name: String
    let category: String
}

enum EmojiCatalog {
    // Unicode Emoji 16.0, fully-qualified sequences. See Unicode-Emoji-LICENSE.txt.
    static let all: [KeyboardEmoji] = {
        guard let url = Bundle.main.url(forResource: "EmojiCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([KeyboardEmoji].self, from: data) else { return [] }
        return items
    }()
    static func identity(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !(0x1F3FB...0x1F3FF).contains($0.value) && $0.value != 0xFE0F }))
    }
    static let base = all.filter { !$0.glyph.unicodeScalars.contains { (0x1F3FB...0x1F3FF).contains($0.value) } }
    static let categories = base.reduce(into: [String]()) { if !$0.contains($1.category) { $0.append($1.category) } }
    private static let variants = Dictionary(grouping: all, by: { identity($0.glyph) })
    private static let keywords: [String: [String]] = {
        guard let url = Bundle.main.url(forResource: "EmojiKeywords", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let names = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return names
    }()
    /// Exact names/keywords only: no substring matches that turn "hotdog" into 🐕.
    /// Queries stay local and are never persisted or sent to a provider.
    static func suggestions(for names: [String], limit: Int = 3) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>(), result: [String] = []
        for name in names.prefix(6) where name.count <= 80 {
            let normalized = name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            for glyph in keywords[normalized] ?? [] where seen.insert(glyph).inserted {
                result.append(glyph)
                if result.count == limit { return result }
            }
        }
        return result
    }
    static func applying(tone: Int, to item: KeyboardEmoji) -> KeyboardEmoji {
        guard (1...5).contains(tone), let choices = variants[identity(item.glyph)] else { return item }
        let scalar = UInt32(0x1F3FA + tone)
        return choices.first { candidate in
            let tones = candidate.glyph.unicodeScalars.filter { (0x1F3FB...0x1F3FF).contains($0.value) }
            return !tones.isEmpty && tones.allSatisfy { $0.value == scalar }
        } ?? item
    }
}
