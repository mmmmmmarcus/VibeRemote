import XCTest
@testable import vvhisper

final class BilingualDictationTests: XCTestCase {
    func testSeedStreamRefinementAndFallbackKeepDefaultBilingualModel() throws {
        // Both live and nostream refinement use this same request builder.
        let stream = SeedStreamFrame.requestJSON(appID: "", removeFillers: true)
        let fallback = try XCTUnwrap(SeedASRDictationEngine.request(
            audio: DictationAudio(samples: [0]), accessKey: "test", appID: "",
            resourceID: SeedASRDictationEngine.defaultResourceID).httpBody)
        for data in [stream, fallback] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let audio = try XCTUnwrap(json["audio"] as? [String: Any])
            let request = try XCTUnwrap(json["request"] as? [String: Any])
            XCTAssertNil(audio["language"], "Do not force mixed speech into one language")
            XCTAssertNil(request["language"])
            XCTAssertEqual(request["model_name"] as? String, "bigmodel")
            XCTAssertEqual(request["enable_punc"] as? Bool, true)
        }
    }

    func testMixedTranscriptSurvivesParsingCleanupAndTyping() throws {
        let text = "我们今天 test 一下 Soundcore，please keep 中文和 English 原样。"
        let data = try JSONSerialization.data(withJSONObject: ["result": ["text": text]])
        XCTAssertEqual(SeedStreamResult.parse(data)?.text, text)
        let final = try SeedASRDictationEngine.parse(data: data, statusCode: "20000000", message: nil, httpStatus: 200)
        let cleaned = DictationTyper.normalized(DictationFillers.clean(final))
        XCTAssertEqual(cleaned, text)
        XCTAssertEqual(DictationTyper.chunks(cleaned).joined(), text)
        let partial = "我们今天 test 一下 Sound"
        let edit = DictationTypewriterPlan.edit(displayed: partial, target: cleaned)
        XCTAssertTrue(edit == (0, "core，please keep 中文和 English 原样。"))
    }
}
