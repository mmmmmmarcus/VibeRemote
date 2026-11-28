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
    /// "Text first, better later" (2026-11-25): short fixed budgets after release.
    enum Budget {
        /// Release → wait for the accurate nostream final, then use the live final or latest partial.
        static let refinement: TimeInterval = 1.5
        /// Release → longest wait when neither stream has produced any usable text.
        static let recognition: TimeInterval = 5
        /// One retry of the buffered utterance on a fresh nostream session.
        static let retry: TimeInterval = 6
        /// Ordinary polishing; past this the unpolished text commits and the late result is dropped.
        static let polish: TimeInterval = 3
        /// Explicit translation holds get longer: untranslated text defeats the gesture.
        static let translation: TimeInterval = 8
        /// 120 s (the hold limit) of 16 kHz mono PCM16, kept in memory for the retry only.
        static let audioBytes = 3_840_000
    }
    typealias StreamFactory = (@escaping @Sendable (SeedStreamingSession.Event) -> Void) -> KeyboardSpeechStream
    private enum Source { case live, refined, retry }
    private let capture: KeyboardAudioCapture
    private let configuration: () -> Configuration?
    private let makeStream: StreamFactory
    private let polishLoad: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let recents: DictationRecentStore
    private let timings: DictationTimingStore
    private let clock: () -> Date
    private let polisher = DictationPolishSession()
    private var settings: Configuration?
    private(set) var activeID: UUID?
    private var handledID: UUID?
    private var finishing = false
    private var polishing = false
    private var translate = false
    private var receivedAudio = false
    private var retried = false
    private var startedAt = Date.distantPast
    private var releasedAt: Date?
    private var refinementDeadline = Date.distantFuture
    private var recognitionDeadline = Date.distantFuture
    private var polishDeadline = Date.distantFuture
    private var polishStartedAt: Date?
    private var polishSource = ""
    private var stream: KeyboardSpeechStream?
    private var refinement: KeyboardSpeechStream?
    private var retry: KeyboardSpeechStream?
    private var latest = "", latestRefined = "", latestRetry = ""
    private var liveFinal: String?, refinedFinal: String?
    private var failure: DictationFailureKind?
    /// This utterance's PCM, only for a retry after both streams failed. Never persisted.
    private var audioBuffer = Data()
    private var audioOverflow = false
    private var timing: DictationTiming?
    /// A delivered final's metrics wait for the keyboard's commit acknowledgement.
    private var deliveredTiming: (id: UUID, record: DictationTiming, releasedAt: Date?)?
    /// Coalesced delivery on the next main turn avoids reentrancy into command/commit.
    var onReplyAvailable: (() -> Void)?
    private var notificationPending = false
    private var pendingReply: VoiceReply? {
        didSet {
            guard pendingReply != nil, !notificationPending else { return }
            notificationPending = true
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.notificationPending = false
                if self.pendingReply != nil { self.onReplyAvailable?() }
            }
        }
    }
    private var speculativeSource: String?
    private var speculativeResult: DictationPolisher.Result?
    private var speculativeStartedAt: Date?
    private var speculativeCompletedAt: Date?
    private var speculativeAttempted = false
    private(set) var level: VoiceLevel?

    init(capture: KeyboardAudioCapture, configuration: @escaping () -> Configuration? = { .load() },
         makeStream: @escaping StreamFactory = { SeedStreamingSession(onEvent: $0) },
         polishLoad: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await DictationPolisher.session.data(for: $0) },
         recents: DictationRecentStore = .init(fileURL: nil), timings: DictationTimingStore = .init(fileURL: nil),
         clock: @escaping () -> Date = { Date() }) {
        self.capture = capture; self.configuration = configuration; self.makeStream = makeStream; self.polishLoad = polishLoad
        self.recents = recents; self.timings = timings; self.clock = clock
        capture.onAudio = { [weak self] id, data, rms in self?.audio(id: id, data: data, rms: rms) }
        capture.onFailure = { [weak self] id, message in self?.fail(id: id, message: message) }
    }
    func command(_ command: VoiceCommand, at time: Date? = nil) {
        let now = time ?? clock()
        switch command.phase {
        case .recording:
            if handledID == command.id { return }
            cancel(); handledID = command.id
            guard let settings = configuration() else {
                pendingReply = VoiceReply(id: command.id, text: "", isFinal: true, error: "Speech recognition is unavailable in this build."); return
            }
            self.settings = settings; activeID = command.id; startedAt = now
            timing = DictationTiming(date: now)
            timing?.packetMilliseconds = SeedStreamFrame.audioPacketBytes / 32
            // Connect while WebKit starts the microphone; audio queues until the socket is up.
            openStreams(id: command.id, settings: settings)
            // Request headers now own the in-flight credential; no key enters WebKit.
            self.settings?.seedKey = ""
            capture.start(id: command.id)
        case .finish:
            guard activeID == command.id, !finishing else { return }
            capture.stop(); level = nil; finishing = true; translate = command.translate == true
            releasedAt = now
            timing?.captureStopped = Self.seconds(clock(), since: now)
            refinementDeadline = now.addingTimeInterval(Budget.refinement)
            recognitionDeadline = now.addingTimeInterval(Budget.recognition)
            timing?.hold = Self.seconds(now, since: startedAt)
            guard receivedAudio else { finishReply(text: "", empty: true); return }
            stream?.finish(); refinement?.finish()
            speculate(at: now)
            resolve(at: now)
        case .cancel:
            if activeID == command.id || pendingReply?.id == command.id { cancel() }
        }
    }
    func tick(at time: Date? = nil) {
        let now = time ?? clock()
        guard let id = activeID else { return }
        if !finishing {
            if now.timeIntervalSince(startedAt) > 120 { fail(id: id, message: "Dictation reached its two-minute limit.") }
        } else if polishing {
            guard now >= polishDeadline else { return }
            // Commit the unpolished text now; the cancelled request can never replace it.
            polisher.cancel()
            timing?.polish = .timedOut; timing?.polishDuration = polishStartedAt.map { Self.seconds(now, since: $0) }
            finishReply(text: settings?.output.finalize(polishSource) ?? polishSource,
                        notice: translate ? "Translation took too long. Kept the transcript." : nil)
        } else { resolve(at: now) }
    }
    // The remote editor may acknowledge a write on a later run-loop turn.
    // Keep the final reply available until DictationTextSession finishes its commit.
    var reply: VoiceReply? { pendingReply }
    func acknowledge(_ reply: VoiceReply) {
        guard pendingReply?.id == reply.id, pendingReply?.updatedAt == reply.updatedAt else { return }
        pendingReply = nil
        if reply.isFinal, var delivered = deliveredTiming, delivered.id == reply.id {
            if let releasedAt = delivered.releasedAt { delivered.record.committed = Self.seconds(clock(), since: releasedAt) }
            deliveredTiming = nil; timings.append(delivered.record)
        }
    }
    private func openStreams(id: UUID, settings: Configuration) {
        let live = makeStream { [weak self] event in Task { @MainActor in self?.event(event, id: id, source: .live) } }
        let accurate = makeStream { [weak self] event in Task { @MainActor in self?.event(event, id: id, source: .refined) } }
        stream = live; refinement = accurate
        live.start(SeedStreamingSession.request(accessKey: settings.seedKey, appID: settings.appID, resourceID: ""), appID: settings.appID, context: nil, removeFillers: true, sentenceSilence: nil)
        accurate.start(SeedStreamingSession.request(accessKey: settings.seedKey, appID: settings.appID, resourceID: "", endpoint: SeedStreamFrame.nostreamEndpoint), appID: settings.appID, context: nil, removeFillers: true, sentenceSilence: nil)
    }
    private func audio(id: UUID, data: Data, rms: Double) {
        guard activeID == id, !finishing, !data.isEmpty, data.count <= 16384, data.count.isMultiple(of: 2), rms.isFinite else { return }
        let now = clock()
        if !receivedAudio { receivedAudio = true; timing?.micLive = Self.seconds(now, since: startedAt) }
        if !audioOverflow {
            if audioBuffer.count + data.count <= Budget.audioBytes { audioBuffer.append(data) }
            else { audioOverflow = true; audioBuffer = Data() }
        }
        stream?.appendPCM16(data); refinement?.appendPCM16(data)
        if level == nil || now.timeIntervalSince(level!.updatedAt) >= 0.05 {
            level = VoiceLevel(id: id, value: VoiceLevel.normalizedRMS(rms), updatedAt: now)
        }
    }
    private func event(_ event: SeedStreamingSession.Event, id: UUID, source: Source) {
        guard activeID == id, !polishing else { return }
        let now = clock()
        switch event {
        case .partial(let result):
            switch source {
            case .live:
                if timing?.firstText == nil, !result.text.isEmpty { timing?.firstText = Self.seconds(now, since: startedAt) }
                latest = result.text; pendingReply = VoiceReply(id: id, text: result.text, isFinal: false)
            case .refined: latestRefined = result.text
            case .retry: latestRetry = result.text
            }
        case .final(let result):
            if timing?.firstText == nil, let result, !result.text.isEmpty { timing?.firstText = Self.seconds(now, since: startedAt) }
            let elapsed = releasedAt.map { Self.seconds(now, since: $0) }
            switch source {
            case .live: liveFinal = result?.text ?? latest; timing?.liveFinal = elapsed
            case .refined: refinedFinal = result?.text ?? latestRefined; timing?.refinedFinal = elapsed
            case .retry: retry = nil; complete(result?.text ?? latestRetry, path: .retry, at: now); return
            }
            if finishing { speculate(at: now); resolve(at: now) }
        case .failed(let kind):
            // Keep the most specific class; transport noise must not hide a key or quota error.
            if failure == nil || failure == .other { failure = kind }
            switch source {
            case .live: stream?.cancel(); stream = nil
            case .refined: refinement?.cancel(); refinement = nil
            case .retry: retry = nil; giveUp(kind); return
            }
            if finishing { speculate(at: now); resolve(at: now) }
            else if stream == nil, refinement == nil, let failure, !failure.retryable { fail(id: id, message: failure.recognitionMessage, kind: failure) }
            // Otherwise keep recording: the buffered utterance is retried after release.
        }
    }
    /// Chooses the recognized text after release. Called on stream events and ticks.
    private func resolve(at now: Date) {
        guard activeID != nil, finishing, !polishing else { return }
        if let retry {
            if now >= recognitionDeadline { retry.cancel(); self.retry = nil; giveUp(.timeout) }
            return
        }
        if let refinedFinal { complete(refinedFinal, path: .refined, at: now); return }
        if refinement == nil, let liveFinal { complete(liveFinal, path: .live, at: now); return }
        let streamsDead = stream == nil && refinement == nil
        if !streamsDead, now < refinementDeadline { return }
        if refinement != nil { timing?.refinedTimedOut = true }
        if let liveFinal { complete(liveFinal, path: .live, at: now); return }
        if stream != nil, let text = latest.nonempty { complete(text, path: .partial, at: now); return }
        // The live stream died or is silent: wait a little longer for anything usable,
        // then resend the full buffer rather than keep a truncated partial.
        if !streamsDead, now < recognitionDeadline { return }
        recover(at: now)
    }
    /// Both streams failed or stalled: resend the buffered utterance once to a fresh nostream session.
    private func recover(at now: Date) {
        let kind = failure ?? .timeout
        guard let id = activeID, !retried, kind.retryable, !audioOverflow, !audioBuffer.isEmpty, let settings,
              let key = configuration()?.seedKey, !key.isEmpty else { giveUp(kind); return }
        retried = true; timing?.retried = true; timing?.error = failure
        stream?.cancel(); refinement?.cancel(); stream = nil; refinement = nil
        let fresh = makeStream { [weak self] event in Task { @MainActor in self?.event(event, id: id, source: .retry) } }
        retry = fresh
        fresh.start(SeedStreamingSession.request(accessKey: key, appID: settings.appID, resourceID: "", endpoint: SeedStreamFrame.nostreamEndpoint),
                    appID: settings.appID, context: nil, removeFillers: true, sentenceSilence: nil)
        var offset = 0
        while offset < audioBuffer.count {
            let end = min(offset + SeedStreamFrame.audioPacketBytes, audioBuffer.count)
            fresh.appendPCM16(audioBuffer.subdata(in: offset..<end)); offset = end
        }
        fresh.finish()
        audioBuffer = Data()
        recognitionDeadline = now.addingTimeInterval(Budget.retry)
    }
    /// Keep the best text heard so far; only a hold with no text at all shows a classified error.
    private func giveUp(_ kind: DictationFailureKind) {
        guard let id = activeID else { return }
        if failure == nil || failure == .other { failure = kind }
        timing?.error = failure
        if let text = bestRecognized { complete(text, path: .partial, at: clock()) }
        else { fail(id: id, message: (failure ?? kind).recognitionMessage, kind: failure ?? kind) }
    }
    private var bestRecognized: String? {
        refinedFinal?.nonempty ?? liveFinal?.nonempty ?? latest.nonempty ?? latestRefined.nonempty ?? latestRetry.nonempty
    }
    private func complete(_ text: String, path: DictationTiming.Path, at now: Date) {
        guard activeID != nil, finishing, !polishing, let settings else { return }
        stream?.cancel(); refinement?.cancel(); retry?.cancel(); stream = nil; refinement = nil; retry = nil
        audioBuffer = Data()
        timing?.path = path
        if let releasedAt { timing?.recognition = Self.seconds(now, since: releasedAt) }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { finishReply(text: "", empty: true); return }
        polishing = true; polishSource = clean
        if !translate {
            let skip: DictationTiming.Polish? = !settings.polish.enabled ? .disabled
                : DictationShortText.skipsPolishing(clean) ? .skippedShort : nil
            if let skip { timing?.polish = skip; finishReply(text: settings.output.finalize(clean)); return }
        }
        guard let id = activeID else { return }
        pendingReply = VoiceReply(id: id, text: clean, isFinal: false, polishing: true)
        if speculativeSource == clean {
            polishStartedAt = speculativeStartedAt
            polishDeadline = (speculativeStartedAt ?? now).addingTimeInterval(translate ? Budget.translation : Budget.polish)
            timing?.speculation = "reused"
            if let result = speculativeResult { acceptPolish(result, completedAt: speculativeCompletedAt) }
            else { tick(at: now) }
        } else {
            if speculativeSource != nil { timing?.speculation = "discarded" }
            polisher.cancel(); speculativeSource = nil; speculativeResult = nil
            polishStartedAt = now
            polishDeadline = now.addingTimeInterval(translate ? Budget.translation : Budget.polish)
            startPolish(clean, id: id, settings: settings)
        }
    }
    /// At most one speculative request, only after release and on a live final.
    /// The result stays private until recognition selects exactly the same source.
    private func speculate(at now: Date) {
        guard finishing, !polishing, !speculativeAttempted, refinedFinal == nil,
              let id = activeID, let settings, let final = liveFinal else { return }
        let clean = final.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, translate || (settings.polish.enabled && !DictationShortText.skipsPolishing(clean)),
              let key = settings.arkKey, !key.isEmpty else { return }
        speculativeAttempted = true; speculativeSource = clean; speculativeStartedAt = now
        timing?.speculation = "started"
        startPolish(clean, id: id, settings: settings)
    }
    private func startPolish(_ text: String, id: UUID, settings: Configuration) {
        polisher.start(text: text, settings: settings.polish, key: settings.arkKey, translate: translate, load: polishLoad) { [weak self] result in
            guard let self, self.activeID == id, self.finishing else { return }
            if self.polishing { self.acceptPolish(result) }
            else { self.speculativeResult = result; self.speculativeCompletedAt = self.clock() }
        }
    }
    private func acceptPolish(_ result: DictationPolisher.Result, completedAt: Date? = nil) {
        guard polishing, let settings else { return }
        let now = clock()
        // A completion queued at the deadline must not beat the budget watchdog.
        let completed = completedAt ?? now
        guard completed < polishDeadline else { tick(at: now); return }
        if let polishStartedAt { timing?.polishDuration = Self.seconds(completed, since: polishStartedAt) }
        timing?.polish = result.failure != nil ? .failed : translate ? .translated : .polished
        if let failure = result.failure, timing?.error == nil { timing?.error = failure }
        finishReply(text: settings.output.finalize(result.text), notice: result.notice)
    }
    private func finishReply(text: String, notice: String? = nil, empty: Bool = false) {
        guard let id = activeID else { return }
        let now = clock()
        if !text.isEmpty { recents.record(text, at: now) }
        if var record = timing {
            if empty { record.path = .empty }
            if let releasedAt { record.textReady = Self.seconds(now, since: releasedAt) }
            deliveredTiming = (id, record, releasedAt)
            timing = nil
        }
        reset(); pendingReply = VoiceReply(id: id, text: text, isFinal: true, notice: notice)
    }
    private func fail(id: UUID, message: String, kind: DictationFailureKind? = nil) {
        guard activeID == id else { return }
        if var record = timing {
            record.path = .failed; record.error = kind ?? record.error
            timing = nil; timings.append(record)
        }
        reset(); pendingReply = VoiceReply(id: id, text: "", isFinal: true, error: message)
    }
    /// Cancellation after release (dismissal, field change, typing, IPC timeout) keeps
    /// the best in-flight text in recent results. A cancel while still recording discards.
    func cancel() {
        if activeID != nil, finishing, let settings, let text = (polishing ? polishSource.nonempty : nil) ?? bestRecognized {
            recents.record(settings.output.finalize(text), at: clock())
        }
        if activeID != nil, var record = timing { record.path = .cancelled; timings.append(record) }
        timing = nil
        if let delivered = deliveredTiming { deliveredTiming = nil; timings.append(delivered.record) }
        reset()
    }
    private func reset() {
        // Invalidate before stopping; synchronous stop callbacks cannot resurrect this hold.
        activeID = nil; capture.stop(); stream?.cancel(); refinement?.cancel(); retry?.cancel(); polisher.cancel()
        stream = nil; refinement = nil; retry = nil; settings = nil; pendingReply = nil; level = nil
        finishing = false; polishing = false; translate = false; receivedAudio = false; retried = false
        latest = ""; latestRefined = ""; latestRetry = ""; liveFinal = nil; refinedFinal = nil; failure = nil
        audioBuffer = Data(); audioOverflow = false; timing = nil
        releasedAt = nil; polishStartedAt = nil; polishSource = ""
        speculativeSource = nil; speculativeResult = nil; speculativeStartedAt = nil; speculativeCompletedAt = nil; speculativeAttempted = false
        refinementDeadline = .distantFuture; recognitionDeadline = .distantFuture; polishDeadline = .distantFuture
    }
    private static func seconds(_ now: Date, since start: Date) -> Double {
        (max(0, now.timeIntervalSince(start)) * 1000).rounded() / 1000
    }
    isolated deinit { capture.stop(); stream?.cancel(); refinement?.cancel(); retry?.cancel(); polisher.cancel() }
}
private extension String { var nonempty: String? { isEmpty ? nil : self } }
