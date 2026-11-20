import Foundation

/// Try bounded, one-slip repairs only when the literal input is not complete
/// Pinyin. Exact spellings/phrase ranking and initial-letter shortcuts stay intact.
enum PinyinTypo {
    static func spellings(for input: String) -> [String] {
        let letters = Array(input)
        guard (4...32).contains(letters.count), letters.allSatisfy({ $0.isASCII && $0.isLowercase }),
              !PinyinSpelling.isComplete(input) else { return [] }
        var result: [String] = [], seen: Set<String> = [input]
        func append(_ value: [Character]) {
            let spelling = String(value)
            if result.count < 8, seen.insert(spelling).inserted, PinyinSpelling.isComplete(spelling) { result.append(spelling) }
        }
        // Transpositions are especially common when alternating thumbs.
        for index in 0..<(letters.count - 1) {
            var copy = letters; copy.swapAt(index, index + 1); append(copy)
        }
        for index in 1..<letters.count where letters[index] == letters[index - 1] {
            var copy = letters; copy.remove(at: index); append(copy)
        }
        // Nearby key substitutions, never arbitrary rewrites or phonetic changes.
        let neighbors: [Character: String] = ["q":"wa", "w":"qeas", "e":"wrsd", "r":"etdf", "t":"ryfg", "y":"tugh",
            "u":"yihj", "i":"uojk", "o":"ipkl", "p":"ol", "a":"qwsz", "s":"wedax", "d":"erfsxc", "f":"rtgdvc",
            "g":"tyfhvb", "h":"yugjbn", "j":"uihknm", "k":"iojlm", "l":"opk", "z":"asx", "x":"zsdc", "c":"xdfv",
            "v":"cfgb", "b":"vghn", "n":"bhjm", "m":"njk"]
        for index in letters.indices {
            for neighbor in neighbors[letters[index]] ?? "" {
                var copy = letters; copy[index] = neighbor; append(copy)
            }
            if result.count == 8 { break }
        }
        return result.enumerated().sorted {
            let lhs = PinyinSpelling.syllableCount($0.element) ?? 100
            let rhs = PinyinSpelling.syllableCount($1.element) ?? 100
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }
}
