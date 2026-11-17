import AVFoundation
import Foundation
import RemoteAudioProtocol

/// What one dictation hold records from: the Mac's microphone (`DictationRecorder`) or the
/// voice helper's decoded sessions (`DictationBridgeAudioReader`).
protocol DictationAudioSource: AnyObject, Sendable {
    func stop() -> DictationAudio
}

extension DictationRecorder: DictationAudioSource {}

/// Reads the remote's decoded voice straight from the voice helper (`DictationAudioFile`)
/// instead of recording the virtual device's loopback, which only carries audio after it has
/// played out. A hold can therefore end at the remote's protocol end rather than at output
/// drain plus a grace period, and needs no Microphone permission for the remote.
///
/// Polling runs on one serial queue, only while a hold records. The helper renames each new
/// session's file into place; an open handle keeps reading the session it adopted.
final class DictationBridgeAudioReader: DictationAudioSource, @unchecked Sendable {
    static let pollInterval: DispatchTimeInterval = .milliseconds(20)

    private let path: String
    private let holdStartedAt: Date
    private let excluded: Set<UUID>
    private let followsLaterSessions: Bool
    private let onSamples: (@Sendable ([Float]) -> Void)?
    private let queue = DispatchQueue(label: "com.vvhisper.dictation.bridgeAudio")
    private let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: DictationAudioFile.sampleRate,
                                       channels: 1, interleaved: false)!
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: DictationAudio.sampleRate,
                                       channels: 1, interleaved: false)!
    // Everything below is confined to `queue`.
    private var timer: DispatchSourceTimer?
    private var file: FileHandle?
    private var offset: UInt64 = 0
    private var seenFile: (device: dev_t, inode: ino_t)?
    private var sessions: [UUID] = []
    private var accepting = true
    private var samples: [Float] = []
    private lazy var converter = AVAudioConverter(from: source, to: target)

    /// `excluding` lists sessions earlier holds already took. A first-generation tail re-press
    /// continues the same hold, so `followsLaterSessions` lets it take the session that press
    /// starts; other holds take exactly one session.
    init(path: String, holdStartedAt: Date, excluding: Set<UUID>, followsLaterSessions: Bool,
         onSamples: (@Sendable ([Float]) -> Void)? = nil) {
        self.path = path
        self.holdStartedAt = holdStartedAt
        self.excluded = excluding
        self.followsLaterSessions = followsLaterSessions
        self.onSamples = onSamples
    }

    func start() {
        queue.sync {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: Self.pollInterval, leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    /// Stops taking new sessions (the next hold's may already be starting) and returns the
    /// ones this hold took, so the next hold excludes them.
    func freeze() -> [UUID] {
        queue.sync {
            accepting = false
            poll()
            return sessions
        }
    }

    func stop() -> DictationAudio {
        queue.sync {
            accepting = false
            poll()
            timer?.cancel()
            timer = nil
            if !sessions.isEmpty { samples.append(contentsOf: flush()) }
            try? file?.close()
            file = nil
            return DictationAudio(samples: samples)
        }
    }

    /// Same rule as the Siri drain match: the helper stamps a session when it reads the start
    /// record, which can precede the app's HID Siri-down.
    nonisolated static func accepts(_ header: DictationAudioFile.Header, holdStartedAt: Date,
                                    excluding: Set<UUID>, taken: [UUID]) -> Bool {
        header.startedAt >= holdStartedAt.addingTimeInterval(-RemoteInputHandler.voiceStartClockLeadTolerance)
            && !excluding.contains(header.session) && !taken.contains(header.session)
    }

    private func poll() {
        if accepting, sessions.isEmpty || followsLaterSessions { adoptNewSession() }
        readAvailable()
    }

    private func adoptNewSession() {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { return }
        if let seen = seenFile, seen.device == info.st_dev, seen.inode == info.st_ino { return }
        seenFile = (info.st_dev, info.st_ino)
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { seenFile = nil; return }
        let candidate = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_ino == info.st_ino, opened.st_dev == info.st_dev,
              let headerData = try? candidate.read(upToCount: DictationAudioFile.headerSize),
              let header = DictationAudioFile.Header.decode(headerData) else {
            // A rename can land between lstat and open; look again next poll.
            seenFile = nil
            try? candidate.close()
            return
        }
        guard Self.accepts(header, holdStartedAt: holdStartedAt, excluding: excluded, taken: sessions) else {
            try? candidate.close()
            return
        }
        readAvailable()
        try? file?.close()
        file = candidate
        offset = UInt64(DictationAudioFile.headerSize)
        sessions.append(header.session)
    }

    private func readAvailable() {
        guard let file else { return }
        guard (try? file.seek(toOffset: offset)) != nil,
              let data = try? file.readToEnd(), !data.isEmpty else { return }
        let usable = data.count / DictationAudioFile.bytesPerSample * DictationAudioFile.bytesPerSample
        offset += UInt64(usable)
        let decoded = DictationAudioFile.samples(in: data.prefix(usable))
        let chunk = resample(decoded)
        guard !chunk.isEmpty else { return }
        onSamples?(chunk)
        guard Double(samples.count) < DictationRecorder.maximumDuration * DictationAudio.sampleRate else { return }
        samples.append(contentsOf: chunk)
    }

    private func resample(_ input: [Float]) -> [Float] {
        guard !input.isEmpty, let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(input.count)),
              let channel = buffer.floatChannelData?[0] else { return [] }
        buffer.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: input.count) }
        var supplied = false
        // `.noDataNow` (not end of stream) keeps the resampler's filter state between reads.
        return drain(converter, capacity: AVAudioFrameCount(input.count) / 3 + 64) { status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }

    /// The samples still inside the resampler's filter at the end of the hold.
    private func flush() -> [Float] {
        guard let converter else { return [] }
        return drain(converter, capacity: 1_024) { status in
            status.pointee = .endOfStream
            return nil
        }
    }

    /// One read's output can exceed a single buffer when the filter releases what it held
    /// back last time; anything left in the converter would otherwise be lost.
    private func drain(_ converter: AVAudioConverter, capacity: AVAudioFrameCount,
                       input: @escaping (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?) -> [Float] {
        var result: [Float] = []
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { break }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in input(inputStatus) }
            if error == nil, output.frameLength > 0, let channel = output.floatChannelData?[0] {
                result.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            guard error == nil, status == .haveData, output.frameLength == capacity else { break }
        }
        return result
    }
}
