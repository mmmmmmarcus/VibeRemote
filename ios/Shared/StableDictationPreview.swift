import Foundation

/// Matches the Mac typewriter: show agreed growth while held, defer corrections
/// to the polished result. Operates on Characters so emoji/CJK stay intact.
enum StableDictationPreview {
    static func growth(shown target: String, previous: String, latest: String) -> String {
        let agreed = commonPrefix(previous, latest)
        if agreed.hasPrefix(target) { return agreed.count > target.count ? agreed : target }
        guard !target.isEmpty else { return agreed }
        return target + (continuation(of: target, in: agreed) ?? "")
    }

    /// What follows the end of the shown text in the agreed text, or nil when that end cannot be
    /// found. Matching compares only letters, digits and CJK characters, case-insensitively: the
    /// recognizer keeps adding punctuation to words already typed ("quickly and" → "quickly, and"),
    /// and an exact match then never found the shown end again, so typing stopped for the rest of
    /// the hold at the first inserted comma (2026-11-13, reproduced with `--growth`).
    ///
    /// The shown end is found by its last six such characters near where they ended (the last
    /// occurrence, so an earlier repeat cannot type a duplicate); failing that, by its last twelve
    /// where they occur exactly once, because revisions of earlier words add up (a 15 s hold
    /// drifted past a fixed window the same day). If the last word itself was revised ("cafe" →
    /// "café"), the characters just before it within that word stand in, and as many agreed
    /// characters are skipped.
    static func continuation(of shown: String, in agreed: String) -> String? {
        func isText(_ character: Character) -> Bool { character.isLetter || character.isNumber }
        // Each text character with its offset in the original string.
        func skeleton(_ text: [Character]) -> [(character: String, offset: Int)] {
            text.enumerated().filter { isText($0.element) }.map { (String($0.element).lowercased(), $0.offset) }
        }
        let shownCharacters = Array(shown), agreedCharacters = Array(agreed)
        let shownText = skeleton(shownCharacters).map(\.character)
        let agreedSkeleton = skeleton(agreedCharacters)
        let agreedText = agreedSkeleton.map(\.character)
        guard !shownText.isEmpty else { return nil }
        func endings(of anchor: ArraySlice<String>) -> [Int] {
            guard !anchor.isEmpty, anchor.count <= agreedText.count else { return [] }
            return (anchor.count...agreedText.count).filter { agreedText[($0 - anchor.count)..<$0].elementsEqual(anchor) }
        }
        // The shown text's last word, if it ends in one. Skipping stays inside it, keeping at
        // least one of its letters in the anchor: an anchor from an earlier word can match a
        // repeat of that word elsewhere and type a duplicate.
        let lastWord = shownCharacters.reversed().prefix(while: isText).count
        var matched: Int?
        for skip in 0...min(8, max(0, lastWord - 1), shownText.count - 1) {
            let end = shownText.count - skip
            let near = shownText[max(0, end - 6)..<end]
            if let last = endings(of: near).last(where: { abs($0 - end) <= 12 }) {
                matched = last + skip
            } else if end >= 12 {
                let long = endings(of: shownText[(end - 12)..<end])
                if long.count == 1 { matched = long[0] + skip }
            }
            if matched != nil { break }
        }
        guard let matched, matched <= agreedText.count else { return nil }
        // Back to the agreed text: just after the matched character.
        var index = matched == 0 ? 0 : agreedSkeleton[matched - 1].offset + 1
        // Punctuation or spacing the screen already ends with is not typed twice: skip the
        // agreed text's own run there, keeping a space if only the agreed text has one.
        let shownTrail = shownCharacters.reversed().prefix { !isText($0) }
        guard !shownTrail.isEmpty else { return String(agreedCharacters[index...]) }
        let runStart = index
        while index < agreedCharacters.count, !isText(agreedCharacters[index]) { index += 1 }
        let run = agreedCharacters[runStart..<index]
        let space = run.contains(where: \.isWhitespace) && !shownTrail.contains(where: \.isWhitespace)
        return (space ? " " : "") + String(agreedCharacters[index...])
    }

    static func commonPrefix(_ a: String, _ b: String) -> String {
        var end = a.startIndex, other = b.startIndex
        while end < a.endIndex, other < b.endIndex, a[end] == b[other] {
            end = a.index(after: end); other = b.index(after: other)
        }
        return String(a[..<end])
    }
}
