import Foundation

/// Final-output policy shared with the mobile keyboards; never disables ASR punctuation.
enum DictationSentencePunctuation {
    static let preferenceKey = "dictationSentencePunctuation"
    private static let terminals = Set(".!?。！？…".unicodeScalars)
    private static let closers = Set("\"'”’»）)]】》」』".unicodeScalars)

    static func apply(_ text: String, enabled: Bool) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = Array(trimmed.unicodeScalars)
        let han = scalars.contains { (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value) }
        guard !scalars.isEmpty, scalars.count <= 120, !han || scalars.count <= 40,
              trimmed.split(whereSeparator: { $0.isWhitespace }).count <= 20,
              !trimmed.contains(where: { $0.isNewline }),
              !trimmed.contains("://"), !trimmed.contains("@"),
              !trimmed.lowercased().contains("www.") else { return text }
        var end = scalars.count
        while end > 0, closers.contains(scalars[end - 1]) { end -= 1 }
        let punctuationEnd = end
        while end > 0, terminals.contains(scalars[end - 1]) { end -= 1 }
        let body = Array(scalars[..<end])
        guard body.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return text }
        // Multiple sentences, abbreviations, domains and other ambiguous dotted text stay intact.
        for (index, scalar) in body.enumerated() where terminals.contains(scalar) {
            let decimal = scalar == "." && index > 0 && index + 1 < body.count
                && CharacterSet.decimalDigits.contains(body[index - 1])
                && CharacterSet.decimalDigits.contains(body[index + 1])
            if !decimal { return text }
        }
        func string(_ values: ArraySlice<Unicode.Scalar>) -> String { String(String.UnicodeScalarView(values)) }
        if enabled {
            guard end == punctuationEnd else { return text }
            return string(scalars[..<end]) + (han ? "。" : ".") + string(scalars[punctuationEnd...])
        }
        guard end < punctuationEnd else { return text }
        return string(scalars[..<end]).trimmingCharacters(in: .whitespaces) + string(scalars[punctuationEnd...])
    }
}
