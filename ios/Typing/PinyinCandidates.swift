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
        guard !snapshot.candidates.isEmpty else {
            let spelling = letterCase.apply(to: snapshot.input)
            return [Candidate(text: spelling, identifier: "candidate.spelling", action: .english(spelling))]
        }
        return snapshot.candidates.enumerated().map {
            Candidate(text: $0.element, identifier: "candidate.\($0.offset)", action: .choose($0.offset))
        }
    }
}
