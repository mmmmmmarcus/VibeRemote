import XCTest
@testable import vvhisper

@MainActor private final class TestCapture: KeyboardAudioCapture {
    var onAudio: ((UUID, Data, Double) -> Void)?
    var onFailure: ((UUID, String) -> Void)?
    var starts: [UUID] = []
    var stopped = true
    func start(id: UUID) { starts.append(id); stopped = false }
    func stop() { stopped = true }
    func audio(_ id: UUID) { onAudio?(id, Data([0, 16, 0, 240]), 0.125) }
}
private final class TestStream: KeyboardSpeechStream {
    let event: @Sendable (SeedStreamingSession.Event) -> Void
    var chunks = 0, bytes = 0, finished = false, cancelled = false
    var request: URLRequest?
    init(_ event: @escaping @Sendable (SeedStreamingSession.Event) -> Void) { self.event = event }
    func start(_ request: URLRequest, appID: String, context: String?, removeFillers: Bool, sentenceSilence: Int?) { self.request = request }
    func appendPCM16(_ pcm: Data) { chunks += 1; bytes += pcm.count }
    func finish() { finished = true }
    func cancel() { cancelled = true }
}
private actor DeferredPolish {
    var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    var waiting: Bool { continuation != nil }
    func resolve() throws {
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": "{\"text\":\"Polished\"}"]]]])
        continuation?.resume(returning: (data, HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)); continuation = nil
    }
}
@MainActor final class KeyboardVoiceSessionTests: XCTestCase {
    private func command(_ id: UUID, _ phase: VoiceCommand.Phase, translate: Bool? = nil) -> VoiceCommand {
        VoiceCommand(id: id, phase: phase, updatedAt: Date(), translate: translate)
    }
    private func consume(_ session: KeyboardVoiceSession) -> VoiceReply? {
        guard let reply = session.reply else { return nil }; session.acknowledge(reply); return reply
    }
    func testFinalReplyRemainsUntilRemoteEditorAcknowledgesIt() throws {
        let capture = TestCapture()
        let session = KeyboardVoiceSession(capture: capture, configuration: { .init(seedKey: "synthetic") })
        let id = UUID(); session.command(command(id, .recording)); session.command(command(id, .finish))
        let reply = try XCTUnwrap(session.reply)
        session.tick(); XCTAssertEqual(session.reply?.updatedAt, reply.updatedAt)
        XCTAssertEqual(session.reply?.isFinal, true)
        session.acknowledge(VoiceReply(id: UUID(), text: "", isFinal: true)); XCTAssertNotNil(session.reply)
        session.acknowledge(reply); XCTAssertNil(session.reply)
    }
    private func settle() async { for _ in 0..<20 { await Task.yield() } }
    func testReleaseDuringStartupIsSilentAndRejectsLateAudio() {
        let capture = TestCapture(); var streams: [TestStream] = []
        let session = KeyboardVoiceSession(capture: capture, configuration: { .init(seedKey: "synthetic") }, makeStream: { event in let s = TestStream(event); streams.append(s); return s })
        let id = UUID(); session.command(command(id, .recording))
        // Seed connects at hold start, while the microphone warms up.
        XCTAssertEqual(streams.count, 2)
        session.command(command(id, .finish))
        XCTAssertTrue(capture.stopped); XCTAssertNil(session.activeID)
        let reply = consume(session); XCTAssertEqual(reply?.text, ""); XCTAssertNil(reply?.error); XCTAssertEqual(reply?.isFinal, true)
        capture.audio(id); XCTAssertEqual(streams.count, 2); XCTAssertTrue(streams.allSatisfy { $0.cancelled && $0.chunks == 0 })
        XCTAssertNil(session.level); XCTAssertNil(consume(session))
    }
    func testCancelledHoldCannotFeedNextHoldOrLeakOldLevels() {
        let capture = TestCapture(); var streams: [TestStream] = []
        let session = KeyboardVoiceSession(capture: capture, configuration: { .init(seedKey: "synthetic") }, makeStream: { event in let s = TestStream(event); streams.append(s); return s })
        let a = UUID(), b = UUID()
        session.command(command(a, .recording)); capture.audio(a); XCTAssertEqual(streams.count, 2)
        session.command(command(a, .cancel)); XCTAssertTrue(capture.stopped); XCTAssertNil(session.level)
        session.command(command(b, .recording)); XCTAssertEqual(streams.count, 4)
        capture.audio(a); XCTAssertEqual(streams[2].chunks + streams[3].chunks, 0); XCTAssertEqual(streams[0].chunks, 1); XCTAssertNil(session.level)
        capture.audio(b); XCTAssertEqual(streams.count, 4); XCTAssertEqual(streams[2].chunks, 1); XCTAssertEqual(session.level?.id, b)
        session.command(command(a, .cancel)); XCTAssertEqual(session.activeID, b)
        session.cancel(); XCTAssertTrue(streams.allSatisfy(\.cancelled))
    }
    func testRefinementPolishingAndSentencePunctuationFinishWithoutHost() async throws {
        let capture = TestCapture(); var streams: [TestStream] = []
        let session = KeyboardVoiceSession(capture: capture, configuration: { .init(seedKey: "synthetic", polish: .init(enabled: false)) }, makeStream: { event in let s = TestStream(event); streams.append(s); return s })
        let id = UUID(); session.command(command(id, .recording)); capture.audio(id)
        streams[0].event(.partial(.init(text: "我知道", definiteUtterances: 0))); await settle()
        XCTAssertEqual(consume(session)?.text, "我知道")
        session.command(command(id, .finish)); XCTAssertTrue(capture.stopped); XCTAssertTrue(streams.allSatisfy(\.finished))
        streams[1].event(.final(.init(text: "我知道了", definiteUtterances: 1))); await settle()
        let reply = try XCTUnwrap(consume(session)); XCTAssertTrue(reply.isFinal); XCTAssertEqual(reply.text, "我知道了。")
        XCTAssertNil(session.activeID); XCTAssertNil(session.level)
    }
    func testTranslateFlagReachesArkEvenWhenOrdinaryPolishingIsDisabled() async throws {
        let capture = TestCapture(); var streams: [TestStream] = []
        let session = KeyboardVoiceSession(capture: capture,
            configuration: { .init(seedKey: "synthetic", arkKey: "synthetic", polish: .init(enabled: false)) },
            makeStream: { event in let s = TestStream(event); streams.append(s); return s },
            polishLoad: { request in
                let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
                let messages = body["messages"] as! [[String: String]]
                XCTAssertEqual(messages[0]["content"], DictationPolisher.translationInstruction)
                let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": "{\"text\":\"I understand\"}"]]]])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        let id = UUID(); session.command(command(id, .recording)); capture.audio(id)
        session.command(command(id, .finish, translate: true))
        streams[1].event(.final(.init(text: "我知道了", definiteUtterances: 1)))
        for _ in 0..<100 { if session.reply?.isFinal == true { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(session.reply?.text, "I understand."); XCTAssertNil(session.reply?.notice)
    }

    func testCancellationDuringPolishRejectsEvenUncooperativeLateResponse() async throws {
        let capture = TestCapture(), deferred = DeferredPolish(); var streams: [TestStream] = []
        let session = KeyboardVoiceSession(capture: capture, configuration: { .init(seedKey: "synthetic", arkKey: "synthetic") }, makeStream: { event in let s = TestStream(event); streams.append(s); return s }, polishLoad: { try await deferred.load($0) })
        let id = UUID(); session.command(command(id, .recording)); capture.audio(id); session.command(command(id, .finish))
        streams[1].event(.final(.init(text: "Original words from a longer test sentence", definiteUtterances: 1)))
        for _ in 0..<100 { if await deferred.waiting { break }; await Task.yield() }
        let waiting = await deferred.waiting; XCTAssertTrue(waiting)
        XCTAssertEqual(consume(session)?.polishing, true)
        session.command(command(id, .cancel)); try await deferred.resolve(); await settle()
        XCTAssertNil(consume(session)); XCTAssertNil(session.activeID); XCTAssertTrue(capture.stopped)
    }
    func testMissingKeyNeverStartsNetworkAndCaptureFailureClosesSockets() {
        let capture = TestCapture()
        let missing = KeyboardVoiceSession(capture: capture, configuration: { nil })
        let a = UUID(); missing.command(command(a, .recording)); XCTAssertTrue(capture.starts.isEmpty); XCTAssertNotNil(consume(missing)?.error)
        var streams: [TestStream] = []
        let session = KeyboardVoiceSession(capture: capture, configuration: { .init(seedKey: "synthetic") }, makeStream: { event in let s = TestStream(event); streams.append(s); return s })
        let b = UUID(); session.command(command(b, .recording)); capture.onFailure?(b, "Microphone interrupted")
        XCTAssertTrue(capture.stopped); XCTAssertNil(session.activeID); XCTAssertEqual(consume(session)?.error, "Microphone interrupted")
        // Pre-connected sockets close without ever receiving audio.
        XCTAssertTrue(streams.allSatisfy { $0.cancelled && $0.chunks == 0 })
        session.command(command(b, .recording))
        XCTAssertEqual(capture.starts, [b]); XCTAssertNil(session.activeID)
    }
    func testBoundedHoldAndRefinementDeadline() async {
        let capture = TestCapture(); var streams: [TestStream] = []
        let session = KeyboardVoiceSession(capture: capture, configuration: { .init(seedKey: "synthetic", polish: .init(enabled: false)) }, makeStream: { event in let s = TestStream(event); streams.append(s); return s })
        let now = Date(), id = UUID(); session.command(command(id, .recording), at: now)
        session.tick(at: now.addingTimeInterval(121)); XCTAssertTrue(capture.stopped); XCTAssertNotNil(consume(session)?.error)
        let next = UUID(); session.command(command(next, .recording), at: now); capture.audio(next)
        XCTAssertEqual(streams.count, 4); XCTAssertTrue(streams[0].cancelled)
        streams[2].event(.partial(.init(text: "Hello", definiteUtterances: 0))); await settle(); _ = consume(session)
        session.command(command(next, .finish), at: now)
        session.tick(at: now.addingTimeInterval(1.4)); await settle(); XCTAssertNil(session.reply)
        session.tick(at: now.addingTimeInterval(1.5)); await settle()
        XCTAssertEqual(consume(session)?.text, "Hello."); XCTAssertTrue(capture.stopped)
    }
}

@MainActor private final class TestClock { var now = Date(timeIntervalSince1970: 1_800_000_000) }
private func temporaryURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("vvhisper-\(UUID().uuidString).json") }
private func okPolish(_ text: String, request: URLRequest) throws -> (Data, URLResponse) {
    let content = String(decoding: try JSONSerialization.data(withJSONObject: ["text": text]), as: UTF8.self)
    let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
    return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

/// "Text first, better later": deadlines, polish budget, short-text skip, retry,
/// error classes, recent results and timing metrics.
@MainActor final class DictationFastStableTests: XCTestCase {
    private let longText = "please send the quarterly report to the whole team tomorrow"
    private var streams: [TestStream] = []
    private lazy var capture = TestCapture()
    private lazy var clock = TestClock()
    private func command(_ id: UUID, _ phase: VoiceCommand.Phase, translate: Bool? = nil) -> VoiceCommand {
        VoiceCommand(id: id, phase: phase, updatedAt: Date(), translate: translate)
    }
    private func settle() async { for _ in 0..<20 { await Task.yield() } }
    private func waitFor(_ condition: () async -> Bool) async {
        for _ in 0..<300 { if await condition() { return }; try? await Task.sleep(for: .milliseconds(5)) }
    }
    private func makeSession(polish: Bool = true, ark: String? = "synthetic", seedKey: String = "synthetic",
                             recents: DictationRecentStore = .init(fileURL: nil), timings: DictationTimingStore = .init(fileURL: nil),
                             load: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { _ in XCTFail("No polish request expected"); throw URLError(.badURL) }) -> KeyboardVoiceSession {
        KeyboardVoiceSession(capture: capture,
            configuration: { .init(seedKey: seedKey, arkKey: ark, polish: .init(enabled: polish)) },
            makeStream: { [unowned self] event in let s = TestStream(event); self.streams.append(s); return s },
            polishLoad: load, recents: recents, timings: timings, clock: { [clock] in clock.now })
    }
    /// Starts a hold at clock.now, feeds `chunks` of audio and releases `after` seconds later.
    private func hold(_ session: KeyboardVoiceSession, chunks: Int = 1, after: TimeInterval = 2, translate: Bool = false) -> UUID {
        let id = UUID(); session.command(command(id, .recording))
        clock.now += 0.25
        for _ in 0..<chunks { capture.audio(id) }
        clock.now += after - 0.25
        session.command(command(id, .finish, translate: translate ? true : nil))
        return id
    }
    private func finalText(_ session: KeyboardVoiceSession) -> VoiceReply? {
        guard let reply = session.reply, reply.isFinal else { return nil }
        session.acknowledge(reply); return reply
    }

    // MARK: Deadlines
    func testRefinedFinalWinsWithinDeadline() async {
        let session = makeSession(polish: false)
        _ = hold(session)
        streams[0].event(.final(.init(text: "Live words", definiteUtterances: 1))); await settle()
        XCTAssertNil(finalText(session), "Wait for refinement while it is still within 1.5 s")
        clock.now += 1.0
        streams[1].event(.final(.init(text: "Refined words", definiteUtterances: 1))); await settle()
        XCTAssertEqual(finalText(session)?.text, "Refined words.")
    }
    func testLiveFinalAfterRefinementDeadline() async {
        let session = makeSession(polish: false)
        _ = hold(session); let release = clock.now
        streams[0].event(.final(.init(text: "Live words", definiteUtterances: 1))); await settle()
        session.tick(at: release + 1.49); XCTAssertNil(finalText(session))
        session.tick(at: release + 1.5); XCTAssertEqual(finalText(session)?.text, "Live words.")
        XCTAssertTrue(streams[1].cancelled)
    }
    func testLatestPartialWhenNoFinalAtDeadline() async {
        let session = makeSession(polish: false)
        let id = UUID(); session.command(command(id, .recording)); capture.audio(id)
        streams[0].event(.partial(.init(text: "Partial words", definiteUtterances: 0))); await settle()
        session.command(command(id, .finish)); let release = clock.now
        session.tick(at: release + 1.5); XCTAssertEqual(finalText(session)?.text, "Partial words.")
    }
    func testSilentStreamsWaitLongerThenRetry() async {
        let session = makeSession(polish: false)
        _ = hold(session); let release = clock.now
        session.tick(at: release + 1.5); session.tick(at: release + 4.9)
        XCTAssertNil(finalText(session)); XCTAssertEqual(streams.count, 2)
        session.tick(at: release + 5); XCTAssertEqual(streams.count, 3, "Stalled streams get one fresh retry")
        XCTAssertEqual(streams[2].request?.url, SeedStreamFrame.nostreamEndpoint)
    }

    // MARK: Polish budget and short text
    func testPolishBudgetCommitsUnpolishedTextAndDropsLateResult() async throws {
        let deferred = DeferredPolish()
        let session = makeSession(load: { try await deferred.load($0) })
        _ = hold(session)
        streams[1].event(.final(.init(text: longText, definiteUtterances: 1))); await settle()
        await waitFor { await deferred.waiting }
        let polishStart = clock.now
        XCTAssertEqual(session.reply?.polishing, true)
        session.tick(at: polishStart + 2.9); XCTAssertNil(finalText(session))
        session.tick(at: polishStart + 3)
        let reply = try XCTUnwrap(finalText(session))
        XCTAssertEqual(reply.text, longText + "."); XCTAssertNil(reply.error); XCTAssertNil(reply.notice)
        try await deferred.resolve(); await settle()
        XCTAssertNil(session.reply, "A late polish result never swaps committed text")
    }
    func testShortUtterancesSkipPolishingButTranslationStillPolishes() async throws {
        let calls = Counter()
        let session = makeSession(load: { request in _ = calls.next(); return try okPolish("Okay", request: request) })
        _ = hold(session)
        streams[1].event(.final(.init(text: "好的没问题", definiteUtterances: 1))); await settle()
        XCTAssertEqual(finalText(session)?.text, "好的没问题。"); XCTAssertEqual(calls.count, 0)
        _ = hold(session, translate: true)
        streams[3].event(.final(.init(text: "好的", definiteUtterances: 1))); await settle()
        await waitFor { session.reply?.isFinal == true }
        XCTAssertEqual(finalText(session)?.text, "Okay."); XCTAssertEqual(calls.count, 1)
    }
    func testShortTextThreshold() {
        XCTAssertTrue(DictationShortText.skipsPolishing("好的，没问题。"))     // 5 Han
        XCTAssertTrue(DictationShortText.skipsPolishing("我明天下午到"))       // 6 Han
        XCTAssertFalse(DictationShortText.skipsPolishing("我明天下午三点"))    // 7 Han
        XCTAssertTrue(DictationShortText.skipsPolishing("I'll be there soon."))  // 4 words
        XCTAssertFalse(DictationShortText.skipsPolishing("I will be there soon."))  // 5 words
        XCTAssertTrue(DictationShortText.skipsPolishing("买 iPhone 17"))       // 1 Han + 2 words = 4
        XCTAssertFalse(DictationShortText.skipsPolishing("帮我订 iPhone 17 Pro"))  // 3 + 4.5
        XCTAssertEqual(DictationShortText.units("well-known e-mail"), 3)
    }

    // MARK: Retry and errors
    func testBothStreamsFailingRetriesBufferedAudioOnceAfterRelease() async throws {
        let timingURL = temporaryURL(); defer { try? FileManager.default.removeItem(at: timingURL) }
        let timings = DictationTimingStore(fileURL: timingURL)
        let session = makeSession(polish: false, timings: timings)
        let id = UUID(); session.command(command(id, .recording)); capture.audio(id)
        streams[0].event(.failed(.offline)); streams[1].event(.failed(.other)); await settle()
        XCTAssertNil(session.reply, "Recording continues; the utterance is retried after release")
        capture.audio(id); capture.audio(id)
        session.command(command(id, .finish))
        XCTAssertEqual(streams.count, 3)
        let retry = streams[2]
        XCTAssertEqual(retry.request?.url, SeedStreamFrame.nostreamEndpoint)
        XCTAssertEqual(retry.bytes, 12); XCTAssertTrue(retry.finished)
        retry.event(.final(.init(text: "Recovered words", definiteUtterances: 1))); await settle()
        let reply = try XCTUnwrap(finalText(session)); XCTAssertEqual(reply.text, "Recovered words."); XCTAssertNil(reply.error)
        let record = try XCTUnwrap(timings.load().last)
        XCTAssertEqual(record.path, .retry); XCTAssertTrue(record.retried); XCTAssertEqual(record.error, .offline)
    }
    func testFailedRetryKeepsBestPartialText() async {
        let session = makeSession(polish: false)
        let id = UUID(); session.command(command(id, .recording)); capture.audio(id)
        streams[0].event(.partial(.init(text: "Heard so far", definiteUtterances: 0))); await settle()
        streams[0].event(.failed(.offline)); streams[1].event(.failed(.offline)); await settle()
        session.command(command(id, .finish)); XCTAssertEqual(streams.count, 3)
        streams[2].event(.failed(.offline)); await settle()
        let reply = finalText(session); XCTAssertEqual(reply?.text, "Heard so far."); XCTAssertNil(reply?.error)
        XCTAssertEqual(streams.count, 3, "Only one retry")
    }
    func testNoTextAfterRetryShowsClassifiedError() async {
        let session = makeSession(polish: false)
        let id = UUID(); session.command(command(id, .recording)); capture.audio(id)
        streams[0].event(.failed(.offline)); streams[1].event(.failed(.offline)); await settle()
        session.command(command(id, .finish))
        streams[2].event(.failed(.offline)); await settle()
        XCTAssertEqual(finalText(session)?.error, DictationFailureKind.offline.recognitionMessage)
    }
    func testRetryTimeoutShowsTimeoutWhenNothingWasHeard() async {
        let session = makeSession(polish: false)
        let id = UUID(); session.command(command(id, .recording)); capture.audio(id)
        streams[0].event(.failed(.other)); streams[1].event(.failed(.other)); await settle()
        session.command(command(id, .finish)); let release = clock.now
        session.tick(at: release + 5.9); XCTAssertNil(finalText(session))
        session.tick(at: release + 6); XCTAssertTrue(streams[2].cancelled)
        XCTAssertEqual(finalText(session)?.error, DictationFailureKind.timeout.recognitionMessage)
    }
    func testKeyOrQuotaFailureNeverRetries() async {
        for kind in [DictationFailureKind.auth, .quota] {
            streams = []
            let session = makeSession(polish: false)
            let id = UUID(); session.command(command(id, .recording)); capture.audio(id)
            streams[0].event(.failed(kind)); streams[1].event(.failed(.other)); await settle()
            XCTAssertEqual(finalText(session)?.error, kind.recognitionMessage)
            XCTAssertTrue(capture.stopped); XCTAssertEqual(streams.count, 2)
        }
    }
    func testFailureClassification() {
        XCTAssertEqual(DictationFailureKind.classify(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(DictationFailureKind.classify(URLError(.networkConnectionLost)), .offline)
        XCTAssertEqual(DictationFailureKind.classify(URLError(.timedOut)), .timeout)
        XCTAssertEqual(DictationFailureKind.classify(URLError(.badServerResponse)), .other)
        XCTAssertEqual(DictationFailureKind.classify(CocoaError(.fileNoSuchFile)), .other)
        XCTAssertEqual(DictationFailureKind.classify(httpStatus: 401), .auth)
        XCTAssertEqual(DictationFailureKind.classify(httpStatus: 403), .auth)
        XCTAssertEqual(DictationFailureKind.classify(httpStatus: 429), .quota)
        XCTAssertNil(DictationFailureKind.classify(httpStatus: 500))
        XCTAssertEqual(DictationFailureKind.classify(seedCode: 45_000_081, message: ""), .timeout)
        XCTAssertEqual(DictationFailureKind.classify(seedCode: 55_000_031, message: ""), .quota)
        XCTAssertEqual(DictationFailureKind.classify(seedCode: 45_000_000, message: "Quota exceeded"), .quota)
        XCTAssertEqual(DictationFailureKind.classify(seedCode: 45_000_000, message: "invalid access key"), .auth)
        XCTAssertEqual(DictationFailureKind.classify(seedCode: 45_000_001, message: "bad params"), .other)
        XCTAssertFalse(DictationFailureKind.auth.retryable); XCTAssertFalse(DictationFailureKind.quota.retryable)
        XCTAssertTrue(DictationFailureKind.offline.retryable); XCTAssertTrue(DictationFailureKind.timeout.retryable)
        XCTAssertEqual(Set(DictationFailureKind.allCases.map(\.recognitionMessage)).count, DictationFailureKind.allCases.count)
    }
    func testPolishRetriesOnceOnConnectionFailureOnly() async {
        let calls = Counter()
        let recovered = await DictationPolisher.polish("original text", enabled: true, key: "synthetic") { request in
            if calls.next() == 1 { throw URLError(.networkConnectionLost) }
            return try okPolish("Original text", request: request)
        }
        XCTAssertEqual(recovered.text, "Original text"); XCTAssertNil(recovered.failure); XCTAssertEqual(calls.count, 2)
        let offline = Counter()
        let failed = await DictationPolisher.polish("original text", enabled: true, key: "synthetic") { _ in _ = offline.next(); throw URLError(.notConnectedToInternet) }
        XCTAssertEqual(failed.text, "original text"); XCTAssertEqual(failed.failure, .offline); XCTAssertEqual(offline.count, 2)
        let timeouts = Counter()
        let slow = await DictationPolisher.polish("original text", enabled: true, key: "synthetic") { _ in _ = timeouts.next(); throw URLError(.timedOut) }
        XCTAssertEqual(slow.failure, .timeout); XCTAssertEqual(timeouts.count, 1)
        let quota = await DictationPolisher.polish("original text", enabled: true, key: "synthetic") { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(quota.failure, .quota); XCTAssertEqual(quota.text, "original text")
    }

    // MARK: Recent results
    func testRecentResultsStoreKeepsTenNewestUniqueItems() {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let store = DictationRecentStore(fileURL: url)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<12 { store.record("Result \(index)", at: start + Double(index)) }
        XCTAssertEqual(store.items.map(\.text), (2..<12).reversed().map { "Result \($0)" })
        store.record("Result 5", at: start + 100)
        XCTAssertEqual(store.items.first, DictationRecent(text: "Result 5", date: start + 100)); XCTAssertEqual(store.items.count, 10)
        store.record("  "); store.record(String(repeating: "a", count: 20_001))
        XCTAssertEqual(DictationRecentStore(fileURL: url).items.count, 10, "Persisted; empty and oversize text rejected")
        store.clear(); XCTAssertTrue(DictationRecentStore(fileURL: url).items.isEmpty)
        DictationRecentStore(fileURL: nil).record("ignored"); XCTAssertTrue(DictationRecentStore(fileURL: nil).items.isEmpty)
    }
    func testFinalTextsAndInFlightResultsAreSavedButDiscardedHoldsAreNot() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let recents = DictationRecentStore(fileURL: url), deferred = DeferredPolish()
        let session = makeSession(recents: recents, load: { try await deferred.load($0) })
        _ = hold(session)
        streams[1].event(.final(.init(text: "短句", definiteUtterances: 1))); await settle()
        XCTAssertEqual(finalText(session)?.text, "短句。"); XCTAssertEqual(recents.items.map(\.text), ["短句。"])
        // Dismissed while polishing: the finalized unpolished text is kept.
        let polishing = hold(session)
        streams[3].event(.final(.init(text: longText, definiteUtterances: 1))); await settle()
        await waitFor { await deferred.waiting }
        session.command(command(polishing, .cancel))
        XCTAssertEqual(recents.items.first?.text, longText + ".")
        // Dismissed during refinement: the best text so far is kept.
        let refining = hold(session)
        streams[4].event(.final(.init(text: "Live only here", definiteUtterances: 1))); await settle()
        session.cancel()
        XCTAssertEqual(recents.items.first?.text, "Live only here.")
        // A hold cancelled while recording (slide to Delete) is discarded.
        let id = UUID(); session.command(command(id, .recording)); capture.audio(id)
        streams[6].event(.partial(.init(text: "Discard me", definiteUtterances: 0))); await settle()
        session.command(command(id, .cancel))
        XCTAssertEqual(recents.items.count, 3); XCTAssertNotEqual(refining, id)
        try await deferred.resolve()
    }

    // MARK: Metrics
    func testTimingRecordsDurationsPathAndNoText() async throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let timings = DictationTimingStore(fileURL: url)
        let session = makeSession(timings: timings, load: { request in try okPolish("Please send the quarterly report to the whole team tomorrow", request: request) })
        let id = UUID(); session.command(command(id, .recording))
        clock.now += 0.3; capture.audio(id)
        clock.now += 2; session.command(command(id, .finish))
        clock.now += 0.4; streams[0].event(.final(.init(text: longText, definiteUtterances: 1))); await settle()
        clock.now += 0.6; streams[1].event(.final(.init(text: longText, definiteUtterances: 1))); await settle()
        await waitFor { session.reply?.isFinal == true }
        clock.now += 0.05
        let reply = try XCTUnwrap(finalText(session))
        XCTAssertEqual(reply.text, "Please send the quarterly report to the whole team tomorrow.")
        let record = try XCTUnwrap(timings.load().last)
        XCTAssertEqual(record.micLive, 0.3); XCTAssertEqual(record.hold, 2.3)
        XCTAssertEqual(record.liveFinal, 0.4); XCTAssertEqual(record.refinedFinal, 1.0); XCTAssertFalse(record.refinedTimedOut)
        XCTAssertEqual(record.recognition, 1.0); XCTAssertEqual(record.polish, .polished); XCTAssertEqual(record.polishDuration, 0)
        XCTAssertEqual(record.textReady, 1.0); XCTAssertEqual(record.committed, 1.05)
        XCTAssertEqual(record.path, .refined); XCTAssertNil(record.error)
        XCTAssertEqual(record.speculation, "reused")
        let json = timings.exportJSON()
        XCTAssertFalse(json.localizedCaseInsensitiveContains("quarterly")); XCTAssertFalse(json.contains("synthetic"))
        // A skipped short utterance and a timed-out refinement are labelled.
        _ = hold(session); let release = clock.now
        streams[2].event(.final(.init(text: "好的", definiteUtterances: 1))); await settle()
        session.tick(at: release + 1.5); _ = finalText(session)
        let short = try XCTUnwrap(timings.load().last)
        XCTAssertEqual(short.polish, .skippedShort); XCTAssertTrue(short.refinedTimedOut); XCTAssertEqual(short.path, .live)
    }
    func testTimingStoreCapsAndSummarizes() throws {
        let url = temporaryURL(); defer { try? FileManager.default.removeItem(at: url) }
        let store = DictationTimingStore(fileURL: url)
        for index in 0..<205 {
            var record = DictationTiming(date: Date(timeIntervalSince1970: Double(index)))
            record.path = .live; record.micLive = 0.2; record.recognition = 0.5
            record.polishDuration = index.isMultiple(of: 3) ? 0.1 : 2; record.textReady = Double(index % 10) / 10
            store.append(record)
        }
        let records = store.load()
        XCTAssertEqual(records.count, 200); XCTAssertEqual(records.first?.date, Date(timeIntervalSince1970: 5))
        let summary = DictationTimingSummary(records)
        XCTAssertEqual(summary.count, 200); XCTAssertEqual(summary.median, 0.4); XCTAssertEqual(summary.p90, 0.8)
        XCTAssertEqual(summary.slowestStep, .polishing)
        XCTAssertTrue(summary.text.contains("200 dictations")); XCTAssertTrue(summary.text.contains("Polishing"))
        XCTAssertEqual(DictationTimingSummary([]).text, "No dictations recorded yet.")
        var failed = DictationTiming(date: Date()); failed.path = .failed; failed.error = .quota
        XCTAssertNil(DictationTimingSummary([failed]).median)
        XCTAssertEqual(DictationTimingSummary.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.9), 9)
    }
}

private actor SpeculationLoader {
    var pending: [CheckedContinuation<(Data, URLResponse), Error>] = []
    func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
    var count: Int { pending.count }
    func resolve(_ index: Int, text: String) throws {
        let content = String(decoding: try JSONSerialization.data(withJSONObject: ["text": text]), as: UTF8.self)
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": content]]]])
        pending[index].resume(returning: (data, HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
    }
}
@MainActor final class DictationSpeculationTests: XCTestCase {
    private func settle() async { for _ in 0..<60 { await Task.yield() } }
    func testExactFinalReusesPolishingAndDeliversWithoutPolling() async throws {
        let capture = TestCapture(); var streams: [TestStream] = []; let loader = SpeculationLoader()
        let session = KeyboardVoiceSession(capture: capture, configuration: { .init(seedKey: "synthetic", arkKey: "synthetic") },
            makeStream: { event in let stream = TestStream(event); streams.append(stream); return stream },
            polishLoad: { try await loader.load($0) })
        let id = UUID(); var deliveries = 0
        session.onReplyAvailable = { deliveries += 1 }
        session.command(.init(id: id, phase: .recording, updatedAt: Date())); capture.audio(id)
        session.command(.init(id: id, phase: .finish, updatedAt: Date()))
        let source = "please send the updated document tomorrow"
        streams[0].event(.final(.init(text: source, definiteUtterances: 1))); await settle()
        let requests = await loader.count; XCTAssertEqual(requests, 1)
        try await loader.resolve(0, text: "Please send the updated document tomorrow."); await settle()
        XCTAssertNotEqual(session.reply?.isFinal, true)
        streams[1].event(.final(.init(text: source, definiteUtterances: 1))); await settle()
        XCTAssertEqual(session.reply?.text, "Please send the updated document tomorrow.")
        XCTAssertEqual(session.reply?.isFinal, true); XCTAssertGreaterThan(deliveries, 0)
        let after = await loader.count; XCTAssertEqual(after, 1)
    }
    func testChangedRefinementDiscardsSpeculativeResult() async throws {
        let capture = TestCapture(); var streams: [TestStream] = []; let loader = SpeculationLoader()
        let session = KeyboardVoiceSession(capture: capture, configuration: { .init(seedKey: "synthetic", arkKey: "synthetic") },
            makeStream: { event in let stream = TestStream(event); streams.append(stream); return stream },
            polishLoad: { try await loader.load($0) })
        let id = UUID(); session.command(.init(id: id, phase: .recording, updatedAt: Date())); capture.audio(id)
        session.command(.init(id: id, phase: .finish, updatedAt: Date()))
        streams[0].event(.final(.init(text: "please send the updated document tomorrow", definiteUtterances: 1))); await settle()
        streams[1].event(.final(.init(text: "please send the updated document Monday", definiteUtterances: 1))); await settle()
        let requests = await loader.count; XCTAssertEqual(requests, 2)
        try await loader.resolve(0, text: "Wrong old transcript."); await settle()
        XCTAssertNotEqual(session.reply?.isFinal, true)
        try await loader.resolve(1, text: "Please send the updated document Monday."); await settle()
        XCTAssertEqual(session.reply?.text, "Please send the updated document Monday.")
        XCTAssertEqual(session.reply?.isFinal, true)
    }
}
