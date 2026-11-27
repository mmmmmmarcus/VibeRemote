import XCTest
@testable import vvhisper

@MainActor
final class PinyinMultiErrorTests: XCTestCase {
    private func action(_ value: PinyinEngine.Action) async -> PinyinEngine.Snapshot {
        await withCheckedContinuation { continuation in
            PinyinEngine.shared.perform(value) { continuation.resume(returning: $0) }
        }
    }
    private func type(_ spelling: String) async -> PinyinEngine.Snapshot {
        var snapshot = await action(.clear)
        for byte in spelling.utf8 { snapshot = await action(.key(Int32(byte))) }
        return snapshot
    }
    private func index() throws -> PinyinTypoIndex {
        let root = try XCTUnwrap(Bundle.main.url(forResource: "Rime", withExtension: nil))
        return try XCTUnwrap(PinyinTypoIndex(url: root.appendingPathComponent("PinyinTypo.bin")))
    }

    func testContinuousMultiErrorInputOffersWholeCommitInBothCandidatePolicies() async throws {
        let provider = BilingualCandidates()
        for (input, expected) in [("woxhfiaole", "我知道了"), ("meiyouwrnit", "没有问题"),
                                  ("xirxirni", "谢谢你"), ("drngyixoa", "等一下"),
                                  ("meiyowentti", "没有问题")] {
            for policy in [BilingualCandidates.Policy.conservative, .experimental] {
                let snapshot = await type(input)
                XCTAssertNil(snapshot.error)
                XCTAssertEqual(snapshot.input, input)
                XCTAssertTrue(snapshot.committed.isEmpty)
                let choices = provider.choices(for: snapshot, letterCase: .lowercase, policy: policy)
                let repairs = try index().search(input).repairs
                let candidate = try XCTUnwrap(choices.first(where: { $0.text == expected }),
                                              "\(input): \(choices.map(\.text)); search: \(repairs)")
                XCTAssertTrue(choices.prefix(5).contains(where: { $0.text == expected }), "\(input): \(choices.map(\.text))")
                XCTAssertNotEqual(choices.first?.identifier, candidate.identifier, "Multi-error guesses must not become Space's default")
                let committed = await action(candidate.spaceAction)
                XCTAssertEqual(committed.committed, expected)
                XCTAssertTrue(committed.input.isEmpty)
                XCTAssertTrue(committed.suggestions.isEmpty)
                XCTAssertTrue(committed.candidates.isEmpty)
            }
        }
    }

    func testExactSpellingsAbbreviationsAndUnrelatedInputKeepNativePath() async throws {
        let provider = BilingualCandidates()
        for input in ["wozhidaole", "meiyouwenti", "xiexieni", "dengyixia", "nihao", "haode", "can", "name"] {
            let snapshot = await type(input)
            XCTAssertTrue(snapshot.suggestions.isEmpty, input)
            XCTAssertTrue(snapshot.corrections.isEmpty, input)
            let choices = PinyinCandidates().choices(for: snapshot, letterCase: .lowercase)
            XCTAssertEqual(choices.map(\.text), snapshot.candidates, input)
        }
        for input in ["qzxqzxqzx", "zzzzzzzzzz", "vvhisper", "keyboard", "soundcore", "openai", "wzdl"] {
            let snapshot = await type(input)
            XCTAssertTrue(snapshot.suggestions.isEmpty, "\(input): \(snapshot.suggestions)")
            XCTAssertEqual(snapshot.input, input)
            XCTAssertTrue(snapshot.committed.isEmpty)
            _ = provider.choices(for: snapshot, letterCase: .lowercase, policy: .conservative)
            let literal = await action(.literal)
            XCTAssertEqual(literal.committed, input)
        }
    }

    func testNativeCandidatesKeepIndicesOrderAndSpaceChoice() async throws {
        let snapshot = await type("woxhfiaole")
        let choices = PinyinCandidates().choices(for: snapshot, letterCase: .lowercase)
        let native = choices.filter { if case .choose = $0.action { return true }; return false }
        XCTAssertEqual(native.map(\.text), snapshot.candidates.filter { !snapshot.corrections.contains($0) })
        let first = try XCTUnwrap(choices.first)
        XCTAssertFalse(first.identifier.hasPrefix("candidate.suggestion."))
        let baseline = PinyinCandidates().choices(for: .init(input: snapshot.input, candidates: snapshot.candidates,
                                                            corrections: snapshot.corrections), letterCase: .lowercase)
        XCTAssertEqual(first.text, baseline.first?.text)
        _ = await action(.clear)
    }

    func testStaleCorrectionCannotCommitAfterDeleteClearOrSameSpellingRevision() async throws {
        for change in [PinyinEngine.Action.key(0xff08), .clear] {
            let old = await type("woxhfiaole")
            let candidate = try XCTUnwrap(PinyinCandidates().choices(for: old, letterCase: .lowercase)
                .first { $0.identifier.hasPrefix("candidate.suggestion.") })
            let changed = await action(change)
            let stale = await action(candidate.action)
            XCTAssertTrue(stale.committed.isEmpty)
            XCTAssertEqual(stale.input, changed.input)
        }
        let old = await type("woxhfiaole")
        let candidate = try XCTUnwrap(PinyinCandidates().choices(for: old, letterCase: .lowercase)
            .first { $0.identifier.hasPrefix("candidate.suggestion.") })
        _ = await type("woxhfiaole")
        let stale = await action(candidate.action)
        XCTAssertTrue(stale.committed.isEmpty)
        XCTAssertEqual(stale.input, "woxhfiaole")
        _ = await action(.clear)
    }

    func testQueuedTypingRevisionsCancelSearchWithoutDroppingKeystrokes() async throws {
        _ = await type("woxhfiao")
        let snapshots: [PinyinEngine.Snapshot] = await withCheckedContinuation { continuation in
            var replies: [PinyinEngine.Snapshot] = []
            let commands: [PinyinEngine.Action] = [.key(108), .key(101), .key(0xff08), .clear, .key(110), .key(105)]
            for command in commands {
                PinyinEngine.shared.perform(command) {
                    replies.append($0)
                    if replies.count == commands.count { continuation.resume(returning: replies) }
                }
            }
        }
        XCTAssertEqual(snapshots.map(\.input), ["woxhfiaol", "woxhfiaole", "woxhfiaol", "", "n", "ni"])
        XCTAssertTrue(snapshots.allSatisfy { $0.committed.isEmpty && $0.suggestions.isEmpty })
        XCTAssertEqual(snapshots.map(\.revision), snapshots.map(\.revision).sorted())
        _ = await action(.clear)
    }

    func testMeasuredRealPipelineLatency() async throws {
        var milliseconds: [Double] = []
        for _ in 0..<12 {
            _ = await type("woxhfiaol")
            let start = ProcessInfo.processInfo.systemUptime
            let snapshot = await action(.key(101))
            milliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            XCTAssertTrue(BilingualCandidates().choices(for: snapshot, letterCase: .lowercase, policy: .conservative)
                .contains { $0.text == "我知道了" })
        }
        milliseconds.sort()
        print("TYPO_BENCH pipeline_last_key_ms median=\(milliseconds[6]) p95=\(milliseconds[11])")
        XCTAssertLessThan(milliseconds[11], 250)
        _ = await action(.clear)
    }

    func testIndexCapsCancellationMissingDataAndMeasuredSearchLatency() throws {
        let trie = try index()
        XCTAssertLessThanOrEqual(trie.spellingCount, 80_000)
        XCTAssertLessThanOrEqual(trie.storageBytes, 8_000_000)
        XCTAssertNil(PinyinTypoIndex(data: Data()))
        XCTAssertNil(PinyinTypoIndex(data: Data("VVTYPO01".utf8) + Data(repeating: 255, count: 32)))
        XCTAssertNil(PinyinTypoIndex(url: URL(fileURLWithPath: "/missing-pinyin-typo-index")))
        for text in ["wozhidaole", "Woxhfiaole", "wo xh fiao le", "wo'xhfiaole", "123456", String(repeating: "x", count: 33)] {
            XCTAssertTrue(trie.search(text).repairs.isEmpty)
        }
        XCTAssertTrue(trie.search("woxhfiaole", cancelled: { true }).repairs.isEmpty)
        let expired = trie.search("woxhfiaole", seconds: 0)
        XCTAssertTrue(expired.exhausted)
        XCTAssertTrue(expired.repairs.isEmpty)
        var checks = 0
        let cancelled = trie.search("woxhfiaole", cancelled: { checks += 1; return checks >= 3 })
        XCTAssertTrue(cancelled.exhausted)
        XCTAssertTrue(cancelled.repairs.isEmpty)
        var milliseconds: [Double] = []
        for _ in 0..<12 {
            let start = ProcessInfo.processInfo.systemUptime
            let result = trie.search("woxhfiaole")
            milliseconds.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            XCTAssertFalse(result.exhausted)
            XCTAssertLessThanOrEqual(result.visited, PinyinTypoIndex.visitLimit)
            XCTAssertTrue(result.repairs.contains { $0.spelling == "wozhidaole" }, "\(result.repairs)")
        }
        milliseconds.sort()
        print("TYPO_BENCH search_ms median=\(milliseconds[6]) p95=\(milliseconds[11]) index_bytes=\(trie.storageBytes) spellings=\(trie.spellingCount)")
        XCTAssertLessThan(milliseconds[11], 150) // generous CI scheduling bound, not a device claim
    }
}
