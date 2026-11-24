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
    var chunks = 0, finished = false, cancelled = false
    init(_ event: @escaping @Sendable (SeedStreamingSession.Event) -> Void) { self.event = event }
    func start(_ request: URLRequest, appID: String, context: String?, removeFillers: Bool, sentenceSilence: Int?) {}
    func appendPCM16(_ pcm: Data) { chunks += 1 }
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
        let capture = TestCapture(); var streamCount = 0
        let session = KeyboardVoiceSession(capture: capture, configuration: { .init(seedKey: "synthetic") }, makeStream: { event in streamCount += 1; return TestStream(event) })
        let id = UUID(); session.command(command(id, .recording)); session.command(command(id, .finish))
        XCTAssertTrue(capture.stopped); XCTAssertNil(session.activeID)
        let reply = consume(session); XCTAssertEqual(reply?.text, ""); XCTAssertNil(reply?.error); XCTAssertEqual(reply?.isFinal, true)
        capture.audio(id); XCTAssertEqual(streamCount, 0); XCTAssertNil(session.level); XCTAssertNil(consume(session))
    }
    func testCancelledHoldCannotFeedNextHoldOrLeakOldLevels() {
        let capture = TestCapture(); var streams: [TestStream] = []
        let session = KeyboardVoiceSession(capture: capture, configuration: { .init(seedKey: "synthetic") }, makeStream: { event in let s = TestStream(event); streams.append(s); return s })
        let a = UUID(), b = UUID()
        session.command(command(a, .recording)); capture.audio(a); XCTAssertEqual(streams.count, 2)
        session.command(command(a, .cancel)); XCTAssertTrue(capture.stopped); XCTAssertNil(session.level)
        session.command(command(b, .recording)); capture.audio(a); XCTAssertEqual(streams.count, 2); XCTAssertNil(session.level)
        capture.audio(b); XCTAssertEqual(streams.count, 4); XCTAssertEqual(session.level?.id, b)
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
        streams[1].event(.final(.init(text: "Original", definiteUtterances: 1)))
        for _ in 0..<100 { if await deferred.waiting { break }; await Task.yield() }
        let waiting = await deferred.waiting; XCTAssertTrue(waiting)
        XCTAssertEqual(consume(session)?.polishing, true)
        session.command(command(id, .cancel)); try await deferred.resolve(); await settle()
        XCTAssertNil(consume(session)); XCTAssertNil(session.activeID); XCTAssertTrue(capture.stopped)
    }
    func testMissingKeyAndCaptureFailureNeverStartNetwork() {
        let capture = TestCapture()
        let missing = KeyboardVoiceSession(capture: capture, configuration: { nil })
        let a = UUID(); missing.command(command(a, .recording)); XCTAssertTrue(capture.starts.isEmpty); XCTAssertNotNil(consume(missing)?.error)
        let session = KeyboardVoiceSession(capture: capture, configuration: { .init(seedKey: "synthetic") }, makeStream: { event in XCTFail("No audio, no network"); return TestStream(event) })
        let b = UUID(); session.command(command(b, .recording)); capture.onFailure?(b, "Microphone interrupted")
        XCTAssertTrue(capture.stopped); XCTAssertNil(session.activeID); XCTAssertEqual(consume(session)?.error, "Microphone interrupted")
        session.command(command(b, .recording))
        XCTAssertEqual(capture.starts, [b]); XCTAssertNil(session.activeID)
    }
    func testBoundedHoldAndRefinementDeadline() async {
        let capture = TestCapture(); var streams: [TestStream] = []
        let session = KeyboardVoiceSession(capture: capture, configuration: { .init(seedKey: "synthetic", polish: .init(enabled: false)) }, makeStream: { event in let s = TestStream(event); streams.append(s); return s })
        let now = Date(), id = UUID(); session.command(command(id, .recording), at: now)
        session.tick(at: now.addingTimeInterval(121)); XCTAssertTrue(capture.stopped); XCTAssertNotNil(consume(session)?.error)
        let next = UUID(); session.command(command(next, .recording), at: now); capture.audio(next)
        streams[0].event(.partial(.init(text: "Hello", definiteUtterances: 0))); await settle(); _ = consume(session)
        session.command(command(next, .finish), at: now); session.tick(at: now.addingTimeInterval(6)); await settle()
        XCTAssertEqual(consume(session)?.text, "Hello."); XCTAssertTrue(capture.stopped)
    }
}
