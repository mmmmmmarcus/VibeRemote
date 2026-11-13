import XCTest
@testable import VibeRemote

final class DictationFillersTests: XCTestCase {
    /// The refinement's actual answers for the synthetic filler clips (2026-11-12), and what the
    /// live stream's own `enable_ddc` made of the same speech.
    func testCleansTheMeasuredRefinementOutput() {
        XCTAssertEqual(DictationFillers.clean("嗯，那个，我想我想让他，就是帮我把这个，这个光标的问题修一下，然后然后再提交。"),
                       "我想让他，就是帮我把这个光标的问题修一下，然后再提交。")
        XCTAssertEqual(DictationFillers.clean("Um, So, uh, I want to I want to ask it to like fix the uh uh the cursor bug, and then and then push it."),
                       "So, I want to ask it to like fix the cursor bug, and then push it.")
        XCTAssertEqual(DictationFillers.clean("Um, so, uh, I want to, I want to ask it to like fix the, uh, the cursor bug and then, and then push it."),
                       "So, I want to ask it to like fix the cursor bug and then push it.")
    }

    func testKeepsWordsThatOnlyLookLikeFillers() {
        for text in ["那个文件在哪里？", "就是这样。", "我们研究研究再说。", "谢谢你，看看效果。", "额外的费用",
                     "I know that that is wrong.", "What it is is a bug.", "Bye bye.", "The umbrella is under the user's desk.",
                     "Go. Go now.", "Version 1 2 1 2"] {
            XCTAssertEqual(DictationFillers.clean(text), text, text)
        }
    }

    func testRemovesHesitationsAndStutters() {
        XCTAssertEqual(DictationFillers.clean("呃我我觉得可以"), "我觉得可以")
        XCTAssertEqual(DictationFillers.clean("嗯嗯，好的"), "好的")
        XCTAssertEqual(DictationFillers.clean("所以，所以我们明天发布"), "所以我们明天发布")
        XCTAssertEqual(DictationFillers.clean("um the the build failed"), "the build failed")
        XCTAssertEqual(DictationFillers.clean("Uh, ask Claude"), "Ask Claude")
        XCTAssertEqual(DictationFillers.clean("用 Codex 嗯，写一个测试。"), "用 Codex 写一个测试。")
    }

    func testOnlySeedWithTheSwitchOnIsCleaned() {
        var settings = DictationSettings()
        settings.provider = .seedASR
        XCTAssertEqual(DictationController.finalText("嗯，好的", settings: settings), "好的")
        settings.seedRemoveFillers = false
        XCTAssertEqual(DictationController.finalText("嗯，好的", settings: settings), "嗯，好的")
        settings.provider = .openAI
        settings.seedRemoveFillers = true
        XCTAssertEqual(DictationController.finalText("嗯，好的", settings: settings), "嗯，好的")
    }
}

@MainActor
final class DictationRefinementStreamTests: XCTestCase {
    private func result(_ text: String) -> SeedStreamResult { SeedStreamResult(text: text, definiteUtterances: 0) }

    func testFinalWithoutTextKeepsTheLastReport() {
        let stream = DictationRefinementStream.make()
        stream.handle(.partial(result("first fifteen seconds")))
        stream.handle(.final(nil))
        XCTAssertEqual(stream.answer, "first fifteen seconds")
        stream.handle(.final(result("ignored after the end")))
        XCTAssertEqual(stream.answer, "first fifteen seconds")
    }

    func testFailureOrSilenceFallsBackToFlash() {
        let failed = DictationRefinementStream.make()
        failed.handle(.failed("HTTP 403"))
        XCTAssertNil(failed.answer)
        XCTAssertEqual(failed.failure, "HTTP 403")
        let silent = DictationRefinementStream.make()
        silent.handle(.final(result("  ")))
        XCTAssertNil(silent.answer, "an empty answer goes to flash")
        let unfinished = DictationRefinementStream.make()
        unfinished.handle(.partial(result("so far")))
        XCTAssertNil(unfinished.answer, "only a final result is an answer")
    }

    func testCancelEndsWaiting() async {
        let stream = DictationRefinementStream.make()
        stream.cancel()
        await stream.waitForEnd(timeout: 10)
        XCTAssertEqual(stream.failure, "cancelled")
    }
}

final class SeedSentenceSplitTests: XCTestCase {
    /// `vad_segment_duration` measured to change nothing (2026-11-12), so dictation never sends it.
    func testSentenceSilenceIsOnlySentWhenAsked() throws {
        func request(_ json: Data) throws -> [String: Any] {
            try XCTUnwrap((try JSONSerialization.jsonObject(with: json) as? [String: Any])?["request"] as? [String: Any])
        }
        XCTAssertNil(try request(SeedStreamFrame.requestJSON(appID: ""))["vad_segment_duration"])
        XCTAssertEqual(try request(SeedStreamFrame.requestJSON(appID: "", sentenceSilence: 8000))["vad_segment_duration"] as? Int, 8000)
        let flash = SeedASRDictationEngine.request(audio: DictationAudio(samples: [0]), accessKey: "k", appID: "", resourceID: "r")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(flash.httpBody)) as? [String: Any])
        XCTAssertNil((body["request"] as? [String: Any])?["vad_segment_duration"])
    }
}
