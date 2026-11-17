import UIKit

/// Opt-in experiment. Normal Chinese mode does not create a system spell checker.
@MainActor
final class BilingualCandidates {
    typealias Candidate = PinyinCandidates.Candidate
    private let checker: UITextChecker
    init(checker: UITextChecker = UITextChecker()) { self.checker = checker }

    func choices(for snapshot: PinyinEngine.Snapshot, letterCase: EnglishLetterCase) -> [Candidate] {
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
        if let first = snapshot.candidates.first {
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

    private func recognizesEnglish(_ word: String) -> Bool {
        func hasMisspelling(_ text: String) -> Bool {
            checker.rangeOfMisspelledWord(in: text, range: NSRange(location: 0, length: text.utf16.count),
                                         startingAt: 0, wrap: false, language: "en_US").location != NSNotFound
        }
        guard !hasMisspelling(word) else { return false }
        // An unavailable system dictionary reports NSNotFound for every input.
        return hasMisspelling("qzxqzxqzxqzx")
    }
}
