import UIKit

/// Normal Chinese mode offers known English without promoting raw Pinyin.
/// The opt-in experiment also favors capitals and unconverted Latin fragments.
@MainActor
final class BilingualCandidates {
    enum Policy { case conservative, experimental }
    typealias Candidate = PinyinCandidates.Candidate
    private let checker: UITextChecker
    private lazy var correction = EnglishCorrection(checker: checker)
    private static let bundledWords: [String] = {
        guard let url = Bundle.main.url(forResource: "Rime", withExtension: nil)?.appendingPathComponent("EnglishWords.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(Set(text.split(whereSeparator: \.isNewline).map(String.init).filter {
            !$0.hasPrefix("#") && !$0.isEmpty
        })).sorted()
    }()
    private static let bundledWordSet = Set(bundledWords)
    init(checker: UITextChecker = UITextChecker()) { self.checker = checker }

    func choices(for snapshot: PinyinEngine.Snapshot, letterCase: EnglishLetterCase,
                 policy: Policy = .experimental, correctEnglish: Bool = true) -> [Candidate] {
        var choices = uncorrectedChoices(for: snapshot, letterCase: letterCase, policy: policy)
        if correctEnglish, snapshot.page == 0, !PinyinSpelling.isComplete(snapshot.input) {
            // In Chinese mode keep this especially conservative: only repair to
            // a bundled English term, never displace Chinese with a wild guess.
            let repairs = correction.suggestions(for: snapshot.input).filter { Self.bundledWordSet.contains($0.lowercased()) }
            for (index, repair) in repairs.enumerated().reversed() {
                let display = letterCase.apply(to: repair)
                if !choices.contains(where: { $0.text.caseInsensitiveCompare(display) == .orderedSame }) {
                    choices.insert(Candidate(text: display, identifier: "candidate.english.correction.\(index)", action: .english(display), addsSpaceOnSpaceKey: true), at: 0)
                }
            }
        }
        return choices
    }

    private func uncorrectedChoices(for snapshot: PinyinEngine.Snapshot, letterCase: EnglishLetterCase,
                                   policy: Policy) -> [Candidate] {
        if policy == .conservative { return conservativeChoices(for: snapshot, letterCase: letterCase) }
        guard !snapshot.input.isEmpty else { return [] }
        let spelling = snapshot.input
        let range = NSRange(location: 0, length: spelling.utf16.count)
        let hasUnconvertedLatin = snapshot.commitPreview.unicodeScalars.contains {
            $0.isASCII && CharacterSet.letters.contains($0)
        }
        let looksEnglish = recognizesEnglish(spelling) || hasUnconvertedLatin || letterCase != .lowercase
        let preferEnglish = snapshot.page == 0 && looksEnglish
        let display = letterCase.apply(to: spelling)
        let english = Candidate(text: display, identifier: "candidate.english", action: .english(display), addsSpaceOnSpaceKey: true)
        var choices: [Candidate] = []
        if preferEnglish { choices.append(english) }
        choices += snapshot.corrections.enumerated().map {
            Candidate(text: $0.element, identifier: "candidate.correction.\($0.offset)", action: .english($0.element))
        }
        if let first = snapshot.candidates.first, !snapshot.corrections.contains(first) {
            choices.append(Candidate(text: first, identifier: "candidate.0", action: .choose(0)))
        }
        if !preferEnglish && (looksEnglish || snapshot.candidates.isEmpty) { choices.append(english) }
        let completions = checker.completions(forPartialWordRange: range, in: spelling, language: "en_US") ?? []
        var seen = Set(choices.map { $0.text.lowercased() })
        var completionCount = 0
        for word in completions where word.caseInsensitiveCompare(spelling) != .orderedSame {
            guard seen.insert(word.lowercased()).inserted else { continue }
            let completion = letterCase.apply(to: word)
            choices.append(Candidate(text: completion, identifier: "candidate.english.\(completionCount)",
                                     action: .english(completion), addsSpaceOnSpaceKey: true))
            completionCount += 1
            if completionCount == 2 { break }
        }
        for (index, text) in snapshot.candidates.enumerated().dropFirst() {
            choices.append(Candidate(text: text, identifier: "candidate.\(index)", action: .choose(index)))
        }
        return choices
    }

    private func conservativeChoices(for snapshot: PinyinEngine.Snapshot, letterCase: EnglishLetterCase) -> [Candidate] {
        guard !snapshot.input.isEmpty else { return [] }
        let spelling = snapshot.input.lowercased()
        let chinese = PinyinCandidates().choices(for: snapshot, letterCase: letterCase)
        let recognized = recognizesEnglish(spelling)
        let ambiguous = PinyinSpelling.isComplete(spelling)
        let display = letterCase.apply(to: spelling)
        let english = Candidate(text: display, identifier: "candidate.english", action: .english(display), addsSpaceOnSpaceKey: true)
        let preferEnglish = recognized && !ambiguous && snapshot.page == 0
        var choices: [Candidate] = []
        var seen: Set<String> = []
        func append(_ candidate: Candidate) {
            if seen.insert(candidate.text.lowercased()).inserted { choices.append(candidate) }
        }
        if preferEnglish { append(english) }
        if let first = chinese.first { append(first) }
        if recognized && !preferEnglish { append(english) }
        // Only an unmistakably Latin prefix gets completions in normal mode.
        // A valid Pinyin word such as haode must never acquire a raw-spelling row.
        if !ambiguous && spelling.count >= 3 {
            let range = NSRange(location: 0, length: spelling.utf16.count)
            let completions = Self.bundledWords.filter { $0.hasPrefix(spelling) }
                + (checker.completions(forPartialWordRange: range, in: spelling, language: "en_US") ?? [])
            var count = 0
            for word in completions {
                guard word.lowercased().hasPrefix(spelling), word.count <= 64,
                      !seen.contains(word.lowercased()) else { continue }
                let text = letterCase.apply(to: word)
                append(Candidate(text: text, identifier: "candidate.english.completion.\(count)",
                                 action: .english(text), addsSpaceOnSpaceKey: true))
                count += 1
                if count == 2 { break }
            }
        }
        for candidate in chinese.dropFirst() { append(candidate) }
        return choices
    }

    private func recognizesEnglish(_ word: String) -> Bool {
        if Self.bundledWordSet.contains(word.lowercased()) { return true }
        func hasMisspelling(_ text: String) -> Bool {
            checker.rangeOfMisspelledWord(in: text, range: NSRange(location: 0, length: text.utf16.count),
                                         startingAt: 0, wrap: false, language: "en_US").location != NSNotFound
        }
        guard !hasMisspelling(word) else { return false }
        // An unavailable system dictionary reports NSNotFound for every input.
        return hasMisspelling("qzxqzxqzxqzx")
    }
}
