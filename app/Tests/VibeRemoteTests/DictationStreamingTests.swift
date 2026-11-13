import XCTest
@testable import VibeRemote

final class DictationStreamingTests: XCTestCase {
    private func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    func testClientFramesFollowTheDocumentedHeader() {
        let json = Data("{}".utf8)
        XCTAssertEqual([UInt8](SeedStreamFrame.fullClientRequest(json: json)), [0x11, 0x10, 0x10, 0x00] + bigEndian(2) + [0x7b, 0x7d])
        XCTAssertEqual([UInt8](SeedStreamFrame.audio(Data([1, 2]), last: false)), [0x11, 0x20, 0x00, 0x00] + bigEndian(2) + [1, 2])
        // The last packet is the "negative" one: flags 0b0010, and it may carry no audio.
        XCTAssertEqual([UInt8](SeedStreamFrame.audio(Data(), last: true)), [0x11, 0x22, 0x00, 0x00] + bigEndian(0))
    }

    func testServerResponsesCarryASequenceAndMarkTheLastOne() throws {
        let payload = Array(#"{"result":{"text":"hi"}}"#.utf8)
        let partial = Data([0x11, 0x91, 0x10, 0x00] + bigEndian(2) + bigEndian(UInt32(payload.count)) + payload)
        XCTAssertEqual(try SeedStreamFrame.parse(partial), .response(isLast: false, payload: Data(payload)))
        let last = Data([0x11, 0x93, 0x10, 0x00] + bigEndian(UInt32(bitPattern: -3)) + bigEndian(UInt32(payload.count)) + payload)
        XCTAssertEqual(try SeedStreamFrame.parse(last), .response(isLast: true, payload: Data(payload)))
    }

    func testErrorFramesAndMalformedFrames() throws {
        let message = Array("bad resource".utf8)
        let error = Data([0x11, 0xF0, 0x10, 0x00] + bigEndian(45_000_001) + bigEndian(UInt32(message.count)) + message)
        XCTAssertEqual(try SeedStreamFrame.parse(error), .error(code: 45_000_001, message: "bad resource"))
        XCTAssertThrowsError(try SeedStreamFrame.parse(Data([0x11, 0x91])))
        XCTAssertThrowsError(try SeedStreamFrame.parse(Data([0x11, 0x90, 0x10, 0x00] + bigEndian(50) + [1, 2])))
        XCTAssertThrowsError(try SeedStreamFrame.parse(Data([0x21, 0x90, 0x10, 0x00] + bigEndian(0))))
    }

    func testGzipPayloadsAreUnwrapped() throws {
        let json = Data(#"{"result":{"text":"压缩"}}"#.utf8)
        let deflated = try (json as NSData).compressed(using: .zlib) as Data
        let gzip = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]) + deflated + Data(repeating: 0, count: 8)
        let frame = Data([0x11, 0x91, 0x11, 0x00] + bigEndian(1) + bigEndian(UInt32(gzip.count))) + gzip
        XCTAssertEqual(try SeedStreamFrame.parse(frame), .response(isLast: false, payload: json))
    }

    func testResultsParseTextAndDefiniteSentences() {
        let full = Data(#"{"result":{"text":"一。二","utterances":[{"text":"一。","definite":true},{"text":"二","definite":false}]}}"#.utf8)
        XCTAssertEqual(SeedStreamResult.parse(full), SeedStreamResult(text: "一。二", definiteUtterances: 1))
        let list = Data(#"{"result":[{"text":"list form"}]}"#.utf8)
        XCTAssertEqual(SeedStreamResult.parse(list)?.text, "list form")
        XCTAssertNil(SeedStreamResult.parse(Data(#"{"audio_info":{"duration":200}}"#.utf8)))
    }

    func testRequestAsksForStreamingOf16kPCMWithoutASecondPass() throws {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: SeedStreamFrame.requestJSON(appID: "42")) as? [String: Any])
        let audio = try XCTUnwrap(json["audio"] as? [String: Any])
        let request = try XCTUnwrap(json["request"] as? [String: Any])
        XCTAssertEqual(audio["format"] as? String, "pcm")
        XCTAssertEqual(audio["rate"] as? Int, 16_000)
        XCTAssertEqual(request["enable_nonstream"] as? Bool, false, "no second pass while speaking; refined once after release")
        XCTAssertEqual(request["result_type"] as? String, "full")
        XCTAssertEqual((json["user"] as? [String: Any])?["uid"] as? String, "42")
        XCTAssertEqual(SeedStreamFrame.audioPacketBytes, 16_000 / 5 * 2, "200 ms of 16-bit mono")
    }

    func testPCMIsLittleEndianAndClamped() {
        XCTAssertEqual([UInt8](SeedStreamFrame.pcm16([0, 1, -1, 2])), [0x00, 0x00, 0xFF, 0x7F, 0x01, 0x80, 0xFF, 0x7F])
    }

    func testHandshakeHeadersMatchBothConsoleStyles() {
        let old = SeedStreamingSession.request(accessKey: "token", appID: "7967928849", resourceID: "")
        XCTAssertEqual(old.url, SeedStreamFrame.endpoint)
        XCTAssertEqual(old.value(forHTTPHeaderField: "X-Api-App-Key"), "7967928849")
        XCTAssertEqual(old.value(forHTTPHeaderField: "X-Api-Access-Key"), "token")
        XCTAssertNil(old.value(forHTTPHeaderField: "X-Api-Key"))
        XCTAssertEqual(old.value(forHTTPHeaderField: "X-Api-Resource-Id"), "volc.bigasr.sauc.duration")
        XCTAssertNotNil(old.value(forHTTPHeaderField: "X-Api-Connect-Id"))
        let new = SeedStreamingSession.request(accessKey: "key", appID: "", resourceID: "volc.seedasr.sauc.duration")
        XCTAssertEqual(new.value(forHTTPHeaderField: "X-Api-Key"), "key")
        XCTAssertNil(new.value(forHTTPHeaderField: "X-Api-App-Key"))
        XCTAssertEqual(new.value(forHTTPHeaderField: "X-Api-Resource-Id"), "volc.seedasr.sauc.duration")
    }

    /// The revision rule: keep the common prefix, replace only the tail that changed.
    func testTypewriterReplacesOnlyTheChangedTail() {
        XCTAssertTrue(DictationTypewriterPlan.edit(displayed: "hello wor", target: "hello world") == (0, "ld"))
        XCTAssertTrue(DictationTypewriterPlan.edit(displayed: "hello word", target: "hello world.") == (1, "ld."))
        XCTAssertTrue(DictationTypewriterPlan.edit(displayed: "你好世", target: "你好，世界") == (1, "，世界"))
        XCTAssertTrue(DictationTypewriterPlan.edit(displayed: "", target: "abc") == (0, "abc"))
        XCTAssertTrue(DictationTypewriterPlan.edit(displayed: "abc", target: "abc") == (0, ""))
        XCTAssertTrue(DictationTypewriterPlan.edit(displayed: "abc", target: "") == (3, ""))
        // Emoji and combining marks count as one character each, as Backspace does.
        XCTAssertTrue(DictationTypewriterPlan.edit(displayed: "ok 👍🏽", target: "ok") == (2, ""))
    }

    /// Smooth while nearly caught up, never far behind when text backs up.
    /// The correction after release may re-anchor on the editor's own caret only when this hold's
    /// text is verifiably right before it (ChatGPT counted 1–2 ahead, 2026-11-13).
    func testReanchorOnlyWhenTheHoldsTextIsRightBeforeTheCaret() {
        let reanchor = DictationTypewriterPlan.reanchor
        // The caret past the count (anchor read as 13, so 24 expected), the hold's text right before it.
        XCTAssertEqual(reanchor("Earlier note.\nhello there", 25, "hello there"), 14)
        // A trailing paragraph break after the caret.
        XCTAssertEqual(reanchor("Earlier note.\nhello there\n", 25, "hello there"), 14)
        // Offsets that leave out an earlier paragraph break: the caret at the end reads one short.
        XCTAssertEqual(reanchor("Earlier note.\nhello there", 24, "hello there"), 13)
        // Something else before the caret: never re-anchor, so nothing is deleted.
        XCTAssertNil(reanchor("Earlier note.\nhello thera", 26, "hello there"))
        XCTAssertNil(reanchor("hello there and more", 20, "hello there"), "caret not after the hold's text")
        XCTAssertNil(reanchor("hi", 2, "hello there"))
        XCTAssertNil(reanchor("anything", 3, ""))
    }

    func testHeldTextOnlyGrowsWithWhatTwoPartialsAgreeOn() {
        let grow = DictationTypewriterPlan.growth
        // The first partial has nothing to agree with yet; the moving tail stays off screen.
        XCTAssertEqual(grow("", "", "I want to by"), "")
        XCTAssertEqual(grow("", "I want to by", "I want to buy a"), "I want to b")
        XCTAssertEqual(grow("I want to b", "I want to buy a", "I want to buy a car"), "I want to buy a")
        // A shorter agreement never takes text back off the screen.
        XCTAssertEqual(grow("I want to buy a", "I want to buy a car", "I want to"), "I want to buy a")
        // A revision earlier in the text (capitalization, punctuation) does not stop typing: it
        // continues after the shown text's last characters, found again near the end.
        XCTAssertEqual(grow("i want to buy a", "I want to buy a car.", "I want to buy a car. Today"),
                       "i want to buy a car.")
        // If those characters were revised away too, nothing is added until release.
        XCTAssertEqual(grow("I want to buy a", "I wanted to try it", "I wanted to try it now"), "I want to buy a")
        // Revisions of earlier text add up: the shown end is still found, by a run of its last
        // twelve characters that occurs once, past the near window (typing stalled, 2026-11-13).
        XCTAssertEqual(grow("Well um so like you know I think we should go to the store",
                            "Well I think we should go to the store and buy",
                            "Well I think we should go to the store and buy milk"),
                       "Well um so like you know I think we should go to the store and buy")
        // A revised last word: the characters just before it stand in.
        XCTAssertEqual(grow("We will meet at the cafe", "We will meet at the café tomorrow", "We will meet at the café tomorrow at"),
                       "We will meet at the cafe tomorrow")
        // Punctuation the recognizer adds to words already shown does not stop typing
        // (reproduced 2026-11-13: "quickly and" → "quickly, and" froze the rest of the hold).
        XCTAssertEqual(grow("when I typed quickly and", "when I typed quickly, and I would rather.",
                            "when I typed quickly, and I would rather it."),
                       "when I typed quickly and I would rather")
        XCTAssertEqual(grow("Right now it", "right now, it jumps around.", "right now, it jumps around a lot."),
                       "Right now it jumps around")
        // Punctuation already on screen is not typed twice.
        XCTAssertEqual(grow("quickly, ", "quickly, and I would.", "quickly, and I would rather."), "quickly, and I would")
        XCTAssertEqual(grow("我觉得", "我觉得，我们应该改一下。", "我觉得，我们应该改一下光标。"), "我觉得，我们应该改一下")
        // A long run that occurs twice far from the end is not trusted.
        XCTAssertEqual(grow("we said hello there friends ok", "hello there friends and then hello there friends again",
                            "hello there friends and then hello there friends again now"),
                       "we said hello there friends ok")
        // An earlier repeat of the anchor far from the end is not mistaken for it.
        XCTAssertEqual(grow("ab ab ab", "AB xx yy zz ab ab ab", "AB xx yy zz ab ab ab ab"), "ab ab ab")
        XCTAssertEqual(DictationTypewriterPlan.commonPrefix("你好世界", "你好吗"), "你好")
    }

    func testTypewriterPaceScalesWithBacklog() {
        XCTAssertTrue(DictationTypewriterPlan.pace(backlog: 0) == (0, DictationTypewriterPlan.tick))
        XCTAssertTrue(DictationTypewriterPlan.pace(backlog: 1) == (1, 0.045))
        let nine = DictationTypewriterPlan.pace(backlog: 9)
        XCTAssertEqual(nine.characters, 1); XCTAssertEqual(nine.interval, 0.02, accuracy: 0.0001)
        XCTAssertTrue(DictationTypewriterPlan.pace(backlog: 30) == (2, DictationTypewriterPlan.tick))
        let large = DictationTypewriterPlan.pace(backlog: 150)
        XCTAssertEqual(large.characters, 10)
        // A whole backlog lands within about one packet interval.
        XCTAssertLessThanOrEqual(Double((150 + large.characters - 1) / large.characters) * large.interval, 0.19)
    }

    func testChunksFitOneKeyEvent() {
        XCTAssertEqual(DictationTypewriterPlan.chunk("hello", characters: 2), "he")
        XCTAssertEqual(DictationTypewriterPlan.chunk(String(repeating: "a", count: 40), characters: 30).count, 20)
        let emoji = String(repeating: "👨‍👩‍👧", count: 4)          // 8 UTF-16 units each
        XCTAssertEqual(DictationTypewriterPlan.chunk(emoji, characters: 4).utf16.count, 16)
        XCTAssertEqual(DictationTypewriterPlan.chunk("x", characters: 0), "x")
    }

    /// Corrections delete real text, so they only run with the caret where typing left it.
    func testCaretGuardOnlyAllowsCorrectionsAtTheTypedEnd() {
        XCTAssertEqual(DictationTypewriterPlan.caretCheck(expected: 12, observed: CFRange(location: 12, length: 0)), .proceed)
        XCTAssertEqual(DictationTypewriterPlan.caretCheck(expected: 12, observed: CFRange(location: 7, length: 0)), .wait)
        XCTAssertEqual(DictationTypewriterPlan.caretCheck(expected: 12, observed: CFRange(location: 12, length: 3)), .wait)
        XCTAssertEqual(DictationTypewriterPlan.caretCheck(expected: nil, observed: CFRange(location: 0, length: 0)), .proceed)
        XCTAssertEqual(DictationTypewriterPlan.caretCheck(expected: 12, observed: nil), .proceed)
    }

    func testStreamingIsOnByDefaultAndRoundTrips() throws {
        let suite = "DictationStreamingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(DictationSettings.load(from: defaults).seedStreaming)
        XCTAssertEqual(DictationSettings.load(from: defaults).seedStreamResourceID, "volc.bigasr.sauc.duration")
        var settings = DictationSettings.load(from: defaults)
        settings.seedStreaming = false
        settings.save(to: defaults)
        XCTAssertFalse(DictationSettings.load(from: defaults).seedStreaming)
    }

    /// How a stream ends decides between its own text and the flash fallback. These paths
    /// never touch the typewriter, so nothing is typed.
    @MainActor
    func testLiveHoldEndsOnFinalFailureOrTimeout() async {
        let finished = DictationLiveHold(typewriter: DictationTypewriter(after: nil))
        finished.handle(.final(SeedStreamResult(text: "done", definiteUtterances: 1)))
        XCTAssertTrue(finished.succeeded)
        XCTAssertEqual(finished.latest?.text, "done")

        let failed = DictationLiveHold(typewriter: DictationTypewriter(after: nil))
        failed.handle(.failed("error 45000001"))
        XCTAssertFalse(failed.succeeded)
        failed.handle(.final(nil))
        XCTAssertNil(failed.latest, "events after the end are ignored")

        let silent = DictationLiveHold(typewriter: DictationTypewriter(after: nil))
        await silent.waitForEnd(timeout: 0.05)
        XCTAssertFalse(silent.succeeded)
        XCTAssertEqual(silent.failure, "no final result within 0 s")
    }

    @MainActor
    func testTypewriterWithNothingToTypeFinishesWithoutTyping() async {
        let typewriter = DictationTypewriter(after: nil)
        await typewriter.finish(nil)
        XCTAssertTrue(typewriter.isDone)
        XCTAssertEqual(typewriter.displayed, "")
        let stopped = DictationTypewriter(after: nil)
        stopped.stop("test")
        stopped.update("ignored")
        await stopped.finish("ignored")
        XCTAssertEqual(stopped.displayed, "")
        XCTAssertEqual(stopped.stoppedReason, "test")
    }
}

final class DictationReplacementTests: XCTestCase {
    func testReplacementRangeCoversOnlyTheChangedTailOfThisHold() {
        // "Hello wor" typed at offset 10; the refined text keeps "Hello " and replaces "wor".
        let range = DictationTypewriterPlan.replacementRange(anchor: 10, displayed: "Hello wor", delete: 3)
        XCTAssertEqual(range.location, 16)
        XCTAssertEqual(range.length, 3)
        // UTF-16 units, not characters: the emoji counts two.
        let emoji = DictationTypewriterPlan.replacementRange(anchor: 0, displayed: "好👋了吗", delete: 2)
        XCTAssertEqual(emoji.location, 3)
        XCTAssertEqual(emoji.length, 2)
        // Never reaches before the hold's own text.
        let all = DictationTypewriterPlan.replacementRange(anchor: 5, displayed: "abc", delete: 9)
        XCTAssertEqual(all.location, 5)
        XCTAssertEqual(all.length, 3)
    }

    func testChunksSplitIntoKeyEventsOnCharacterBoundaries() {
        let text = String(repeating: "字", count: 45) + "👋👋"
        let pieces = DictationTypewriterPlan.chunks(text)
        XCTAssertEqual(pieces.joined(), text)
        XCTAssertTrue(pieces.allSatisfy { $0.utf16.count <= 20 && !$0.isEmpty })
        XCTAssertEqual(pieces.count, 3)
        XCTAssertEqual(DictationTypewriterPlan.chunks(""), [])
    }
}
