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
    /// Volcengine's streaming-input mode: the same protocol, but it answers only after the last
    /// packet (or every 15 s of audio), with the more accurate non-streaming model.
    static let nostreamEndpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream")!
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
    /// `context` is hotwords as Volcengine's `request.corpus.context` JSON string. Dictation does
    /// not send it on the stream (it degraded two-way recognition, see `startStream`); the
    /// verifier's `--stream-hotwords` still can, to re-measure.
    /// `removeFillers` is `enable_ddc` (语义顺滑), the same flag the refinement sends.
    /// `sentenceSilence` is `vad_segment_duration` in ms, documented as the silence after which a
    /// new sentence starts (default 3000). Measured 2026-11-12 it changed nothing on any endpoint,
    /// so dictation leaves it unset; the verifier's `--vad` keeps it measurable.
    static func requestJSON(appID: String, context: String? = nil, removeFillers: Bool = false,
                            sentenceSilence: Int? = nil) -> Data {
        var request: [String: Any] = ["model_name": "bigmodel", "enable_itn": true, "enable_punc": true,
                                      "enable_ddc": removeFillers,
                                      "enable_nonstream": false, "show_utterances": true, "result_type": "full"]
        if let context { request["corpus"] = ["context": context] }
        if let sentenceSilence { request["vad_segment_duration"] = sentenceSilence }
        let body: [String: Any] = [
            "user": ["uid": appID.isEmpty ? "viberemote" : appID],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16_000, "bits": 16, "channel": 1],
            "request": request,
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
    /// Audio may arrive before `start` (the refinement session waits for the editor context):
    /// it is held in `pending` and sent once the request has gone out.
    private var started = false

    init(onEvent: @escaping @Sendable (Event) -> Void) { self.onEvent = onEvent }

    static func request(accessKey: String, appID: String, resourceID: String,
                        endpoint: URL = SeedStreamFrame.endpoint) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
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

    func start(_ request: URLRequest, appID: String, context: String? = nil, removeFillers: Bool = false,
               sentenceSilence: Int? = nil) {
        queue.async {
            // A refinement session can be cancelled (hold too short) before its context arrives.
            guard !self.closed else { return }
            let session = URLSession(configuration: .ephemeral)
            let task = session.webSocketTask(with: request)
            self.session = session; self.task = task
            task.resume()
            self.send(SeedStreamFrame.fullClientRequest(json: SeedStreamFrame.requestJSON(appID: appID, context: context,
                                                                                     removeFillers: removeFillers,
                                                                                     sentenceSilence: sentenceSilence)))
            self.started = true
            self.flushPackets()
            if self.finished { self.sendLast() }
            self.receive()
        }
    }

    private func flushPackets() {
        while pending.count >= SeedStreamFrame.audioPacketBytes {
            send(SeedStreamFrame.audio(pending.prefix(SeedStreamFrame.audioPacketBytes), last: false))
            pending.removeFirst(SeedStreamFrame.audioPacketBytes)
        }
    }

    private func sendLast() {
        send(SeedStreamFrame.audio(pending, last: true))
        pending = Data()
    }

    /// Called from the recorder's render thread with 16 kHz mono samples.
    func append(_ samples: [Float]) {
        queue.async {
            guard !self.finished, !self.closed else { return }
            self.pending.append(SeedStreamFrame.pcm16(samples))
            if self.started { self.flushPackets() }
        }
    }

    /// Sends what is left as the negative (last) packet; the server then sends its final result.
    func finish() {
        queue.async {
            guard !self.finished, !self.closed else { return }
            self.finished = true
            if self.started { self.sendLast() }
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
    /// tail stays off screen. When a revision changes text already shown, typing carries on from
    /// where the shown text's end falls in the agreed text (`alignedEnd`); only when it cannot be
    /// found at all is nothing added until release.
    static func growth(shown target: String, previous: String, latest: String) -> String {
        let agreed = commonPrefix(previous, latest)
        if agreed.hasPrefix(target) { return agreed.count > target.count ? agreed : target }
        guard !target.isEmpty, let end = alignedEnd(of: target, in: agreed) else { return target.isEmpty ? agreed : target }
        return target + agreed[agreed.index(agreed.startIndex, offsetBy: end)...]
    }

    /// Where the end of the shown text falls in the agreed text. Its last characters are found
    /// again near where they ended; failing that, a longer run of them that occurs exactly once,
    /// because revisions of earlier text add up: a 15 s hold on 2026-11-13 drifted past the
    /// former fixed 12-character window and typing stopped at 114 of 276 characters. If the
    /// last characters themselves were revised ("cafe" → "café"), the run a few characters
    /// earlier stands in and as many agreed characters are skipped as follow it on screen.
    /// A character offset into `agreed`.
    static func alignedEnd(of shown: String, in agreed: String) -> Int? {
        let shown = Array(shown), agreed = Array(agreed)
        func endings(of anchor: ArraySlice<Character>) -> [Int] {
            guard !anchor.isEmpty, anchor.count <= agreed.count else { return [] }
            return (anchor.count...agreed.count).filter { agreed[($0 - anchor.count)..<$0].elementsEqual(anchor) }
        }
        for skip in 0...min(8, shown.count - 1) {
            let end = shown.count - skip
            // Skip only within the last word: a skipped space or punctuation means the anchor
            // would come from an earlier word, which a repeat elsewhere can match.
            if skip > 0, !(shown[(end - 1)...]).allSatisfy({ $0.isLetter || $0.isNumber }) { break }
            var found: Int?
            // Near its expected place, the last such occurrence (an earlier repeat of the same
            // characters would type a duplicate).
            let near = shown[max(0, end - 6)..<end]
            if let last = endings(of: near).last(where: { abs($0 - end) <= 12 }) {
                found = last
            } else if end >= 12 {
                // Anywhere, when a 12-character run is unambiguous.
                let long = endings(of: shown[(end - 12)..<end])
                if long.count == 1 { found = long[0] }
            }
            if let found {
                return agreed.count >= found + skip ? found + skip : nil
            }
        }
        return nil
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

    /// The final correction in one step (2026-11-12, user's request: backspacing the old tail
    /// read like a person deleting): the UTF-16 range of what is replaced — from the end of the
    /// common prefix to the end of what this hold typed, never before `anchor`.
    static func replacementRange(anchor: Int, displayed: String, delete: Int) -> CFRange {
        let kept = String(displayed.prefix(max(0, displayed.count - delete)))
        let start = anchor + kept.utf16.count
        return CFRange(location: start, length: anchor + displayed.utf16.count - start)
    }

    /// Splits text into key events of at most 20 UTF-16 units each, on character boundaries.
    static func chunks(_ text: String) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            let piece = chunk(String(rest), characters: rest.count)
            result.append(piece)
            rest = rest.dropFirst(piece.count)
        }
        return result
    }

    /// Selection checks after the replacement selection is written (Chromium applies it
    /// asynchronously), 15 ms apart.
    static let maximumSelectionWaits = 8

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
    /// How the corrections were made, for the hold's log line.
    var correctionMethod: String {
        deletedCharacters == 0 ? "" : selectionUnavailable ? " by Backspace" : " by selection"
    }
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
    /// The final replacement's selection, written and awaiting confirmation.
    private var replacing: (range: CFRange, waits: Int)?
    /// Selecting failed once in this editor: further corrections use Backspace.
    private var selectionUnavailable = false
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
        if let pending = replacing, let focus, let element = focus.element {
            confirmReplacement(pending, element: element, focus: focus, plan: plan)
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
            // After release: select the tail being replaced and type over it, instead of
            // backspacing it away one key at a time.
            if finishing, !selectionUnavailable, let anchor = focus.anchor, let element = focus.element {
                let range = DictationTypewriterPlan.replacementRange(anchor: anchor, displayed: displayed, delete: plan.delete)
                if Self.select(element, range) {
                    replacing = (range, 0)
                    schedule(0.015)
                    return
                }
                selectionUnavailable = true
            }
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
        // After release the refined text goes in at once; while Siri is held it is paced.
        if finishing {
            type(plan.insert)
            displayed += plan.insert
            onEmit?()
            schedule(DictationTypewriterPlan.tick)
            return
        }
        let pace = DictationTypewriterPlan.pace(backlog: plan.insert.count)
        let chunk = DictationTypewriterPlan.chunk(plan.insert, characters: pace.characters)
        type(chunk)
        displayed += chunk
        onEmit?()
        schedule(pace.interval)
    }

    private func type(_ text: String) {
        for chunk in DictationTypewriterPlan.chunks(text) {
            RemoteInputHandler.makeKeyEvent(keyCode: 0, flags: [], keyDown: true, text: chunk)?.post(tap: .cghidEventTap)
            RemoteInputHandler.makeKeyEvent(keyCode: 0, flags: [], keyDown: false, text: chunk)?.post(tap: .cghidEventTap)
        }
    }

    /// Types over the selection once the editor reports exactly the range written; typing
    /// replaces a selection, and an empty replacement is one Backspace. If the editor never
    /// confirms it, the caret goes back to the end of the hold's text and Backspace takes over.
    private func confirmReplacement(_ pending: (range: CFRange, waits: Int), element: AXUIElement,
                                    focus: Focus, plan: (delete: Int, insert: String)) {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == focus.pid, Self.stillFocused(focus) else {
            replacing = nil
            stop("focus moved during the correction")
            return
        }
        let observed = Self.selection(element)
        guard let observed, observed.location == pending.range.location, observed.length == pending.range.length else {
            if pending.waits + 1 >= DictationTypewriterPlan.maximumSelectionWaits {
                replacing = nil
                selectionUnavailable = true
                if let anchor = focus.anchor {
                    _ = Self.select(element, CFRange(location: anchor + displayed.utf16.count, length: 0))
                }
                schedule(0.03)
            } else {
                replacing = (pending.range, pending.waits + 1)
                schedule(0.015)
            }
            return
        }
        replacing = nil
        if plan.insert.isEmpty {
            RemoteInputHandler.makeKeyEvent(keyCode: 51, flags: [], keyDown: true)?.post(tap: .cghidEventTap)
            RemoteInputHandler.makeKeyEvent(keyCode: 51, flags: [], keyDown: false)?.post(tap: .cghidEventTap)
        } else {
            type(plan.insert)
        }
        displayed.removeLast(plan.delete)
        displayed += plan.insert
        deletedCharacters += plan.delete
        onEmit?()
        schedule(DictationTypewriterPlan.tick)
    }

    private static func select(_ element: AXUIElement, _ range: CFRange) -> Bool {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return false }
        AXUIElementSetMessagingTimeout(element, 0.05)
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
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
        var settings = DictationSettings.load()
        // `--hotwords a,b` checks the dictionary's hints without touching the saved dictionary;
        // `--hotwords ""` runs without any.
        if let index = CommandLine.arguments.firstIndex(of: "--hotwords"), CommandLine.arguments.indices.contains(index + 1) {
            settings.dictionary = CommandLine.arguments[index + 1].split(separator: ",")
                .map { DictationDictionaryEntry(word: $0.trimmingCharacters(in: .whitespaces)) }
        }
        // `--context "text"` stands in for the text before the caret; `--no-ddc` turns filler
        // removal off, so both can be compared on the same clip.
        var editorText: String?
        if let index = CommandLine.arguments.firstIndex(of: "--context"), CommandLine.arguments.indices.contains(index + 1) {
            editorText = CommandLine.arguments[index + 1]
        }
        if CommandLine.arguments.contains("--no-ddc") { settings.seedRemoveFillers = false }
        // `--vad <ms>` sets `vad_segment_duration` on every request (Volcengine's default otherwise).
        var sentenceSilence: Int?
        if let index = CommandLine.arguments.firstIndex(of: "--vad"), CommandLine.arguments.indices.contains(index + 1) {
            sentenceSilence = Int(CommandLine.arguments[index + 1])
        }
        print("sentence silence: \(sentenceSilence.map { "\($0) ms" } ?? "default")")
        let context = DictationDictionary.seedContext(settings.dictionary, editorText: editorText)
        print("hotwords: \(DictationDictionary.hotwords(settings.dictionary)), editor context: \(editorText?.count ?? 0) chars, remove fillers: \(settings.seedRemoveFillers)")
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
        // `--nostream` feeds the same packets to the streaming-input mode in parallel, the way a
        // hold would, to compare it with the flash refinement.
        let nostream = Record()
        let nostreamDone = DispatchSemaphore(value: 0)
        let second: SeedStreamingSession? = CommandLine.arguments.contains("--nostream") ? SeedStreamingSession { event in
            let now = ProcessInfo.processInfo.systemUptime - started
            nostream.lock.lock(); defer { nostream.lock.unlock() }
            switch event {
            case .partial(let result): nostream.partials += 1; nostream.final = result.text
            case .final(let result):
                if let result { nostream.final = result.text }
                nostream.finalAt = now
                nostreamDone.signal()
            case .failed(let reason): nostream.failure = reason; nostreamDone.signal()
            }
        } : nil
        // Started after the first packets, as in a hold that waits for the editor context, so the
        // session's buffering of early audio is exercised too.
        let startSecond = {
            second?.start(SeedStreamingSession.request(accessKey: key, appID: settings.seedAppID,
                                                       resourceID: settings.seedStreamResourceID,
                                                       endpoint: SeedStreamFrame.nostreamEndpoint),
                          appID: settings.seedAppID, context: context, removeFillers: settings.seedRemoveFillers,
                          sentenceSilence: sentenceSilence)
        }
        session.start(SeedStreamingSession.request(accessKey: key, appID: settings.seedAppID,
                                                   resourceID: settings.seedStreamResourceID), appID: settings.seedAppID,
                      context: CommandLine.arguments.contains("--stream-hotwords") ? context : nil,
                      removeFillers: settings.seedRemoveFillers, sentenceSilence: sentenceSilence)
        let packet = SeedStreamFrame.audioPacketBytes / 2
        var offset = 0
        while offset < samples.count {
            let chunk = Array(samples[offset..<min(samples.count, offset + packet)])
            session.append(chunk)
            second?.append(chunk)
            offset += packet
            if offset == 2 * packet { startSecond() }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let lastSent = ProcessInfo.processInfo.systemUptime - started
        if offset < 2 * packet { startSecond() }
        session.finish()
        second?.finish()
        let answered = done.wait(timeout: .now() + 15) == .success
        record.lock.lock(); defer { record.lock.unlock() }
        print(String(format: "audio: %.1f s, partial updates: %d", Double(samples.count) / 16_000, record.partials))
        if let first = record.firstPartial { print(String(format: "first partial: %.2f s after connect", first)) }
        if let failure = record.failure { print("failed: \(failure)"); exit(1) }
        guard answered, let finalAt = record.finalAt else { print("no final result within 15 s"); exit(1) }
        print(String(format: "final: %.2f s after the last packet", finalAt - lastSent))
        print("stream text: \(record.final ?? "")")
        if second != nil {
            _ = nostreamDone.wait(timeout: .now() + 15)
            nostream.lock.lock()
            if let failure = nostream.failure { print("nostream failed: \(failure)") }
            else { print(String(format: "nostream text (%.2f s after the last packet): %@", (nostream.finalAt ?? 0) - lastSent, nostream.final ?? "")) }
            nostream.lock.unlock()
        }
        let flashStarted = ProcessInfo.processInfo.systemUptime
        // The refinement after release, with the same hotwords and editor context.
        let refined = DispatchSemaphore(value: 0)
        let engine = SeedASRDictationEngine(accessKey: key, appID: settings.seedAppID,
                                            resourceID: settings.seedResourceID, context: context,
                                            removeFillers: settings.seedRemoveFillers,
                                            sentenceSilence: sentenceSilence)
        let clip = DictationAudio(samples: samples)
        Task.detached {
            do {
                let text = try await engine.transcribe(clip, language: "")
                print(String(format: "flash text (%.2f s): %@", ProcessInfo.processInfo.systemUptime - flashStarted, text))
                if settings.seedRemoveFillers { print("flash cleaned: \(DictationFillers.clean(text))") }
            }
            catch { print("flash failed: \(error.localizedDescription)") }
            refined.signal()
        }
        _ = refined.wait(timeout: .now() + 30)
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

    /// Applied to every partial before it reaches the typewriter, so the screen shows the
    /// dictionary's spellings while speaking too.
    let dictionary: [DictationDictionaryEntry]

    /// Where partials go. Auto Computer Use decides at Siri down whether the hold types into the
    /// focused editor or fills the Computer Use bar; until that probe answers (a few ms, long
    /// before the first partial) partials are only kept.
    enum Routing { case pending, typewriter, handoff((String) -> Void) }
    private(set) var routing: Routing = .typewriter

    /// Sets where partials go and delivers the latest one there at once.
    func route(_ routing: Routing) {
        self.routing = routing
        if let latest { deliver(DictationDictionary.apply(dictionary, to: latest.text)) }
    }

    private func deliver(_ text: String) {
        switch routing {
        case .pending: break
        case .typewriter: typewriter.update(text)
        case .handoff(let show): show(text)
        }
    }

    init(typewriter: DictationTypewriter, dictionary: [DictationDictionaryEntry] = []) {
        self.typewriter = typewriter
        self.dictionary = dictionary
    }

    /// A final result arrived, so its text (possibly empty) is the answer.
    var succeeded: Bool { ended && failure == nil }

    func handle(_ event: SeedStreamingSession.Event) {
        guard !ended else { return }
        switch event {
        case .partial(let result):
            partials += 1
            if firstTextAt == nil, !result.text.isEmpty { firstTextAt = Date() }
            latest = result
            deliver(DictationDictionary.apply(dictionary, to: result.text))
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

// MARK: - The refinement session

/// The accurate pass of one Seed hold (2026-11-12, user's request): the same audio, fed during
/// the hold to Volcengine's streaming-input mode (`bigmodel_nostream`), which answers only after
/// the last packet, with the non-streaming model. Measured the same day on clips up to 16 s it
/// gave the flash API's text word for word, 0.5–1.4 s after release instead of flash's 1.2–19 s,
/// because the audio is already uploaded when Siri is released. It also punctuates by meaning
/// across thinking pauses, where flash ends a sentence at every pause over ~3 s, so it serves
/// every hold length; past 15 s it can misread a word or add a break near its window seam. It carries the hints the live stream does not take: the
/// dictionary's hotwords and the text before the caret. Flash stays the fallback.
@MainActor
final class DictationRefinementStream {
    var session: SeedStreamingSession?
    private(set) var text: String?
    private(set) var failure: String?
    private(set) var ended = false
    private var latest: String?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// A session whose events reach `stream`; the caller starts it once the hints are known.
    static func make() -> DictationRefinementStream {
        let stream = DictationRefinementStream()
        stream.session = SeedStreamingSession { [weak stream] event in
            Task { @MainActor in stream?.handle(event) }
        }
        return stream
    }

    /// The answer, or nil when the session failed, timed out or recognized nothing.
    var answer: String? {
        guard ended, failure == nil, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    func handle(_ event: SeedStreamingSession.Event) {
        guard !ended else { return }
        switch event {
        case .partial(let result):
            // Every 15 s of audio the mode reports what it has; the final result is the answer.
            latest = result.text
        case .final(let result):
            text = result?.text ?? latest
            end()
        case .failed(let reason):
            failure = reason
            rmDebug("⚠️ Dictation refinement stream failed: \(reason)")
            end()
        }
    }

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
