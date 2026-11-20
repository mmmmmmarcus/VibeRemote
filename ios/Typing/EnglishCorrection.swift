import UIKit

/// Bounded, offline spelling checks. Unknown words stay literal unless the first
/// dictionary guess is a very close spelling. Nothing is learned, logged or sent.
@MainActor final class EnglishCorrection {
    private let checker: UITextChecker
    private static let knownWords: Set<String> = {
        let url = Bundle.main.url(forResource: "Rime", withExtension: nil)?.appendingPathComponent("EnglishWords.txt")
        let text = url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        return Set(text.split(whereSeparator: \.isNewline).map(String.init))
            .union(["vvhisper", "codex", "figma", "openrouter"])
    }()
    // Unambiguous common slips also work when the system dictionary is absent.
    private static let slips = ["teh": "the", "adn": "and", "thier": "their", "recieve": "receive",
                                "becuase": "because", "definately": "definitely", "alot": "a lot"]
    init(checker: UITextChecker = UITextChecker()) { self.checker = checker }

    func suggestions(for word: String) -> [String] {
        guard (2...32).contains(word.count), word.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "'") }),
              word == word.lowercased() || word == word.lowercased().capitalized else { return [] }
        let lower = word.lowercased()
        // The pronoun stays capitalized even mid-sentence. Keep other short words
        // and the all-caps acronym IM outside automatic spelling correction.
        if lower == "im" { return ["I'm"] }
        guard word.count >= 3 else { return [] }
        guard !Self.knownWords.contains(lower), !PinyinSpelling.isComplete(lower) else { return [] }
        func matchCase(_ value: String) -> String {
            word.first?.isUppercase == true ? value.prefix(1).uppercased() + value.dropFirst() : value
        }
        if let fixed = Self.slips[lower] { return [matchCase(fixed)] }
        let range = NSRange(location: 0, length: word.utf16.count)
        guard checker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false, language: "en_US").location != NSNotFound else { return [] }
        let guesses = checker.guesses(forWordRange: range, in: word, language: "en_US") ?? []
        var seen: Set<String> = []
        return Array(guesses.filter {
            $0.count <= 40 && $0.split(separator: " ").count <= 2 &&
            $0.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "'" || $0 == " ") } &&
            Self.isClose(lower, $0.lowercased().replacingOccurrences(of: " ", with: "")) &&
            seen.insert($0.lowercased()).inserted
        }.prefix(2)).map(matchCase)
    }

    /// One insertion, omission, substitution or adjacent transposition.
    static func isClose(_ source: String, _ target: String) -> Bool {
        let a = Array(source), b = Array(target)
        if a == b { return true }
        if a.count == b.count {
            let differences = a.indices.filter { a[$0] != b[$0] }
            if differences.count == 1 { return true }
            if differences.count == 2 {
                let i = differences[0], j = differences[1]
                return j == i + 1 && a[i] == b[j] && a[j] == b[i]
            }
            return false
        }
        let longer = a.count > b.count ? a : b, shorter = a.count > b.count ? b : a
        guard longer.count == shorter.count + 1 else { return false }
        var index = 0, skipped = false
        for character in longer {
            if index < shorter.count && character == shorter[index] { index += 1 }
            else if skipped { return false }
            else { skipped = true }
        }
        return index == shorter.count
    }
}

/// Own only the word entered by this keyboard. All replacement/undo operations
/// require the same document, caret and surrounding text; a delayed proxy reply
/// can suppress assistance but must never eat or delay an ordinary keypress.
@MainActor final class TypingAssistance {
    private let corrector: EnglishCorrection
    private(set) var word = ""
    private(set) var suggestions: [String] = []
    private var expected: KeyboardTextDestination?
    private var undo: (original: String, replacement: String)?
    private var ownedSpace = false
    private var automaticSpace = false
    private var rejected = false
    init(corrector: EnglishCorrection? = nil) { self.corrector = corrector ?? EnglishCorrection() }

    func clear() { word = ""; suggestions = []; expected = nil; undo = nil; ownedSpace = false; automaticSpace = false; rejected = false }
    func observe(_ proxy: UITextDocumentProxy) {
        if let expected, expected != KeyboardTextDestination(proxy) { clear() }
    }
    private func available(_ proxy: UITextDocumentProxy) -> Bool {
        guard proxy.autocorrectionType != .no, proxy.isSecureTextEntry != true,
              proxy.selectedText?.isEmpty != false,
              proxy.documentContextBeforeInput != nil || proxy.documentContextAfterInput != nil || !proxy.hasText else { return false }
        if [.URL, .emailAddress, .numberPad, .phonePad, .decimalPad, .asciiCapableNumberPad].contains(proxy.keyboardType ?? .default) { return false }
        if let content = proxy.textContentType, [UITextContentType.password, .newPassword, .oneTimeCode, .emailAddress, .URL, .username].contains(content) { return false }
        return true
    }
    func insert(_ text: String, into proxy: UITextDocumentProxy, correction: Bool, spacing: Bool) {
        observe(proxy)
        guard available(proxy) else { clear(); proxy.insertText(text); return }
        let before = proxy.documentContextBeforeInput ?? "", after = proxy.documentContextAfterInput ?? ""
        if spacing && automaticSpace && text == " " && before.hasSuffix(" ") {
            automaticSpace = false; return
        }
        let letter = text.count == 1 && text.first!.isASCII && text.first!.isLetter
        if letter || (text == "'" && !word.isEmpty) {
            undo = nil
            if word.isEmpty {
                // Do not claim a fragment in a word, URL, handle or code token.
                let token = before.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
                let blocked = token.contains("@") || token.contains("/") || token.contains("_") || token.contains(".")
                if blocked || before.last.map({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "'") }) == true || after.first?.isLetter == true {
                    clear(); proxy.insertText(text); return
                }
                if spacing, before.last.map(Self.isHan) == true { proxy.insertText(" ") }
            }
            proxy.insertText(text); word += text; ownedSpace = false; automaticSpace = false
            if word.count > 32 { clear(); return }
            suggestions = correction && !rejected ? corrector.suggestions(for: word) : []
            expected = KeyboardTextDestination(proxy)
            // With delayed acknowledgement do not claim text that is not yet there.
            if expected?.before?.hasSuffix(word) != true { clear() }
            return
        }
        let boundary = text == " " || text == "\n" || ".,!?;:".contains(text) && text.count == 1
        let original = word
        let replacement = boundary && correction && !rejected ? suggestions.first ?? word : word
        var changed = false
        if !word.isEmpty, replacement != word, before.hasSuffix(word), after.first?.isLetter != true {
            changed = replace(word, with: replacement, in: proxy)
        }
        let punctuation = text.count == 1 && ".,!?;:".contains(text)
        if spacing && ownedSpace && (punctuation || text == "\n") && before.hasSuffix(" ") { proxy.deleteBackward() }
        // A directly typed dot may start a domain, path or decimal. Add a space
        // there only when replacing our own trailing space after a finished word.
        let space = spacing && punctuation && (text != "." || ownedSpace) &&
            (before.last?.isLetter == true || ownedSpace) && (after.isEmpty || after.first?.isWhitespace == true)
        let insertion = text + (space && after.first?.isWhitespace != true ? " " : "")
        proxy.insertText(insertion)
        word = ""; suggestions = []; rejected = false
        ownedSpace = spacing && (text == " " || insertion.hasSuffix(" "))
        automaticSpace = space && insertion.hasSuffix(" ")
        expected = KeyboardTextDestination(proxy)
        undo = changed ? (original, replacement + insertion) : nil
        if undo != nil && expected?.before?.hasSuffix(replacement + insertion) != true { clear() }
    }
    @discardableResult func acceptEmoji(_ choice: String, in proxy: UITextDocumentProxy) -> Bool {
        observe(proxy)
        guard available(proxy), !word.isEmpty,
              EmojiCatalog.suggestions(for: [word]).contains(choice),
              proxy.documentContextBeforeInput?.hasSuffix(word) == true,
              replace(word, with: choice, in: proxy) else { return false }
        clear(); expected = KeyboardTextDestination(proxy)
        return true
    }
    @discardableResult func accept(_ choice: String, in proxy: UITextDocumentProxy, spacing: Bool) -> Bool {
        observe(proxy)
        guard available(proxy), !word.isEmpty, choice == word || suggestions.contains(choice),
              proxy.documentContextBeforeInput?.hasSuffix(word) == true else { return false }
        let original = word
        let suffix = spacing && (proxy.documentContextAfterInput ?? "").isEmpty ? " " : ""
        guard replace(word, with: choice + suffix, in: proxy) else { return false }
        clear(); expected = KeyboardTextDestination(proxy); ownedSpace = !suffix.isEmpty
        automaticSpace = !suffix.isEmpty
        if suffix.isEmpty { word = choice; rejected = true }
        else if original != choice { undo = (original, choice + suffix) }
        return true
    }
    func delete(in proxy: UITextDocumentProxy, correction: Bool = true) {
        observe(proxy)
        guard available(proxy) else { clear(); proxy.deleteBackward(); return }
        if available(proxy), let undo, proxy.documentContextBeforeInput?.hasSuffix(undo.replacement) == true {
            let original = undo.original
            if replace(undo.replacement, with: original, in: proxy) {
                clear(); word = original; rejected = true; expected = KeyboardTextDestination(proxy); return
            }
        }
        undo = nil; ownedSpace = false; automaticSpace = false
        proxy.deleteBackward()
        if !word.isEmpty { word.removeLast(); suggestions = rejected || !correction ? [] : corrector.suggestions(for: word) }
        expected = KeyboardTextDestination(proxy)
        if !word.isEmpty && expected?.before?.hasSuffix(word) != true { clear() }
    }
    private func replace(_ old: String, with new: String, in proxy: UITextDocumentProxy) -> Bool {
        let id = KeyboardDocumentIdentity.snapshot(proxy)
        guard proxy.selectedText?.isEmpty != false, proxy.documentContextBeforeInput?.hasSuffix(old) == true else { return false }
        for _ in old {
            guard KeyboardDocumentIdentity.snapshot(proxy) == id else { clear(); return false }
            proxy.deleteBackward()
        }
        guard KeyboardDocumentIdentity.snapshot(proxy) == id else { clear(); return false }
        proxy.insertText(new); return true
    }
    static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) || (0x20000...0x323af).contains($0.value) }
    }
}
