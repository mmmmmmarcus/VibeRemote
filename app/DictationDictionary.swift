import Foundation

/// One word the user wants dictation to get right, written the way it should appear. An
/// "often heard as" column of misspellings to replace existed until 2026-11-12 and was removed at
/// the user's request: it was hard to tell what to enter there. Saved entries that still carry
/// that key decode fine (unknown keys are ignored) and drop it on the next save.
struct DictationDictionaryEntry: Equatable, Sendable, Identifiable, Codable {
    var id = UUID()
    var word: String
}

/// The user's dictation dictionary (2026-11-11, user's request), used three ways:
/// - **Recognizer hints.** Seed ASR gets the words as hotwords (`request.corpus.context`, a JSON
///   string `{"hotwords":[{"word":…}]}` per Volcengine's streaming ASR docs) on the refinement after
///   release (not on the live stream, see `startStream`); OpenAI gets them as a vocabulary prompt.
/// - **Case correction.** After recognition, every engine's text has the word's own spelling
///   case-corrected ("codex" → "Codex"), locally, which also covers engines that take no hints.
enum DictationDictionary {
    static let defaultsKey = "dictationDictionary"

    static func load(from defaults: UserDefaults = .standard) -> [DictationDictionaryEntry] {
        guard let data = defaults.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([DictationDictionaryEntry].self, from: data) else { return [] }
        return entries
    }

    static func save(_ entries: [DictationDictionaryEntry], to defaults: UserDefaults = .standard) {
        let kept = entries.filter { !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        defaults.set(try? JSONEncoder().encode(kept), forKey: defaultsKey)
    }

    // MARK: Hints

    /// Volcengine's two-way streaming recognizer accepts about 100 tokens of hotwords. Tokens are
    /// not specified, so this budgets conservatively: a CJK character counts one, a Latin word two
    /// plus one per six letters. Words past the budget are left out (the list's order is the
    /// user's priority).
    static let hotwordBudget = 90

    /// Hotwords may not contain punctuation other than spaces (Volcengine's rule), so it is
    /// stripped; words that end up empty are dropped, and duplicates kept once.
    static func hotwords(_ entries: [DictationDictionaryEntry], budget: Int = hotwordBudget) -> [String] {
        var words: [String] = []
        var spent = 0
        for entry in entries {
            let cleaned = entry.word.unicodeScalars
                .map { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) ? Character($0) : " " }
            let word = String(cleaned).split(separator: " ").joined(separator: " ")
            guard !word.isEmpty, !words.contains(word) else { continue }
            let cost = tokenEstimate(word)
            guard spent + cost <= budget else { continue }
            spent += cost
            words.append(word)
        }
        return words
    }

    static func tokenEstimate(_ word: String) -> Int {
        var cost = 0
        for part in word.split(separator: " ") {
            let cjk = part.unicodeScalars.filter { $0.value >= 0x2E80 }.count
            let latin = part.unicodeScalars.count - cjk
            cost += cjk + (latin > 0 ? 2 + latin / 6 : 0)
        }
        return max(1, cost)
    }

    /// `request.corpus.context` for Seed ASR, or nil with neither usable words nor editor text.
    /// `editorText` is what already stands before the caret (`DictationEditorContext`), sent as
    /// Volcengine's dialog context (`context_type` "dialog_ctx", `context_data` newest first; the
    /// docs allow 800 tokens and 20 entries) so the recognizer knows the topic and the names in use.
    static func seedContext(_ entries: [DictationDictionaryEntry], editorText: String? = nil) -> String? {
        var object: [String: Any] = [:]
        let words = hotwords(entries)
        if !words.isEmpty { object["hotwords"] = words.map { ["word": $0] } }
        if let editorText = editorText.flatMap(DictationEditorContext.trimmed) {
            object["context_type"] = "dialog_ctx"
            object["context_data"] = [["text": editorText]]
        }
        guard !object.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// OpenAI's transcription `prompt`: the spellings to prefer, as plain text.
    static func openAIPrompt(_ entries: [DictationDictionaryEntry]) -> String? {
        let words = entries.map { $0.word.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return "Vocabulary: " + words.joined(separator: ", ") + "."
    }

    // MARK: Replacement

    /// Each word's own spelling is case-corrected, matched case-insensitively. Words that start or
    /// end with a Latin letter or digit match only as whole words, so "Codex" never rewrites the
    /// middle of "Codexes"; CJK words match anywhere, since Chinese has no word boundaries. Longer
    /// words go first.
    static func apply(_ entries: [DictationDictionaryEntry], to text: String) -> String {
        var rules: [(pattern: String, word: String)] = []
        for entry in entries {
            let word = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { continue }
            rules.append((word, word))
        }
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var result = text
        for rule in rules.sorted(by: { $0.pattern.count > $1.pattern.count }) {
            let escaped = NSRegularExpression.escapedPattern(for: rule.pattern)
            // Only Latin letters and digits count as neighbours, so "Codex" still matches in "用Codex写".
            let leading = rule.pattern.first.map(isWordCharacter) == true ? "(?<![A-Za-z0-9\\u00C0-\\u024F])" : ""
            let trailing = rule.pattern.last.map(isWordCharacter) == true ? "(?![A-Za-z0-9\\u00C0-\\u024F])" : ""
            guard let regex = try? NSRegularExpression(pattern: leading + escaped + trailing, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: rule.word))
        }
        return result
    }

    /// Latin letters and digits form words with their neighbours; CJK characters do not.
    private static func isWordCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0.value < 0x2E80 && (CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)) }
    }
}
