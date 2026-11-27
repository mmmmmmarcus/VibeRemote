import Foundation

/// Chinese mode follows Rime's dictionary order, without English detection or completions.
struct PinyinCandidates {
    struct Candidate {
        let text: String
        let identifier: String
        let action: PinyinEngine.Action
        var addsSpaceOnSpaceKey = false
        var spaceAction: PinyinEngine.Action {
            if addsSpaceOnSpaceKey, case .english(let word) = action { return .english(word + " ") }
            return action
        }
    }

    func choices(for snapshot: PinyinEngine.Snapshot, letterCase: EnglishLetterCase) -> [Candidate] {
        guard !snapshot.input.isEmpty else { return [] }
        let corrected = snapshot.corrections.enumerated().map {
            Candidate(text: $0.element, identifier: "candidate.correction.\($0.offset)", action: .english($0.element))
        }
        let suggested = suggestions(for: snapshot)
        guard !snapshot.candidates.isEmpty else {
            if !corrected.isEmpty { return corrected + suggested }
            let spelling = letterCase.apply(to: snapshot.input)
            return [Candidate(text: spelling, identifier: "candidate.spelling", action: .english(spelling))] + suggested
        }
        let native = snapshot.candidates.enumerated().filter { !snapshot.corrections.contains($0.element) }.map {
            Candidate(text: $0.element, identifier: "candidate.\($0.offset)", action: .choose($0.offset))
        }
        // Multi-error guesses never replace the highlighted exact/one-slip path.
        // Keep every native candidate's relative order and original Rime index.
        return corrected + Array(native.prefix(1)) + suggested + Array(native.dropFirst())
    }

    func suggestions(for snapshot: PinyinEngine.Snapshot) -> [Candidate] {
        guard snapshot.page == 0 else { return [] }
        return snapshot.suggestions.enumerated().filter {
            !snapshot.candidates.contains($0.element) && !snapshot.corrections.contains($0.element)
        }.map {
            Candidate(text: $0.element, identifier: "candidate.suggestion.\($0.offset)",
                      action: .correction(text: $0.element, input: snapshot.input, revision: snapshot.revision))
        }
    }
}
