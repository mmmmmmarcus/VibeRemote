import AVFoundation
import Foundation
import RemoteAudioProtocol

/// Writes each allowed voice session's decoded PCM to `DictationAudioFile` as it decodes, so
/// vvhisper Dictation can transcribe it at protocol end instead of re-recording the virtual
/// device after its output drains. It is fed beside the audio output, never instead of it:
/// mapped dictation keys still follow the output drain, because a third-party dictation app
/// hears only what the device plays.
final class DictationAudioWriter: @unchecked Sendable {
    /// A new remote's end marker can precede its last packet by one BLE interval (16 ms
    /// observed). This is the minimum technical settle; the configured aluminum release
    /// window may hold the file open longer. Glass already applies its buffer in the parser.
    /// Late packets after completion are left out of the file; the output still plays them.
    static let settle: TimeInterval = 0.1
    /// The app reads within milliseconds of completion (or at its own drain deadline), so the
    /// speech does not need to outlive that by much.
    static let retention: TimeInterval = 10

    private let path: String
    private let queue = DispatchQueue(label: "com.vvhisper.dictationAudio")
    private var handle: FileHandle?
    private var header: DictationAudioFile.Header?
    private var writtenSamples = 0
    private var ending = false
    private var settleDelay = DictationAudioWriter.settle
    private var endDeadline: DispatchTime?
    private var revision: UInt64 = 0

    init(path: String) {
        self.path = path
        unlink(path)
        unlink(path + ".new")
    }

    func voiceStarted(settle: TimeInterval = DictationAudioWriter.settle) {
        queue.sync {
            settleDelay = settle
            completeLocked()
            revision &+= 1
            let header = DictationAudioFile.Header(session: UUID(), startedAt: Date())
            let staging = path + ".new"
            unlink(staging)
            let descriptor = open(staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { log("Dictation audio file unavailable: errno \(errno)"); return }
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try file.write(contentsOf: header.encoded())
                guard rename(staging, path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            } catch {
                try? file.close(); unlink(staging)
                log("Dictation audio file unavailable: \(error.localizedDescription)")
                return
            }
            handle = file
            self.header = header
            writtenSamples = 0
            ending = false
            endDeadline = nil
        }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0], buffer.format.sampleRate == DictationAudioFile.sampleRate,
              buffer.format.channelCount == 1 else { return }
        let count = Int(buffer.frameLength)
        queue.sync {
            guard let handle, writtenSamples + count <= DictationAudioFile.maximumSamples else { return }
            var data = Data(capacity: count * DictationAudioFile.bytesPerSample)
            for index in 0..<count {
                withUnsafeBytes(of: channel[index].bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
            do { try handle.write(contentsOf: data); writtenSamples += count }
            catch { log("Dictation audio write failed: \(error.localizedDescription)") }
            if ending { scheduleCompletionLocked() }
        }
    }

    func voiceEnded() {
        queue.sync {
            guard handle != nil else { return }
            ending = true
            endDeadline = .now() + settleDelay
            scheduleCompletionLocked()
        }
    }

    private func scheduleCompletionLocked() {
        revision &+= 1
        let expected = revision
        queue.asyncAfter(deadline: max(.now() + Self.settle, endDeadline ?? .now())) { [weak self] in
            guard let self, self.ending, self.revision == expected else { return }
            self.completeLocked()
        }
    }

    /// Sets the flag after every sample is written, then announces the session. A session the
    /// next start interrupts is completed the same way, so a first-generation tail re-press
    /// can follow it into the new one.
    private func completeLocked() {
        guard let handle, let header else { return }
        self.handle = nil
        self.header = nil
        ending = false
        do {
            try handle.seek(toOffset: DictationAudioFile.completeFlagOffset)
            try handle.write(contentsOf: DictationAudioFile.completeFlag())
        } catch {
            log("Dictation audio completion failed: \(error.localizedDescription)")
        }
        try? handle.close()
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(DictationAudioFile.completeNotification), object: nil,
            userInfo: ["startedAt": header.startedAt.timeIntervalSince1970, "session": header.session.uuidString],
            deliverImmediately: true)
        let expected = revision
        queue.asyncAfter(deadline: .now() + Self.retention) { [weak self] in
            guard let self, self.revision == expected, self.handle == nil else { return }
            unlink(self.path)
        }
    }

    private func log(_ message: String) {
        print("\(Date()) \(message)"); fflush(stdout)
    }
}
