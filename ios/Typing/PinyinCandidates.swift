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
        guard !snapshot.candidates.isEmpty else {
            if !corrected.isEmpty { return corrected }
            let spelling = letterCase.apply(to: snapshot.input)
            return [Candidate(text: spelling, identifier: "candidate.spelling", action: .english(spelling))]
        }
        return corrected + snapshot.candidates.enumerated().filter { !snapshot.corrections.contains($0.element) }.map {
            Candidate(text: $0.element, identifier: "candidate.\($0.offset)", action: .choose($0.offset))
        }
    }
}
