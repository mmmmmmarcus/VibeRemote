import Foundation

/// Immutable, build-time dictionary trie. Search never enumerates arbitrary
/// three-edit strings or compiles dictionaries in the extension. It is a
/// deliberately incomplete beam: exhausting any budget keeps the exact path.
struct PinyinTypoIndex: Sendable {
    struct Repair: Sendable {
        let spelling: String
        let cost: Int // quarter-edit units
        let weight: UInt32
        var score: Double { Double(cost) - 0.35 * min(20, log2(Double(max(1, weight)))) }
    }
    struct Search: Sendable {
        var repairs: [Repair] = []
        var visited = 0
        var exhausted = false
    }
    private struct Node: Sendable {
        let first: UInt32
        let weight: UInt32
        let maximum: UInt32
        let count: UInt16
        let letter: UInt8
    }
    private struct State {
        let node: Int
        let spelling: [UInt8]
        let row: [Int]
        let previous: [Int]
        let score: Double
    }
    static let maximumNodes = 500_000
    static let beamWidth = 192
    static let visitLimit = 16_000
    static let searchSeconds = 0.035
    private let nodes: [Node]
    let spellingCount: Int
    var storageBytes: Int { nodes.count * MemoryLayout<Node>.stride }

    init?(url: URL) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 16 + Self.maximumNodes * 16,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        guard data.count >= 32, data.count <= 16 + Self.maximumNodes * 16,
              data.prefix(8) == Data("VVTYPO01".utf8) else { return nil }
        var parsed: [Node] = []
        var spellings = 0
        let valid = data.withUnsafeBytes { bytes -> Bool in
            func uint32(_ offset: Int) -> UInt32 { UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
            let count = Int(uint32(8))
            spellings = Int(uint32(12))
            guard count > 0, count <= Self.maximumNodes, (1...80_000).contains(spellings), data.count == 16 + count * 16 else { return false }
            parsed.reserveCapacity(count)
            for index in 0..<count {
                let offset = 16 + index * 16
                let first = uint32(offset), weight = uint32(offset + 4), maximum = uint32(offset + 8)
                let children = UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + 12, as: UInt16.self))
                let letter = bytes[offset + 14]
                guard Int(first) > index, Int(first) + Int(children) <= count, children <= 26,
                      maximum >= weight, index == 0 ? letter == 0 : (97...122).contains(letter) else { return false }
                parsed.append(Node(first: first, weight: weight, maximum: maximum, count: children, letter: letter))
            }
            return true
        }
        guard valid else { return nil }
        nodes = parsed
        spellingCount = spellings
    }

    /// Neighbor substitutions, missing/extra letters and adjacent transpositions
    /// can combine. A transposed pair may also contain a neighbor slip, counting
    /// both errors (e.g. a two-thumb inversion following a neighboring key hit).
    func search(_ input: String, cancelled: () -> Bool = { false },
                seconds: TimeInterval = searchSeconds) -> Search {
        let letters = Array(input.utf8)
        guard (6...32).contains(letters.count), letters.allSatisfy({ (97...122).contains($0) }),
              !PinyinSpelling.isComplete(input), !cancelled() else { return Search() }
        let budget = letters.count >= 9 ? 12 : 8
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, seconds)
        let initial = (0...letters.count).map { $0 * 5 }
        var frontier = [State(node: 0, spelling: [], row: initial, previous: initial, score: 0)]
        var result = Search()
        for depth in 1...min(32, letters.count + budget / 5) {
            var next: [State] = []
            for state in frontier {
                let parent = nodes[state.node]
                for index in Int(parent.first)..<(Int(parent.first) + Int(parent.count)) {
                    if result.visited % 64 == 0,
                       cancelled() || ProcessInfo.processInfo.systemUptime >= deadline {
                        // Never publish a partially searched, enumeration-biased list.
                        return Search(visited: result.visited, exhausted: true)
                    }
                    guard result.visited < Self.visitLimit else { return Search(visited: result.visited, exhausted: true) }
                    result.visited += 1
                    let node = nodes[index], byte = node.letter
                    var row = [Int](repeating: 1000, count: letters.count + 1)
                    row[0] = depth * 5
                    for column in 1...letters.count {
                        row[column] = min(state.row[column] + 5, row[column - 1] + 5,
                                          state.row[column - 1] + Self.substitution(letters[column - 1], byte))
                        if column >= 2, let last = state.spelling.last {
                            let swap = state.previous[column - 2] + 4
                                + Self.substitution(letters[column - 2], byte)
                                + Self.substitution(letters[column - 1], last)
                            row[column] = min(row[column], swap)
                        }
                    }
                    let lowerBound = row.min() ?? 1000
                    guard lowerBound <= budget else { continue }
                    let spelling = state.spelling + [byte]
                    if node.weight > 0, row[letters.count] > 0, row[letters.count] <= budget {
                        result.repairs.append(Repair(spelling: String(decoding: spelling, as: UTF8.self),
                                                     cost: row[letters.count], weight: node.weight))
                    }
                    if node.count > 0 {
                        let score = Double(lowerBound) - 0.35 * min(20, log2(Double(max(1, node.maximum))))
                        next.append(State(node: index, spelling: spelling, row: row, previous: state.row, score: score))
                    }
                }
            }
            next.sort { $0.score == $1.score ? $0.node < $1.node : $0.score < $1.score }
            frontier = Array(next.prefix(Self.beamWidth))
            if frontier.isEmpty { break }
        }
        guard !cancelled() else { return Search(visited: result.visited, exhausted: true) }
        result.repairs.sort {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.spelling < $1.spelling
        }
        result.repairs = Array(result.repairs.prefix(4))
        return result
    }

    private static let neighbors: [UInt32] = {
        let rows = ["qwsz", "vghn", "xdfv", "erfsxc", "wrsd", "rtgdvc", "tyfhvb", "yugjbn", "uojk",
                    "uihknm", "iojlm", "opk", "njk", "bhjm", "ipkl", "ol", "wa", "etdf", "wedax",
                    "ryfg", "yihj", "cfgb", "qeas", "zsdc", "tugh", "asx"]
        return rows.map { $0.utf8.reduce(UInt32(0)) { $0 | (1 << ($1 - 97)) } }
    }()
    private static func substitution(_ a: UInt8, _ b: UInt8) -> Int {
        if a == b { return 0 }
        return neighbors[Int(a - 97)] & (1 << (b - 97)) != 0 ? 4 : 1000
    }
}
