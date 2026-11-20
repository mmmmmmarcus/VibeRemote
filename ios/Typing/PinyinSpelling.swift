import Foundation

/// Detect full syllables only, not Rime's initial-letter abbreviations. This
/// keeps ambiguous words such as can/name Chinese-first in normal Chinese mode.
enum PinyinSpelling {
    private static let syllables: Set<String>? = {
        guard let url = Bundle.main.url(forResource: "Rime", withExtension: nil)?.appendingPathComponent("PinyinSyllables.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
    }()

    static func isComplete(_ spelling: String) -> Bool {
        if syllables == nil { return true } // Missing data must not demote Chinese.
        return syllableCount(spelling) != nil
    }

    static func syllableCount(_ spelling: String) -> Int? {
        guard let syllables else { return nil }
        let bytes = Array(spelling.lowercased().utf8)
        guard !bytes.isEmpty, bytes.count <= 64, bytes.allSatisfy({ (97...122).contains($0) }) else { return nil }
        var reachable = [Int](repeating: 100, count: bytes.count + 1)
        reachable[0] = 0
        for start in bytes.indices where reachable[start] < 100 {
            for end in (start + 1)...min(bytes.count, start + 6) {
                if syllables.contains(String(decoding: bytes[start..<end], as: UTF8.self)) { reachable[end] = min(reachable[end], reachable[start] + 1) }
            }
        }
        return reachable[bytes.count] == 100 ? nil : reachable[bytes.count]
    }
}
