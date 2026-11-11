import AppKit
import AVFoundation
import Foundation

// Streaming dictation ("flow output"), modeled on Doubao IME: recognition runs while Siri is
// still held, partial text is typed into the editor as it arrives, and later revisions replace
// only the tail that changed. Doubao shows partials as IMK marked text; VibeRemote is not an
// input method, so it types real keystrokes and guards every correction instead.

// MARK: - Wire format

/// Volcengine's SAUC binary frames (大模型流式语音识别 API): a 4-byte header, an optional
/// sequence, a big-endian payload size, the payload. Nothing is compressed — the server answers
/// in the client's compression, and raw 16-bit PCM barely shrinks anyway.
enum SeedStreamFrame {
    static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!
    static let defaultResourceID = "volc.bigasr.sauc.duration"
    /// 200 ms of 16 kHz mono s16le, the packet size the documentation says performs best.
    static let audioPacketBytes = 6_400

    static func fullClientRequest(json: Data) -> Data { frame(kind: 0b0001, flags: 0, serialization: 1, payload: json) }
    static func audio(_ pcm: Data, last: Bool) -> Data { frame(kind: 0b0010, flags: last ? 0b0010 : 0, serialization: 0, payload: pcm) }

    private static func frame(kind: UInt8, flags: UInt8, serialization: UInt8, payload: Data) -> Data {
        var data = Data([0x11, kind << 4 | flags, serialization << 4, 0])
        let size = UInt32(payload.count)
        data.append(contentsOf: [UInt8(size >> 24 & 0xff), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)])
        data.append(payload)
        return data
    }

    /// The first request: audio format and streaming recognition only. Doubao's two-pass mode
    /// (`enable_nonstream`) re-recognizes every pause-ended sentence with the accurate model while
    /// the user is still speaking, so a long hold was rewritten several times before release; the
    /// user asked (2026-11-10) for one refinement after release instead, which
    /// `DictationController.finishStreaming` gets from the flash API with the recorded clip.
    static func requestJSON(appID: String) -> Data {
        let body: [String: Any] = [
            "user": ["uid": appID.isEmpty ? "viberemote" : appID],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16_000, "bits": 16, "channel": 1],
            "request": ["model_name": "bigmodel", "enable_itn": true, "enable_punc": true,
                        "enable_nonstream": false, "show_utterances": true, "result_type": "full"],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = UInt16(bitPattern: Int16(max(-1, min(1, sample)) * 32_767))
            data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8))
        }
        return data
    }

    enum Message: Equatable {
        case response(isLast: Bool, payload: Data)
        case error(code: UInt32, message: String)
    }

    static func parse(_ data: Data) throws -> Message {
        let bytes = [UInt8](data)
        let malformed = DictationError("Seed ASR stream sent a malformed frame.")
        guard bytes.count >= 4, bytes[0] >> 4 == 1 else { throw malformed }
        var offset = Int(bytes[0] & 0x0f) * 4
        let kind = bytes[1] >> 4, flags = bytes[1] & 0x0f, gzipped = bytes[2] & 0x0f == 1
        func u32() throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw malformed }
            defer { offset += 4 }
            return bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        func payload(_ size: Int) throws -> Data {
            guard size >= 0, offset + size <= bytes.count else { throw malformed }
            let body = Data(bytes[offset..<offset + size])
            return gzipped ? try gunzip(body) : body
        }
        switch kind {
        case 0b1111:
            let code = try u32()
            return .error(code: code, message: String(decoding: try payload(Int(try u32())), as: UTF8.self))
        case 0b1001:
            if flags & 0b0001 != 0 { _ = try u32() }
            return .response(isLast: flags & 0b0010 != 0, payload: try payload(Int(try u32())))
        default:
            throw malformed
        }
    }

    /// Only for a server that compresses anyway: strip the gzip wrapper, inflate raw DEFLATE.
    static func gunzip(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        let invalid = DictationError("Seed ASR stream sent invalid gzip.")
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw invalid }
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 { guard offset + 2 <= bytes.count else { throw invalid }; offset += 2 + Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        for bit in [UInt8(0x08), 0x10] where flags & bit != 0 {
            while offset < bytes.count, bytes[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < bytes.count - 8 else { throw invalid }
        return try (Data(bytes[offset..<bytes.count - 8]) as NSData).decompressed(using: .zlib) as Data
    }
}

/// One recognition result. With `result_type: full`, `text` is everything heard so far.
struct SeedStreamResult: Equatable, Sendable {
    var text: String
    var definiteUtterances: Int

    static func parse(_ payload: Data) -> SeedStreamResult? {
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        var result = json["result"]
        if let list = result as? [[String: Any]] { result = list.first }
        guard let result = result as? [String: Any], let text = result["text"] as? String else { return nil }
        let utterances = result["utterances"] as? [[String: Any]] ?? []
        return SeedStreamResult(text: text, definiteUtterances: utterances.filter { $0["definite"] as? Bool == true }.count)
    }
}

// MARK: - Session

/// One WebSocket recognition session per hold. All mutable state is confined to `queue`;
/// audio arrives from the recorder's render thread and is packed there into 200 ms packets.
final class SeedStreamingSession: @unchecked Sendable {
    enum Event: Sendable {
        case partial(SeedStreamResult)
        /// nil when the last frame carried no result: keep the latest partial.
        case final(SeedStreamResult?)
        case failed(String)
    }

    private let queue = DispatchQueue(label: "com.viberemote.dictation.seed-stream")
    private let onEvent: @Sendable (Event) -> Void
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var pending = Data()
    private var finished = false
    private var closed = false

    init(onEvent: @escaping @Sendable (Event) -> Void) { self.onEvent = onEvent }

    static func request(accessKey: String, appID: String, resourceID: String) -> URLRequest {
        var request = URLRequest(url: SeedStreamFrame.endpoint, timeoutInterval: 15)
        if appID.isEmpty {
            request.setValue(accessKey, forHTTPHeaderField: "X-Api-Key")
        } else {
            request.setValue(appID, forHTTPHeaderField: "X-Api-App-Key")
            request.setValue(accessKey, forHTTPHeaderField: "X-Api-Access-Key")
        }
        request.setValue(resourceID.isEmpty ? SeedStreamFrame.defaultResourceID : resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")
        return request
    }

    func start(_ request: URLRequest, appID: String) {
        queue.async {
            let session = URLSession(configuration: .ephemeral)
            let task = session.webSocketTask(with: request)
            self.session = session; self.task = task
            task.resume()
            self.send(SeedStreamFrame.fullClientRequest(json: SeedStreamFrame.requestJSON(appID: appID)))
            self.receive()
        }
    }

    /// Called from the recorder's render thread with 16 kHz mono samples.
    func append(_ samples: [Float]) {
        queue.async {
            guard !self.finished, !self.closed else { return }
            self.pending.append(SeedStreamFrame.pcm16(samples))
            while self.pending.count >= SeedStreamFrame.audioPacketBytes {
                self.send(SeedStreamFrame.audio(self.pending.prefix(SeedStreamFrame.audioPacketBytes), last: false))
                self.pending.removeFirst(SeedStreamFrame.audioPacketBytes)
            }
        }
    }

    /// Sends what is left as the negative (last) packet; the server then sends its final result.
    func finish() {
        queue.async {
            guard !self.finished, !self.closed else { return }
            self.finished = true
            self.send(SeedStreamFrame.audio(self.pending, last: true))
            self.pending = Data()
        }
    }

    func cancel() { queue.async { self.close() } }

    private func send(_ data: Data) {
        task?.send(.data(data)) { [weak self] error in
            guard let error, let self else { return }
            self.queue.async { self.fail("send failed: \(error.localizedDescription)") }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                switch result {
                case .failure(let error):
                    let http = self.task?.response as? HTTPURLResponse
                    let status = http.map { " HTTP \($0.statusCode)" } ?? ""
                    let logID = http?.value(forHTTPHeaderField: "X-Tt-Logid").map { " logid=\($0)" } ?? ""
                    self.fail("\(error.localizedDescription)\(status)\(logID)")
                case .success(let message):
                    let data: Data
                    switch message {
                    case .data(let bytes): data = bytes
                    case .string(let text): data = Data(text.utf8)
                    @unknown default: self.receive(); return
                    }
                    do {
                        switch try SeedStreamFrame.parse(data) {
                        case .error(let code, let message):
                            self.fail("error \(code): \(message)")
                        case .response(let isLast, let payload):
                            let parsed = SeedStreamResult.parse(payload)
                            if isLast {
                                self.onEvent(.final(parsed))
                                self.close()
                            } else {
                                if let parsed { self.onEvent(.partial(parsed)) }
                                self.receive()
                            }
                        }
                    } catch {
                        self.fail(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func fail(_ reason: String) {
        guard !closed else { return }
        onEvent(.failed(reason))
        close()
    }

    private func close() {
        guard !closed else { return }
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil; session = nil
    }
}

// MARK: - Typewriter

/// The typewriter's decisions, kept pure so diffing, pacing and the caret guard are testable.
enum DictationTypewriterPlan {
    static let tick: TimeInterval = 0.012
    /// Aim to type a backlog in about one audio packet, so text flows instead of bursting.
    static let spread: TimeInterval = 0.18
    static let maximumDeletesPerTick = 40
    /// Caret checks before a correction may wait this many times for a lagging editor.
    static let maximumCaretWaits = 6

    /// Keep the longest common prefix of characters; delete what follows it on screen, then
    /// type the rest of the target. Doubao logs the same decision as replaceLength /
    /// commonPrefixCount.
    static func edit(displayed: String, target: String) -> (delete: Int, insert: String) {
        var shown = displayed.startIndex, wanted = target.startIndex
        while shown < displayed.endIndex, wanted < target.endIndex, displayed[shown] == target[wanted] {
            shown = displayed.index(after: shown); wanted = target.index(after: wanted)
        }
        return (displayed.distance(from: shown, to: displayed.endIndex), String(target[wanted...]))
    }

    /// While Siri is held the screen only grows (user's request, 2026-11-10: deleting and
    /// retyping partials looked unstable, and the refined result after release replaces them
    /// anyway). It shows what two consecutive partials agree on, so the recognizer's still-moving
    /// tail stays off screen. When a revision changes text already shown, typing carries on after
    /// the shown text's last few characters, found again near the end of the agreed text; if those
    /// were revised away too, nothing is added until release.
    static func growth(shown target: String, previous: String, latest: String) -> String {
        let agreed = commonPrefix(previous, latest)
        if agreed.hasPrefix(target) { return agreed.count > target.count ? agreed : target }
        guard !target.isEmpty else { return agreed }
        let anchor = String(target.suffix(min(6, target.count)))
        guard let found = agreed.range(of: anchor, options: .backwards),
              // The anchor's real place is about where the shown text ends; an earlier repeat of
              // the same characters would type a duplicate.
              abs(agreed.distance(from: agreed.startIndex, to: found.upperBound) - target.count) <= 12
        else { return target }
        let rest = agreed[found.upperBound...]
        return rest.isEmpty ? target : target + rest
    }

    static func commonPrefix(_ a: String, _ b: String) -> String {
        var end = a.startIndex, other = b.startIndex
        while end < a.endIndex, other < b.endIndex, a[end] == b[other] {
            end = a.index(after: end); other = b.index(after: other)
        }
        return String(a[..<end])
    }

    /// One character at a time while the screen is nearly caught up, so speech reads as typing;
    /// more per tick as text backs up, so the screen never trails recognition by much.
    static func pace(backlog: Int) -> (characters: Int, interval: TimeInterval) {
        guard backlog > 0 else { return (0, tick) }
        let perCharacter = spread / Double(backlog)
        if perCharacter >= tick { return (1, min(0.045, perCharacter)) }
        return (Int((Double(backlog) * tick / spread).rounded(.up)), tick)
    }

    /// Up to `characters` characters, never more than one key event (20 UTF-16 units) holds.
    static func chunk(_ text: String, characters: Int) -> String {
        var result = ""
        for character in text.prefix(max(1, characters)) {
            if result.utf16.count + character.utf16.count > 20, !result.isEmpty { break }
            result.append(character)
        }
        return result
    }

    enum CaretCheck: Equatable { case proceed, wait }

    /// A correction deletes real characters, so it may only run while the caret sits exactly
    /// at the end of what this hold typed. Unknown positions (no anchor, unreadable selection)
    /// proceed: the focus check still applies, and the delete never exceeds our own text.
    static func caretCheck(expected: Int?, observed: CFRange?) -> CaretCheck {
        guard let expected, let observed else { return .proceed }
        return observed.length == 0 && observed.location == expected ? .proceed : .wait
    }
}

/// Moves the editor's text toward the latest transcript one paced tick at a time. Each hold has
/// its own; a hold that starts while the previous one is still typing waits for it, so two
/// holds never interleave keystrokes.
@MainActor
final class DictationTypewriter {
    private struct Focus {
        let pid: pid_t
        let element: AXUIElement?
        /// UTF-16 selection start when this hold began typing: typing replaces any selection,
        /// so the caret should then sit at anchor + typed length.
        let anchor: Int?
    }

    private(set) var displayed = ""
    /// Where the editor's caret should be once the screen has caught up: the hold's anchor plus
    /// what it has typed. nil before the first keystroke or when the selection was unreadable.
    var expectedCaret: Int? { focus?.anchor.map { $0 + displayed.utf16.count } }
    private(set) var isDone = false
    private(set) var stoppedReason: String?
    private(set) var deletedCharacters = 0
    var onEmit: (() -> Void)?

    private var target = ""
    private var previousPartial = ""
    private var finishing = false
    private var completion: (() -> Void)?
    private var timer: Timer?
    private var settleTicks = 0
    private var caretWaits = 0
    private var focus: Focus?
    private var lastElementCheck: TimeInterval = 0
    private var previous: DictationTypewriter?

    init(after previous: DictationTypewriter?) {
        self.previous = previous?.isDone == false ? previous : nil
    }

    /// A partial while Siri is held: the screen only grows (`DictationTypewriterPlan.growth`).
    /// Deletions wait for `finish`, which reconciles toward the refined result in one pass.
    func update(_ text: String) {
        guard !finishing, !isDone else { return }
        let latest = DictationTyper.normalized(text)
        target = DictationTypewriterPlan.growth(shown: target, previous: previousPartial, latest: latest)
        previousPartial = latest
        schedule(0)
    }

    /// The last target (nil keeps the latest partial); `completion` runs once the screen
    /// matches it or the typewriter has stopped.
    func finish(_ text: String?, completion: @escaping () -> Void) {
        if let text, !isDone { target = DictationTyper.normalized(text) }
        finishing = true
        if isDone { completion(); return }
        self.completion = completion
        schedule(0)
    }

    func finish(_ text: String?) async {
        await withCheckedContinuation { continuation in finish(text) { continuation.resume() } }
    }

    /// Leaves whatever is on screen and types nothing more.
    func stop(_ reason: String) {
        guard !isDone else { return }
        stoppedReason = reason
        rmDebug("🗣 Dictation typing stopped: \(reason)")
        complete()
    }

    private func complete() {
        isDone = true
        timer?.invalidate(); timer = nil
        let done = completion
        completion = nil
        done?()
    }

    private func schedule(_ interval: TimeInterval) {
        guard timer == nil, !isDone else { return }
        let next = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    private func tick() {
        timer = nil
        guard !isDone else { return }
        if let previous {
            guard previous.isDone else { schedule(0.03); return }
            self.previous = nil
        }
        let plan = DictationTypewriterPlan.edit(displayed: displayed, target: target)
        if plan.delete == 0, plan.insert.isEmpty {
            if finishing { complete() }
            return
        }
        if settleTicks > 0 { settleTicks -= 1; schedule(DictationTypewriterPlan.tick); return }
        if focus == nil { focus = Self.captureFocus() }
        guard let focus else { stop("no focused app"); return }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.pid else { stop("focus moved to another app"); return }
        let now = ProcessInfo.processInfo.systemUptime
        if plan.delete > 0 || now - lastElementCheck > 0.1 {
            lastElementCheck = now
            guard Self.stillFocused(focus) else { stop("focus moved to another field"); return }
        }
        if plan.delete > 0 {
            let expected = focus.anchor.map { $0 + displayed.utf16.count }
            let observed = focus.element.flatMap(Self.selection)
            if DictationTypewriterPlan.caretCheck(expected: expected, observed: observed) == .wait {
                caretWaits += 1
                if caretWaits > DictationTypewriterPlan.maximumCaretWaits { stop("the cursor moved"); return }
                schedule(0.03)
                return
            }
            caretWaits = 0
            let count = min(plan.delete, DictationTypewriterPlan.maximumDeletesPerTick)
            for _ in 0..<count {
                RemoteInputHandler.makeKeyEvent(keyCode: 51, flags: [], keyDown: true)?.post(tap: .cghidEventTap)
                RemoteInputHandler.makeKeyEvent(keyCode: 51, flags: [], keyDown: false)?.post(tap: .cghidEventTap)
            }
            displayed.removeLast(count)
            deletedCharacters += count
            // Web editors need a beat after a replacement before more typing (Doubao skips a
            // round for the same reason).
            settleTicks = 1
            onEmit?()
            schedule(DictationTypewriterPlan.tick)
            return
        }
        let pace = DictationTypewriterPlan.pace(backlog: plan.insert.count)
        let chunk = DictationTypewriterPlan.chunk(plan.insert, characters: pace.characters)
        RemoteInputHandler.makeKeyEvent(keyCode: 0, flags: [], keyDown: true, text: chunk)?.post(tap: .cghidEventTap)
        RemoteInputHandler.makeKeyEvent(keyCode: 0, flags: [], keyDown: false, text: chunk)?.post(tap: .cghidEventTap)
        displayed += chunk
        onEmit?()
        schedule(pace.interval)
    }

    private static func captureFocus() -> Focus? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let element = focusedElement(pid: pid)
        return Focus(pid: pid, element: element, anchor: element.flatMap(selection).map { Int($0.location) })
    }

    private static func focusedElement(pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.03)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }

    /// Without a readable focused element at the start there is nothing to compare against.
    private static func stillFocused(_ focus: Focus) -> Bool {
        guard let original = focus.element else { return true }
        guard let current = focusedElement(pid: focus.pid) else { return true }
        return CFEqual(original, current)
    }

    private static func selection(_ element: AXUIElement) -> CFRange? {
        AXUIElementSetMessagingTimeout(element, 0.03)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(unsafeBitCast(raw, to: AXValue.self), .cfRange, &range) ? range : nil
    }
}

// MARK: - Command-line verification

/// `VibeRemote --verify-seed-stream <audio file>` streams a file through the same session the
/// app uses, paced in real time, with the app's own Keychain key — so the protocol can be
/// checked end to end without the key ever leaving the app. Prints the transcript of the file
/// it was given and the timings.
enum SeedStreamVerifier {
    private final class Record: @unchecked Sendable {
        let lock = NSLock()
        var partials = 0
        var firstPartial: TimeInterval?
        var final: String?
        var failure: String?
        var finalAt: TimeInterval?
    }

    static func run(path: String) -> Never {
        let settings = DictationSettings.load()
        guard let key = DictationKeychain.key(for: .seedASR) else { print("No Seed ASR key in the Keychain."); exit(2) }
        guard let samples = loadSamples(URL(fileURLWithPath: path)) else { print("Could not read \(path)."); exit(2) }
        let record = Record()
        let done = DispatchSemaphore(value: 0)
        let started = ProcessInfo.processInfo.systemUptime
        let session = SeedStreamingSession { event in
            let now = ProcessInfo.processInfo.systemUptime - started
            record.lock.lock(); defer { record.lock.unlock() }
            switch event {
            case .partial(let result):
                record.partials += 1
                if record.firstPartial == nil, !result.text.isEmpty { record.firstPartial = now }
                record.final = result.text
            case .final(let result):
                if let result { record.final = result.text }
                record.finalAt = now
                done.signal()
            case .failed(let reason):
                record.failure = reason
                done.signal()
            }
        }
        session.start(SeedStreamingSession.request(accessKey: key, appID: settings.seedAppID,
                                                   resourceID: settings.seedStreamResourceID), appID: settings.seedAppID)
        let packet = SeedStreamFrame.audioPacketBytes / 2
        var offset = 0
        while offset < samples.count {
            session.append(Array(samples[offset..<min(samples.count, offset + packet)]))
            offset += packet
            Thread.sleep(forTimeInterval: 0.2)
        }
        let lastSent = ProcessInfo.processInfo.systemUptime - started
        session.finish()
        let answered = done.wait(timeout: .now() + 15) == .success
        record.lock.lock(); defer { record.lock.unlock() }
        print(String(format: "audio: %.1f s, partial updates: %d", Double(samples.count) / 16_000, record.partials))
        if let first = record.firstPartial { print(String(format: "first partial: %.2f s after connect", first)) }
        if let failure = record.failure { print("failed: \(failure)"); exit(1) }
        guard answered, let finalAt = record.finalAt else { print("no final result within 15 s"); exit(1) }
        print(String(format: "final: %.2f s after the last packet", finalAt - lastSent))
        print("text: \(record.final ?? "")")
        exit(0)
    }

    private static func loadSamples(_ url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1_024)
        else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

// MARK: - One streaming hold

/// The streaming half of one hold: its session, its typewriter, and how the stream ended.
@MainActor
final class DictationLiveHold {
    var session: SeedStreamingSession?
    let typewriter: DictationTypewriter
    let startedAt = Date()
    private(set) var latest: SeedStreamResult?
    private(set) var failure: String?
    private(set) var partials = 0
    private(set) var firstTextAt: Date?
    private(set) var ended = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(typewriter: DictationTypewriter) { self.typewriter = typewriter }

    /// A final result arrived, so its text (possibly empty) is the answer.
    var succeeded: Bool { ended && failure == nil }

    func handle(_ event: SeedStreamingSession.Event) {
        guard !ended else { return }
        switch event {
        case .partial(let result):
            partials += 1
            if firstTextAt == nil, !result.text.isEmpty { firstTextAt = Date() }
            latest = result
            typewriter.update(result.text)
        case .final(let result):
            if let result { latest = result }
            end()
        case .failed(let reason):
            failure = reason
            rmDebug("⚠️ Dictation stream failed: \(reason)")
            end()
        }
    }

    /// Returns once the server has answered the last packet, failed, or `timeout` passed.
    func waitForEnd(timeout: TimeInterval) async {
        guard !ended else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, !self.ended else { return }
                self.failure = "no final result within \(Int(timeout)) s"
                self.session?.cancel()
                self.end()
            }
        }
    }

    func cancel() {
        session?.cancel()
        if !ended { failure = "cancelled"; end() }
    }

    private func end() {
        ended = true
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}
