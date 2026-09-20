import Foundation
import AVFoundation
import SharedAudio

protocol VoiceAudioOutput: AnyObject {
    func voiceStarted()
    func enqueue(_ buffer: AVAudioPCMBuffer, traceFirstPacket: Bool, captureTime: Date?)
    func voiceEnded()
}

/// A protocol end marker can precede the last audio frame. Serialize output calls
/// and allow that short tail to arrive before snapshotting the final drain target.
final class SettlingAudioOutput: VoiceAudioOutput, @unchecked Sendable {
    private let output: any VoiceAudioOutput
    private let queue = DispatchQueue(label: "com.viberemote.voiceSession")
    private var ending = false
    private var revision: UInt64 = 0
    init(_ output: any VoiceAudioOutput) { self.output = output }
    func voiceStarted() {
        queue.sync { revision &+= 1; ending = false; output.voiceStarted() }
    }
    func enqueue(_ buffer: AVAudioPCMBuffer, traceFirstPacket: Bool, captureTime: Date?) {
        queue.sync {
            output.enqueue(buffer, traceFirstPacket: traceFirstPacket, captureTime: captureTime)
            if ending { scheduleEnd() }
        }
    }
    func voiceEnded() { queue.sync { ending = true; scheduleEnd() } }
    private func scheduleEnd() {
        revision &+= 1
        let expected = revision
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.ending, self.revision == expected else { return }
            self.ending = false
            self.output.voiceEnded()
        }
    }
}

/// Completion callbacks can race protocol events, so all session state is locked.
/// A completion from an older hold can never complete a new hold.
final class AudioDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var session = UUID()
    private var startedAt = Date.distantPast
    private var pending = 0
    private var ended = false
    private var failed = false
    private var reported = false
    func begin() {
        lock.lock(); defer { lock.unlock() }
        session = UUID(); startedAt = Date(); pending = 0
        ended = false; failed = false; reported = false
    }
    func submit() -> UUID {
        lock.lock(); defer { lock.unlock() }
        pending += 1; return session
    }
    func complete(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard token == session else { return }
        pending = max(0, pending - 1); reportIfComplete()
    }
    func interrupt() {
        lock.lock(); defer { lock.unlock() }
        failed = true
    }
    func end() {
        lock.lock()
        ended = true; let token = session
        reportIfComplete(); lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard token == self.session, !self.reported else { return }
            self.reported = true; self.failed = true
            print("\(Date()) Voice drain timed out/interrupted; pending=\(self.pending)"); fflush(stdout)
        }
    }
    private func reportIfComplete() {
        guard ended, pending == 0, !failed, !reported else { return }
        reported = true
        print("\(Date()) Voice buffer drained session=\(session)"); fflush(stdout)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.viberemote.voice-drained"), object: nil,
            userInfo: ["startedAt": startedAt.timeIntervalSince1970, "session": session.uuidString],
            deliverImmediately: true)
    }
}

/// No AVAudioEngine or virtual output stream: the HAL input callback consumes these frames.
final class SharedAudioOutput: VoiceAudioOutput, @unchecked Sendable {
    private let handle: OpaquePointer
    private let queue = DispatchQueue(label: "com.viberemote.sharedAudio")
    private let timer: DispatchSourceTimer
    private let delivery = AudioDelivery()
    // Enqueue happens on the stdin decode thread. Shared ring counters are C atomics.
    private var epoch: UInt64 = 0
    init() throws {
        guard let handle = vr_audio_open(getuid(), 1) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        self.handle = handle
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }; vr_audio_heartbeat(self.handle)
        }
        timer.resume()
        print("Audio output: shared-memory HAL, 48000 Hz mono"); fflush(stdout)
    }
    deinit { timer.cancel(); vr_audio_close(handle) }
    func voiceStarted() {
        queue.sync { epoch &+= 1 }
        delivery.begin(); vr_audio_begin(handle)
    }
    func enqueue(_ buffer: AVAudioPCMBuffer, traceFirstPacket: Bool, captureTime: Date?) {
        guard let samples = buffer.floatChannelData?[0], buffer.format.sampleRate == 48000 else {
            delivery.interrupt(); return
        }
        if vr_audio_written(handle) + UInt64(buffer.frameLength) - vr_audio_consumed(handle) > 96000 {
            delivery.interrupt()
        }
        _ = vr_audio_write(handle, samples, buffer.frameLength)
        if traceFirstPacket { print("\(Date()) First PCM written to HAL ring frames=\(buffer.frameLength)"); fflush(stdout) }
    }
    func voiceEnded() {
        let target = vr_audio_written(handle), token = delivery.submit()
        let generation = queue.sync { epoch }
        delivery.end()
        queue.async { [weak self] in self?.waitForDrain(target: target, token: token, generation: generation, deadline: .now() + 3) }
    }
    private func waitForDrain(target: UInt64, token: UUID, generation: UInt64, deadline: DispatchTime) {
        guard generation == epoch else { return }
        if vr_audio_consumed(handle) >= target { delivery.complete(token); return }
        guard DispatchTime.now() < deadline else { return }
        queue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.waitForDrain(target: target, token: token, generation: generation, deadline: deadline)
        }
    }
}
