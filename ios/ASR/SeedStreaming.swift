// Port of macos/DictationStreaming.swift wire codec and serial session.
import zlib
import AVFoundation
import Foundation

// Streaming dictation ("flow output"), modeled on Doubao IME: recognition runs while Siri is
// still held, partial text is typed into the editor as it arrives, and later revisions replace
// only the tail that changed. Doubao shows partials as IMK marked text; vvhisper is not an
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
    /// 100 ms by default. Set dictationAudioPacketMilliseconds=200 for comparison.
    static var audioPacketBytes: Int {
        UserDefaults.standard.integer(forKey: "dictationAudioPacketMilliseconds") == 200 ? 6_400 : 3_200
    }

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

    static func gunzip(_ data: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw DictationError("Could not initialize decompression.")
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var result = Data()
            var status: Int32 = Z_OK
            repeat {
                var chunk = [UInt8](repeating: 0, count: 16384)
                let count = chunk.withUnsafeMutableBytes { output -> Int in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(output.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return output.count - Int(stream.avail_out)
                }
                guard status == Z_OK || status == Z_STREAM_END, result.count + count < 4_000_000 else {
                    throw DictationError("Seed sent invalid compressed data.")
                }
                result.append(contentsOf: chunk.prefix(count))
            } while status != Z_STREAM_END
            return result
        }
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
        /// A coarse class only: provider bodies, identifiers and status text never leave the session.
        case failed(DictationFailureKind)
    }

    private let queue = DispatchQueue(label: "com.vvhisper.dictation.seed-stream")
    private let onEvent: @Sendable (Event) -> Void
    private let packetBytes = SeedStreamFrame.audioPacketBytes
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
        while pending.count >= packetBytes {
            send(SeedStreamFrame.audio(pending.prefix(packetBytes), last: false))
            pending.removeFirst(packetBytes)
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

    /// WebKit supplies native-endian Int16 PCM (little-endian on supported arm64).
    func appendPCM16(_ pcm: Data) {
        guard !pcm.isEmpty, pcm.count <= 16384, pcm.count.isMultiple(of: 2) else { return }
        queue.async {
            guard !self.finished, !self.closed else { return }
            self.pending.append(pcm)
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
            self.queue.async { self.fail(DictationFailureKind.classify(error)) }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                switch result {
                case .failure(let error):
                    // The handshake status distinguishes a rejected key or quota from transport loss.
                    let status = (self.task?.response as? HTTPURLResponse)?.statusCode
                    self.fail(status.flatMap(DictationFailureKind.classify(httpStatus:)) ?? DictationFailureKind.classify(error))
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
                            self.fail(DictationFailureKind.classify(seedCode: code, message: message))
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
                        self.fail(.other)
                    }
                }
            }
        }
    }

    private func fail(_ kind: DictationFailureKind) {
        guard !closed else { return }
        onEvent(.failed(kind))
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


struct DictationError: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
