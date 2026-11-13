import Foundation

/// Filler-word cleanup for Seed ASR's final text (2026-11-12, user's request: Doubao IME drops
/// 嗯, 那个 and stutters, VibeRemote kept them). Volcengine's `enable_ddc` (语义顺滑) does this
/// well on the live two-way stream, but measured the same day, the accurate model behind the
/// refinement after release (flash and `bigmodel_nostream` alike) only drops 呃/uh and keeps
/// 嗯, 那个 and repeats such as "我想我想" or "and then and then". The refinement replaces the
/// streamed text, so without this pass the fillers came back the moment Siri was released.
///
/// Deliberately conservative, because it deletes words the recognizer heard:
/// - Hesitation sounds (嗯, 呃, um, uh, er…) go wherever they stand alone.
/// - 那个 / 就是 go only as a clause of their own ("那个，我想"), never as words ("那个文件").
/// - A repeated phrase collapses only when it is a stutter: two or more Latin words, a Latin
///   function word ("the the"; not "that that" or "is is", which can be grammatical), or a CJK phrase that starts with a pronoun or connective
///   ("我想我想", "然后，然后"). Chinese reduplication ("研究研究", "谢谢", "看看") stays.
enum DictationFillers {
    static func clean(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = removeHesitations(text)
        result = collapseLatinRepeats(result)
        result = collapseCJKRepeats(result)
        result = tidy(result)
        if let first = text.first, first.isUppercase, let head = result.first, head.isLowercase {
            result = head.uppercased() + result.dropFirst()
        }
        return result
    }

    // MARK: Hesitations

    private static let latinHesitations = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "hmm", "mm"]
    /// Words that are fillers only as a clause of their own.
    private static let cjkClauseFillers = ["那个", "就是"]
    private static let clauseStart = "(?:^|(?<=[，。！？、；：,.!?;:\\s]))"

    private static func removeHesitations(_ text: String) -> String {
        var result = text
        let latin = latinHesitations.joined(separator: "|")
        // A hesitation and the comma that set it off: "Um, so" → "so", "the, uh, the" → "the, the".
        result = replace(result, "(?i)(?<![A-Za-z0-9'])(?:\(latin))(?![A-Za-z0-9'])[,，]?\\s*", "")
        // 嗯/呃 are never words; 额 is (额外, 额度), so it goes only as its own clause.
        result = replace(result, "[嗯呃唔]+[，,]?", "")
        let clause = (cjkClauseFillers + ["额"]).joined(separator: "|")
        result = replace(result, "\(clauseStart)(?:\(clause))[，,]", "")
        return result
    }

    // MARK: Repeats

    private static let latinFunctionWords: Set<String> = [
        "the", "a", "an", "i", "to", "and", "of", "in", "on", "it", "we", "you", "this",
        "so", "but", "or", "my", "for", "with", "be", "are", "was", "he", "she", "they", "if",
    ]

    private static func collapseLatinRepeats(_ text: String) -> String {
        var words = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        func key(_ word: String) -> String {
            word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",，.。!?！？;；:"))
        }
        func isLatin(_ word: String) -> Bool {
            let k = key(word)
            return !k.isEmpty && k.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.letters.contains($0) || $0 == "'") }
        }
        var changed = true
        while changed {
            changed = false
            outer: for n in stride(from: 4, through: 1, by: -1) where words.count >= 2 * n {
                for i in 0...(words.count - 2 * n) {
                    let first = words[i..<i + n], second = words[i + n..<i + 2 * n]
                    guard first.allSatisfy(isLatin), zip(first, second).allSatisfy({ key($0) == key($1) }) else { continue }
                    // The first copy may end a clause ("then." before "Then"): not a stutter.
                    guard !(first.last.map { [".", "!", "?", "。", "！", "？"].contains($0.last ?? " ") } ?? false) else { continue }
                    guard n >= 2 || latinFunctionWords.contains(key(first.first ?? "")) else { continue }
                    // Keep the second copy: its punctuation belongs to what follows.
                    let capitalized = first.first?.first?.isUppercase == true
                    words.removeSubrange(i..<i + n)
                    if capitalized, var head = words[safe: i], let letter = head.first, letter.isLowercase {
                        head = letter.uppercased() + head.dropFirst()
                        words[i] = head
                    }
                    changed = true
                    break outer
                }
            }
        }
        return words.joined(separator: " ")
    }

    /// The first characters of CJK phrases whose immediate repetition is a stutter.
    private static let cjkStutterStarts: Set<Character> = ["我", "你", "他", "她", "它", "咱", "这", "那", "然", "就", "所", "但", "因", "如", "还", "而", "其"]

    private static func collapseCJKRepeats(_ text: String) -> String {
        var chars = Array(text)
        func isCJK(_ c: Character) -> Bool { c.unicodeScalars.allSatisfy { $0.value >= 0x3400 && $0.value <= 0x9FFF } }
        var i = 0
        while i < chars.count {
            var collapsed = false
            for n in stride(from: 6, through: 1, by: -1) where i + 2 * n <= chars.count {
                let first = chars[i..<i + n]
                guard first.allSatisfy(isCJK), let start = first.first, cjkStutterStarts.contains(start) else { continue }
                // A single pronoun only ("我我"); "这这"/"那那" alone are too short to judge.
                if n == 1, !["我", "你", "他", "她", "它"].contains(start) { continue }
                var j = i + n
                if j < chars.count, chars[j] == "，" || chars[j] == "," { j += 1 }
                guard j + n <= chars.count, Array(chars[j..<j + n]) == Array(first) else { continue }
                chars.removeSubrange(i..<j)
                collapsed = true
                break
            }
            if !collapsed { i += 1 }
        }
        return String(chars)
    }

    // MARK: Punctuation

    private static func tidy(_ text: String) -> String {
        var result = text
        result = replace(result, "，{2,}", "，")
        result = replace(result, ",\\s*,", ",")
        result = replace(result, "[，,]\\s*([。！？.!?])", "$1")
        result = replace(result, "\\s+([,.!?;:])", "$1")
        result = replace(result, " {2,}", " ")
        result = replace(result, "^[\\s，,、]+", "")
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func replace(_ text: String, _ pattern: String, _ template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
