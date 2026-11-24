import Foundation

protocol KeyboardSpeechStream: AnyObject {
    func start(_ request: URLRequest, appID: String, context: String?, removeFillers: Bool, sentenceSilence: Int?)
    func appendPCM16(_ pcm: Data)
    func finish()
    func cancel()
}
extension SeedStreamingSession: KeyboardSpeechStream {}

/// A complete hold lives in the extension. No host process, file polling or idle mic.
/// The controller still owns document validation and committing marked text.
@MainActor final class KeyboardVoiceSession {
    struct Configuration {
        var seedKey: String
        var appID = ""
        var arkKey: String?
        var polish = DictationPolishSettings()
        var output = DictationOutputSettings()
        static func load() -> Self? {
            guard let key = SeedKeychain.read(), !key.isEmpty else { return nil }
            return Self(seedKey: key, appID: "",
                        arkKey: ArkPolishKeychain.read(), polish: .load(), output: .load())
        }
    }
    typealias StreamFactory = (@escaping @Sendable (SeedStreamingSession.Event) -> Void) -> KeyboardSpeechStream
    private let capture: KeyboardAudioCapture
    private let configuration: () -> Configuration?
    private let makeStream: StreamFactory
    private let polishLoad: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let polisher = DictationPolishSession()
    private var settings: Configuration?
    private(set) var activeID: UUID?
    private var handledID: UUID?
    private var finishing = false
    private var polishing = false
    private var translate = false
    private var receivedAudio = false
    private var startedAt = Date.distantPast
    private var finalDeadline = Date.distantFuture
    private var stream: KeyboardSpeechStream?
    private var refinement: KeyboardSpeechStream?
    private var latest = "", latestRefined = ""
    private var liveFinal: String?, refinedFinal: String?
    private var pendingReply: VoiceReply?
    private(set) var level: VoiceLevel?

    init(capture: KeyboardAudioCapture, configuration: @escaping () -> Configuration? = { .load() },
         makeStream: @escaping StreamFactory = { SeedStreamingSession(onEvent: $0) },
         polishLoad: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await DictationPolisher.session.data(for: $0) }) {
        self.capture = capture; self.configuration = configuration; self.makeStream = makeStream; self.polishLoad = polishLoad
        capture.onAudio = { [weak self] id, data, rms in self?.audio(id: id, data: data, rms: rms) }
        capture.onFailure = { [weak self] id, message in self?.fail(id: id, message: message) }
    }
    func command(_ command: VoiceCommand, at now: Date = Date()) {
        switch command.phase {
        case .recording:
            if handledID == command.id { return }
            cancel(); handledID = command.id
            guard let settings = configuration() else {
                pendingReply = VoiceReply(id: command.id, text: "", isFinal: true, error: "Speech recognition is unavailable in this build."); return
            }
            self.settings = settings; activeID = command.id; startedAt = now
            capture.start(id: command.id)
        case .finish:
            guard activeID == command.id, !finishing else { return }
            capture.stop(); level = nil; finishing = true; translate = command.translate == true
            finalDeadline = now.addingTimeInterval(5)
            guard receivedAudio else { finishReply(text: ""); return }
            stream?.finish(); refinement?.finish()
            if let refinedFinal { complete(refinedFinal) }
            else if refinement == nil, let liveFinal { complete(liveFinal) }
        case .cancel:
            if activeID == command.id || pendingReply?.id == command.id { cancel() }
        }
    }
    func tick(at now: Date = Date()) {
        guard let id = activeID else { return }
        if !finishing, now.timeIntervalSince(startedAt) > 120 { fail(id: id, message: "Dictation reached its two-minute limit.") }
        else if finishing, !polishing, now >= finalDeadline { complete(refinedFinal ?? liveFinal ?? latest.nonempty ?? latestRefined) }
    }
    // The remote editor may acknowledge a write on a later run-loop turn.
    // Keep the final reply available until DictationTextSession finishes its commit.
    var reply: VoiceReply? { pendingReply }
    func acknowledge(_ reply: VoiceReply) {
        if pendingReply?.id == reply.id, pendingReply?.updatedAt == reply.updatedAt { pendingReply = nil }
    }
    private func audio(id: UUID, data: Data, rms: Double) {
        guard activeID == id, !finishing, !data.isEmpty, data.count <= 16384, data.count.isMultiple(of: 2), rms.isFinite else { return }
        if !receivedAudio {
            guard let settings else { return }
            receivedAudio = true
            let live = makeStream { [weak self] event in Task { @MainActor in self?.event(event, id: id, accurate: false) } }
            let accurate = makeStream { [weak self] event in Task { @MainActor in self?.event(event, id: id, accurate: true) } }
            stream = live; refinement = accurate
            live.start(SeedStreamingSession.request(accessKey: settings.seedKey, appID: settings.appID, resourceID: ""), appID: settings.appID, context: nil, removeFillers: true, sentenceSilence: nil)
            accurate.start(SeedStreamingSession.request(accessKey: settings.seedKey, appID: settings.appID, resourceID: "", endpoint: SeedStreamFrame.nostreamEndpoint), appID: settings.appID, context: nil, removeFillers: true, sentenceSilence: nil)
            // Request headers now own the in-flight credential; no key enters WebKit.
            self.settings?.seedKey = ""
        }
        stream?.appendPCM16(data); refinement?.appendPCM16(data)
        let now = Date()
        if level == nil || now.timeIntervalSince(level!.updatedAt) >= 0.05 {
            level = VoiceLevel(id: id, value: VoiceLevel.normalizedRMS(rms), updatedAt: now)
        }
    }
    private func event(_ event: SeedStreamingSession.Event, id: UUID, accurate: Bool) {
        guard activeID == id, !polishing else { return }
        switch event {
        case .partial(let result):
            if accurate { latestRefined = result.text }
            else { latest = result.text; pendingReply = VoiceReply(id: id, text: result.text, isFinal: false) }
        case .final(let result):
            if accurate { refinedFinal = result?.text ?? latestRefined }
            else { liveFinal = result?.text ?? latest }
            if finishing, let refinedFinal { complete(refinedFinal) }
            else if finishing, refinement == nil, let liveFinal { complete(liveFinal) }
        case .failed:
            if accurate { refinement?.cancel(); refinement = nil }
            else { stream?.cancel(); stream = nil }
            // Do not display provider response bodies, identifiers or transport diagnostics.
            if stream == nil && refinement == nil { fail(id: id, message: "Recognition unavailable. Check your connection or try again later.") }
            else if finishing, refinement == nil, let liveFinal { complete(liveFinal) }
        }
    }
    private func complete(_ text: String) {
        guard let id = activeID, finishing, !polishing, let settings else { return }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { finishReply(text: ""); return }
        polishing = true
        stream?.cancel(); refinement?.cancel(); stream = nil; refinement = nil
        pendingReply = VoiceReply(id: id, text: clean, isFinal: false, polishing: true)
        polisher.start(text: clean, settings: settings.polish, key: settings.arkKey, translate: translate, load: polishLoad) { [weak self] result in
            guard let self, self.activeID == id, self.finishing, self.polishing else { return }
            self.finishReply(text: settings.output.finalize(result.text), notice: result.notice)
        }
    }
    private func finishReply(text: String, notice: String? = nil) {
        guard let id = activeID else { return }
        cancel(); pendingReply = VoiceReply(id: id, text: text, isFinal: true, notice: notice)
    }
    private func fail(id: UUID, message: String) {
        guard activeID == id else { return }
        cancel(); pendingReply = VoiceReply(id: id, text: "", isFinal: true, error: message)
    }
    func cancel() {
        // Invalidate before stopping; synchronous stop callbacks cannot resurrect this hold.
        activeID = nil; capture.stop(); stream?.cancel(); refinement?.cancel(); polisher.cancel()
        stream = nil; refinement = nil; settings = nil; pendingReply = nil; level = nil
        finishing = false; polishing = false; translate = false; receivedAudio = false
        latest = ""; latestRefined = ""; liveFinal = nil; refinedFinal = nil
    }
    isolated deinit { capture.stop(); stream?.cancel(); refinement?.cancel(); polisher.cancel() }
}
private extension String { var nonempty: String? { isEmpty ? nil : self } }
