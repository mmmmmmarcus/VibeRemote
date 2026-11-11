import XCTest
@testable import VibeRemote

final class DictationTests: XCTestCase {
    func testWAVHeaderDescribes16kMonoPCM() {
        let audio = DictationAudio(samples: [0, 1, -1, 0.5])
        let wav = audio.wavData()
        XCTAssertEqual(wav.count, 44 + 8)
        XCTAssertEqual(String(decoding: wav[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        func u32(_ offset: Int) -> UInt32 { wav[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        func i16(_ offset: Int) -> Int16 { Int16(bitPattern: UInt16(wav[offset]) | UInt16(wav[offset + 1]) << 8) }
        XCTAssertEqual(u32(24), 16_000)
        XCTAssertEqual(i16(22), 1, "mono")
        XCTAssertEqual(i16(34), 16, "bits per sample")
        XCTAssertEqual(u32(40), 8, "data size")
        XCTAssertEqual(i16(46), Int16.max)
        XCTAssertEqual(i16(48), -Int16.max)
    }

    func testTyperChunksNeverSplitACharacter() {
        let text = String(repeating: "a", count: 19) + "👍🏽" + "中文"
        let chunks = DictationTyper.chunks(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 20 })
        XCTAssertEqual(chunks.first, String(repeating: "a", count: 19), "the emoji moves whole into the next event")
        XCTAssertTrue(DictationTyper.chunks("").isEmpty)
    }

    func testTranscriptBecomesOneLineSoItCannotSubmit() {
        XCTAssertEqual(DictationTyper.normalized("  Hello\nworld \n\n 你好 "), "Hello world 你好")
        XCTAssertEqual(DictationTyper.normalized(" \n "), "")
    }

    func testLanguageCodesForWhisperAndOpenAI() {
        XCTAssertNil(DictationLanguage.isoCode(""))
        XCTAssertEqual(DictationLanguage.isoCode("zh-CN"), "zh")
        XCTAssertEqual(DictationLanguage.isoCode("en-US"), "en")
        XCTAssertEqual(DictationLanguage.isoCode("yue-CN"), "yue")
        XCTAssertEqual(DictationLanguage.choices.first?.id, "")
    }

    func testOpenAIRequestIsMultipartWithModelLanguageAndFile() throws {
        let audio = DictationAudio(samples: [0, 0.25])
        let request = OpenAIDictationEngine.request(audio: audio, apiKey: "sk-test", model: "gpt-4o-mini-transcribe",
                                                    language: "zh-CN", boundary: "B")
        XCTAssertEqual(request.url, OpenAIDictationEngine.endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=B")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\ngpt-4o-mini-transcribe\r\n"))
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nzh\r\n"))
        XCTAssertTrue(body.contains("filename=\"dictation.wav\""))
        XCTAssertTrue(body.hasSuffix("\r\n--B--\r\n"))
        let automatic = OpenAIDictationEngine.request(audio: audio, apiKey: "k", model: "m", language: "", boundary: "B")
        XCTAssertFalse(String(decoding: automatic.httpBody!, as: UTF8.self).contains("name=\"language\""))
    }

    func testOpenAIResponseParsing() throws {
        XCTAssertEqual(try OpenAIDictationEngine.parse(data: Data(#"{"text":"hi there"}"#.utf8), status: 200), "hi there")
        XCTAssertThrowsError(try OpenAIDictationEngine.parse(
            data: Data(#"{"error":{"message":"Incorrect API key"}}"#.utf8), status: 401)) { error in
            XCTAssertEqual(error.localizedDescription, "OpenAI: Incorrect API key")
        }
    }

    func testSeedRequestSupportsBothConsoleKeyStyles() throws {
        let audio = DictationAudio(samples: [0, 0.5])
        let modern = SeedASRDictationEngine.request(audio: audio, accessKey: "key", appID: "",
                                                    resourceID: SeedASRDictationEngine.defaultResourceID, requestID: "r1")
        XCTAssertEqual(modern.url, SeedASRDictationEngine.endpoint)
        XCTAssertEqual(modern.value(forHTTPHeaderField: "X-Api-Key"), "key")
        XCTAssertNil(modern.value(forHTTPHeaderField: "X-Api-App-Key"))
        XCTAssertEqual(modern.value(forHTTPHeaderField: "X-Api-Resource-Id"), "volc.bigasr.auc_turbo")
        XCTAssertEqual(modern.value(forHTTPHeaderField: "X-Api-Request-Id"), "r1")
        XCTAssertEqual(modern.value(forHTTPHeaderField: "X-Api-Sequence"), "-1")

        let legacy = SeedASRDictationEngine.request(audio: audio, accessKey: "token", appID: "123",
                                                    resourceID: "volc.bigasr.auc_turbo", requestID: "r2")
        XCTAssertEqual(legacy.value(forHTTPHeaderField: "X-Api-App-Key"), "123")
        XCTAssertEqual(legacy.value(forHTTPHeaderField: "X-Api-Access-Key"), "token")
        XCTAssertNil(legacy.value(forHTTPHeaderField: "X-Api-Key"))

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(legacy.httpBody)) as? [String: Any])
        XCTAssertEqual((body["user"] as? [String: Any])?["uid"] as? String, "123")
        XCTAssertEqual((body["request"] as? [String: Any])?["model_name"] as? String, "bigmodel")
        let encoded = try XCTUnwrap((body["audio"] as? [String: Any])?["data"] as? String)
        XCTAssertEqual(Data(base64Encoded: encoded), audio.wavData())
    }

    func testSeedResponseUsesHeaderStatus() throws {
        let data = Data(#"{"result":{"text":"你好世界"}}"#.utf8)
        XCTAssertEqual(try SeedASRDictationEngine.parse(data: data, statusCode: "20000000", message: "OK", httpStatus: 200), "你好世界")
        XCTAssertEqual(try SeedASRDictationEngine.parse(data: Data(), statusCode: "20000003", message: nil, httpStatus: 200), "",
                       "silence is an empty transcript, not an error")
        XCTAssertThrowsError(try SeedASRDictationEngine.parse(data: Data(), statusCode: "45000001", message: "bad params", httpStatus: 400)) {
            XCTAssertEqual($0.localizedDescription, "Seed ASR: 45000001 bad params")
        }
    }

    func testSettingsRoundTripAndFallBackToDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DictationTests-\(UUID().uuidString)"))
        XCTAssertEqual(DictationSettings.load(from: defaults), DictationSettings())
        var settings = DictationSettings()
        settings.provider = .seedASR
        settings.language = "zh-CN"
        settings.openAIModel = "whisper-1"
        settings.seedAppID = " 42 "
        settings.save(to: defaults)
        var expected = settings
        expected.seedAppID = "42"
        XCTAssertEqual(DictationSettings.load(from: defaults), expected)
        defaults.set("not-a-provider", forKey: "dictationProvider")
        defaults.set("", forKey: "dictationWhisperModel")
        let fallback = DictationSettings.load(from: defaults)
        XCTAssertEqual(fallback.provider, .apple)
        XCTAssertEqual(fallback.whisperModel, WhisperModelCatalog.defaultModel)
    }

    func testOnlyCloudServicesNeedAKey() {
        XCTAssertEqual(DictationProvider.allCases.filter(\.needsAPIKey), [.openAI, .seedASR])
        XCTAssertTrue(SettingsTab.remoteTabs.contains(.dictation))
        XCTAssertEqual(ButtonAction.vibeDictation.settingsTitle, "Dictation")
    }

    func testSilenceAndShortHoldsAreDetected() {
        XCTAssertEqual(DictationAudio(samples: Array(repeating: 0, count: 16_000)).rms, 0)
        XCTAssertEqual(DictationAudio(samples: Array(repeating: 0, count: 8_000)).duration, 0.5, accuracy: 0.0001)
        XCTAssertGreaterThan(DictationAudio(samples: [0.5, -0.5]).rms, 0.4)
    }

    /// The meter's job is to tell silence from speech at a glance: digital silence and room
    /// noise read empty, close speech reads full, and it rises monotonically in between.
    func testLevelMeterSeparatesSilenceFromSpeech() {
        XCTAssertEqual(DictationLevelMeter.normalized(rms: 0), 0)
        XCTAssertEqual(DictationLevelMeter.normalized(rms: 0.001), 0)          // -60 dBFS
        XCTAssertEqual(DictationLevelMeter.normalized(rms: 0.5), 1, accuracy: 0.01) // -6 dBFS
        XCTAssertEqual(DictationLevelMeter.normalized(rms: 1), 1)
        // Ordinary speech (around -18 dBFS) must sit well below full, or the mic stops moving.
        XCTAssertEqual(DictationLevelMeter.normalized(rms: 0.126), 0.69, accuracy: 0.02)
        let quiet = DictationLevelMeter.normalized(rms: 0.01), loud = DictationLevelMeter.normalized(rms: 0.05)
        XCTAssertGreaterThan(quiet, 0)
        XCTAssertGreaterThan(loud, quiet)
        XCTAssertEqual(DictationLevelMeter.rms([0.5, -0.5, 0.5, -0.5]), 0.5, accuracy: 0.0001)
    }

    func testLevelMeterAttacksFasterThanItReleases() {
        let rise = DictationLevelMeter.eased(0, toward: 1, elapsed: 0.05)
        let fall = 1 - DictationLevelMeter.eased(1, toward: 0, elapsed: 0.05)
        XCTAssertGreaterThan(rise, 0.7)
        XCTAssertLessThan(fall, 0.3)
        XCTAssertEqual(DictationLevelMeter.eased(0.4, toward: 0.4, elapsed: 1), 0.4)
    }

    func testPeakIsTheLoudestWindowNotTheAverage() {
        let samples = [Float](repeating: 0, count: 8_000) + [Float](repeating: 0.1, count: 800)
        XCTAssertEqual(DictationLevelMeter.peakDecibels(samples), -20, accuracy: 0.1)
        XCTAssertLessThan(DictationLevelMeter.peakDecibels([]), -100)
    }

    /// Any sound fills the mic's stand at once; the capsule carries the volume.
    @MainActor
    func testMicFillsFromTheStandUp() {
        // The quietest 50 ms window is the clip's noise floor.
        let clip = [Float](repeating: 0.001, count: 1600) + [Float](repeating: 0.5, count: 1600)
        XCTAssertEqual(DictationLevelMeter.floorDecibels(clip), -60, accuracy: 0.1)
        XCTAssertEqual(DictationLevelMeter.peakDecibels(clip), DictationLevelMeter.decibels(rms: 0.5), accuracy: 0.1)
        XCTAssertEqual(CaretGlyphImages.fillFraction(level: 0), 0)
        XCTAssertEqual(CaretGlyphImages.fillFraction(level: 0.1), 0.1, accuracy: 0.001, "no jump: the fill rises from empty")
        XCTAssertEqual(CaretGlyphImages.fillFraction(level: 1), 1)
        XCTAssertEqual(CaretGlyphImages.fillFraction(level: 3), 1)
    }
}
