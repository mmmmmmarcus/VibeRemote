import RemoteAudioProtocol
import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

private enum BridgeError: LocalizedError {
    case audioDeviceNotFound
    case audioDeviceQuery(OSStatus)
    case audioDeviceSelection(OSStatus)
    case audioFormat
    case opusConverter
    case opusDecode(String)

    var errorDescription: String? {
        switch self {
        case .audioDeviceNotFound:
            return "No VibeRemote (or BlackHole/Soundflower) virtual audio device was found."
        case .audioDeviceQuery(let status):
            return "Could not enumerate audio devices (OSStatus \(status))."
        case .audioDeviceSelection(let status):
            return "Could not select the virtual audio output (OSStatus \(status))."
        case .audioFormat:
            return "Could not create the Siri Remote audio formats."
        case .opusConverter:
            return "Could not create the system Opus decoder."
        case .opusDecode(let message):
            return "Opus decode failed: \(message)"
        }
    }
}

private func log(_ message: String) {
    print("\(Date()) \(message)")
    fflush(stdout)
}

/// Cross-process signal consumed by the menu-bar app. The old remote keeps flushing audio
/// after its physical Siri button rises, so the mapped dictation key follows this real
/// protocol end marker instead of the earlier button release.
private let voiceEndedNotification = Notification.Name("com.viberemote.voice-ended")

private func audioDeviceName(_ deviceID: AudioDeviceID) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &name) {
        AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
    }
    return status == noErr ? name as String : nil
}

private func preferredOutputDevice() throws -> (AudioDeviceID, String) {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        0,
        nil,
        &size
    )
    guard status == noErr else { throw BridgeError.audioDeviceQuery(status) }

    var devices = Array(
        repeating: AudioDeviceID(),
        count: Int(size) / MemoryLayout<AudioDeviceID>.size
    )
    status = devices.withUnsafeMutableBytes {
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            $0.baseAddress!
        )
    }
    guard status == noErr else { throw BridgeError.audioDeviceQuery(status) }

    // Prefer the VibeRemote driver we install ourselves; the others keep an existing
    // BlackHole/Soundflower setup working. Must stay in sync with the app's device list.
    for expectedName in ["VibeRemote", "BlackHole 2ch", "Soundflower (2ch)"] {
        if let device = devices.first(where: { audioDeviceName($0) == expectedName }) {
            return (device, expectedName)
        }
    }
    throw BridgeError.audioDeviceNotFound
}

private final class OpusDecoder {
    let pcmFormat: AVAudioFormat
    private let sourceFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init() throws {
        var opusDescription = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let sourceFormat = AVAudioFormat(streamDescription: &opusDescription),
              let pcmFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
              ) else {
            throw BridgeError.audioFormat
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: pcmFormat) else {
            throw BridgeError.opusConverter
        }
        self.sourceFormat = sourceFormat
        self.pcmFormat = pcmFormat
        self.converter = converter
    }

    func decode(_ packet: Data) throws -> AVAudioPCMBuffer? {
        guard !packet.isEmpty else { return nil }

        let compressed = AVAudioCompressedBuffer(
            format: sourceFormat,
            packetCapacity: 1,
            maximumPacketSize: packet.count
        )
        compressed.packetCount = 1
        compressed.byteLength = UInt32(packet.count)
        packet.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            memcpy(compressed.data, source, packet.count)
        }
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 960,
            mDataByteSize: UInt32(packet.count)
        )

        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 5_760) else {
            throw BridgeError.audioFormat
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            if supplied {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return compressed
        }
        if status == .error {
            throw BridgeError.opusDecode(conversionError?.localizedDescription ?? "unknown error")
        }
        return output.frameLength > 0 ? output : nil
    }
}

private final class VirtualAudioOutput: VoiceAudioOutput {
    private let delivery = AudioDelivery()
    private let format: AVAudioFormat
    /// Guards `engine`/`player`, which the rebuild path replaces wholesale while the read
    /// loop is enqueueing into them.
    private let lock = NSLock()
    /// Rebuilds run here so a burst of audio-hardware changes cannot overlap, and so the
    /// retry backoff never blocks the decode loop.
    private let controlQueue = DispatchQueue(label: "com.viberemote.voicebridge.audioControl")
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var rebuildInFlight = false
    /// Starting an engine is itself an audio-hardware configuration change, so a rebuild
    /// re-posts the very notification that triggered it. Without this quiet window the
    /// handler feeds itself and rebuilds dozens of times per second.
    private var quietUntil = Date.distantPast
    /// Liveness probe for the case the notification cannot cover: an engine that reports
    /// `isRunning` but has stopped advancing its render clock is not rendering anything.
    private var lastRenderSampleTime: AVAudioFramePosition = -1
    private var stalledEnqueues = 0
    private var configurationObserver: NSObjectProtocol?

    init(format: AVAudioFormat) throws {
        self.format = format
        lock.lock()
        defer { lock.unlock() }
        try buildLocked()
        // AVAudioEngine stops itself whenever the audio hardware is reconfigured, and a
        // Bluetooth headset connecting or disconnecting is exactly that: it adds or removes
        // CoreAudio devices. Nothing restarts the engine on its own, and the failure is
        // completely silent — scheduleBuffer keeps accepting buffers, player.isPlaying keeps
        // reporting true, and the decode counter keeps climbing while nothing is rendered
        // into the virtual device. Rebuilding on this notification is mandatory for an
        // engine that is meant to stay warm for the whole session.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        lock.lock()
        let selfInflicted = rebuildInFlight || Date() < quietUntil
        let running = engine.isRunning
        lock.unlock()
        guard !selfInflicted else { return }
        // A configuration change that did not stop the engine needs no rebuild; the stall
        // probe in `enqueue` still covers an engine that keeps running without rendering.
        guard !running else { return }
        rebuild(reason: "the audio hardware was reconfigured")
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// Tune only our own virtual device. The host's default 512-frame quantum adds
    /// several render cycles between receiving a packet and delivering it to dictation.
    /// Unsupported requests keep the existing setting; never alter a fallback or headset.
    private func configureBuffer(deviceID: AudioDeviceID, deviceName: String) {
        guard deviceName == "VibeRemote" else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var current: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &current) == noErr else { return }
        guard current > 128 else {
            log("Output buffer frames: \(current)")
            return
        }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, settable.boolValue else { return }
        var requested: UInt32 = 128
        let result = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &requested)
        var actual = current
        _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &actual)
        log("Output buffer frames: \(current) -> \(actual), requestStatus=\(result)")
    }

    /// Builds a fresh engine pinned to the virtual device. The device is re-resolved by name
    /// every time, because a CoreAudio reconfiguration can hand the same device a new ID.
    private func buildLocked() throws {
        let (deviceID, deviceName) = try preferredOutputDevice()
        configureBuffer(deviceID: deviceID, deviceName: deviceName)
        let newEngine = AVAudioEngine()
        try newEngine.outputNode.withAudioUnit { audioUnit in
            guard let audioUnit else { throw BridgeError.audioFormat }
            var selectedDevice = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &selectedDevice,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw BridgeError.audioDeviceSelection(status) }
        }

        let newPlayer = AVAudioPlayerNode()
        newEngine.attach(newPlayer)
        try newEngine.connectNode(newPlayer, to: newEngine.mainMixerNode, format: format)
        newPlayer.volume = 0.75
        try newEngine.start()
        // Keep the player node running for the lifetime of the bridge ("keep stream
        // warm"). The Siri Remote firmware already gates the microphone to physical
        // button holds, so leaving the node warm only removes per-press start-up
        // latency; it never stops between sessions and thus can never deadlock on a
        // stop issued from a scheduleBuffer completion callback.
        try newPlayer.playAudio()

        let previousEngine = engine
        engine = newEngine
        player = newPlayer
        // Only the engine is stopped, never the outgoing player node: stopping a player is
        // the documented deadlock in this file, and stopping its engine already tears the
        // node down. Buffers still scheduled on the old node are abandoned by design.
        delivery.interrupt()
        previousEngine.stop()
        lastRenderSampleTime = -1
        stalledEnqueues = 0
        quietUntil = Date().addingTimeInterval(1.5)
        log("Output device set to: \(deviceName)")
    }

    /// Rebuilds off the caller's thread, retrying because the virtual device can be briefly
    /// absent while CoreAudio settles after a device is added or removed.
    private func rebuild(reason: String) {
        lock.lock()
        if rebuildInFlight {
            lock.unlock()
            return
        }
        rebuildInFlight = true
        lock.unlock()

        controlQueue.async { [weak self] in
            guard let self else { return }
            var rebuilt = false
            for attempt in 1...5 {
                self.lock.lock()
                do {
                    try self.buildLocked()
                    rebuilt = true
                } catch {
                    log("Audio engine rebuild attempt \(attempt) failed: \(error.localizedDescription)")
                }
                self.lock.unlock()
                if rebuilt { break }
                Thread.sleep(forTimeInterval: 0.5)
            }
            self.lock.lock()
            self.rebuildInFlight = false
            self.lock.unlock()
            log(rebuilt
                ? "Audio engine rebuilt after \(reason)"
                : "Audio engine could not be rebuilt after \(reason); the bridge is silent")
        }
    }

    func voiceStarted() {
        delivery.begin()
        restartIfStopped()
    }

    func enqueue(_ buffer: AVAudioPCMBuffer, traceFirstPacket: Bool = false, captureTime: Date? = nil) {
        lock.lock()
        let engine = self.engine
        let player = self.player
        lock.unlock()

        // Backstop for any reconfiguration that does not post the notification. Dropping the
        // frames decoded during a rebuild costs 20 ms each and beats scheduling them into an
        // engine that will never render them.
        guard engine.isRunning else {
            delivery.interrupt()
            rebuild(reason: "the audio engine was found stopped")
            return
        }
        if !player.isPlaying {
            do { try player.playAudio() }
            catch {
                delivery.interrupt()
                rebuild(reason: "the audio player could not resume")
                return
            }
        }
        if stalledRenderClock(of: player) {
            delivery.interrupt()
            rebuild(reason: "the audio engine stopped advancing its render clock")
            return
        }
        let submitted = Date(), token = delivery.submit(), delivery = self.delivery
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            delivery.complete(token)
            if traceFirstPacket {
                log("Latency first PCM played enqueueToPlayedMs=\(String(format: "%.1f", Date().timeIntervalSince(submitted) * 1000))")
            }
        }
    }

    func voiceEnded() { delivery.end() }

    /// True once half a second of frames have been handed to a player whose render clock has
    /// not moved. One frame is 20 ms, so this tolerates ordinary jitter and still reacts well
    /// inside a single button hold.
    private func stalledRenderClock(of player: AVAudioPlayerNode) -> Bool {
        guard let renderTime = player.lastRenderTime, renderTime.isSampleTimeValid else {
            return false
        }
        lock.lock()
        defer { lock.unlock() }
        if renderTime.sampleTime != lastRenderSampleTime {
            lastRenderSampleTime = renderTime.sampleTime
            stalledEnqueues = 0
            return false
        }
        stalledEnqueues += 1
        return stalledEnqueues >= 25
    }

    private func restartIfStopped() {
        lock.lock()
        let engine = self.engine
        let player = self.player
        lock.unlock()
        guard engine.isRunning else {
            delivery.interrupt()
            rebuild(reason: "the audio engine was found stopped")
            return
        }
        if !player.isPlaying {
            do { try player.playAudio() }
            catch {
                delivery.interrupt()
                rebuild(reason: "the audio player could not resume")
            }
        }
    }
}

/// PacketLogger prefixes each record with "MMM d HH:mm:ss.SSS". Returns nil when the
/// line does not carry a parseable capture timestamp.
private let captureTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "MMM d HH:mm:ss.SSS yyyy"
    return formatter
}()

private func captureLineTimestamp(_ line: String, year: Int) -> Date? {
    let parts = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
    guard parts.count >= 3 else { return nil }
    return captureTimestampFormatter.date(from: "\(parts[0]) \(parts[1]) \(parts[2]) \(year)")
}

// Offline validation reads capture text from stdin without opening an audio device.
let validateCapture = CommandLine.arguments.contains("--validate-capture")
let suppressionFile: String? = CommandLine.arguments.firstIndex(of: "--voice-suppression-file").flatMap {
    CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil
}

do {
    let decoder = try OpusDecoder()
    let audioOutput: (any VoiceAudioOutput)?
    if validateCapture { audioOutput = nil }
    else if CommandLine.arguments.contains("--shared-audio") {
        do { audioOutput = try SharedAudioOutput() }
        catch {
            log("Shared HAL unavailable: \(error.localizedDescription); using compatibility output")
            audioOutput = try VirtualAudioOutput(format: decoder.pcmFormat)
        }
    } else { audioOutput = try VirtualAudioOutput(format: decoder.pcmFormat) }
    let settledOutput = audioOutput.map { SettlingAudioOutput($0) }
    var maximumPeak: Float = 0
    var parser = SiriRemotePacketParser()
    var decodedPackets = 0
    var directHIDReports = 0
    var traceFirstPacket = true
    var voiceSessionGate = VoiceSessionGate()

    // PacketLogger replays the Bluetooth stack's buffered history when a capture starts,
    // which would re-decode the previous voice session into the output device. Skip
    // records older than helper launch until the first live record arrives.
    let staleCutoff = Date().addingTimeInterval(-1.5)
    let captureYear = Calendar.current.component(.year, from: Date())
    var reachedLiveCapture = validateCapture
    var skippedReplayLines = 0

    while let line = readLine(strippingNewline: true) {
        if !reachedLiveCapture, !line.hasPrefix("HID REPORT ") {
            if let timestamp = captureLineTimestamp(line, year: captureYear),
               timestamp < staleCutoff {
                skippedReplayLines += 1
                continue
            }
            reachedLiveCapture = true
            if skippedReplayLines > 0 {
                log("Skipped \(skippedReplayLines) buffered capture lines from before launch")
            }
        }
        if line.hasPrefix("HID REPORT ") {
            directHIDReports += 1
            if directHIDReports == 1 || directHIDReports % 50 == 0 {
                log("Direct HID reports received: \(directHIDReports)")
            }
        }
        let events = parser.events(from: line)
        guard !events.isEmpty else { continue }
        // Suppression can affect output only when the parser produced a voice event.
        // Reading this file for every unrelated HCI record kept the idle helper busy.
        // Checking it here preserves the same per-event gate and buffered-tail behavior.
        let voiceBlocked = suppressionFile.map { (try? String(contentsOfFile: $0, encoding: .utf8)) != "enabled" } ?? false
        voiceSessionGate.update(blocked: voiceBlocked)
        for event in events {
            switch event {
            case .started:
                voiceSessionGate.started(blocked: voiceBlocked)
                guard voiceSessionGate.allowsPackets else { continue }
                traceFirstPacket = true
                let received = Date()
                let age = captureLineTimestamp(line, year: captureYear).map { String(format: "%.1f", received.timeIntervalSince($0) * 1000) } ?? "unknown"
                log("Latency voice start epoch=\(String(format: "%.6f", received.timeIntervalSince1970)) captureAgeMs=\(age)")
                settledOutput?.voiceStarted()
                log("Voice started")
            case .packet(let packet):
                guard voiceSessionGate.allowsPackets else { continue }
                do {
                    if let buffer = try decoder.decode(packet) {
                        if validateCapture, let samples = buffer.floatChannelData?[0] {
                            for index in 0..<Int(buffer.frameLength) {
                                maximumPeak = max(maximumPeak, abs(samples[index]))
                            }
                        }
                        settledOutput?.enqueue(buffer, traceFirstPacket: traceFirstPacket,
                                             captureTime: traceFirstPacket ? captureLineTimestamp(line, year: captureYear) : nil)
                        traceFirstPacket = false
                        decodedPackets += 1
                        if decodedPackets == 1 || decodedPackets % 50 == 0 {
                            log("Decoded audio packets: \(decodedPackets)")
                        }
                    }
                } catch {
                    log("Error: \(error.localizedDescription)")
                }
            case .ended:
                guard voiceSessionGate.allowsPackets else { continue }
                let received = Date()
                let age = captureLineTimestamp(line, year: captureYear).map {
                    String(format: "%.1f", received.timeIntervalSince($0) * 1000)
                } ?? "unknown"
                log("Latency voice end epoch=\(String(format: "%.6f", received.timeIntervalSince1970)) captureAgeMs=\(age)")
                if !validateCapture {
                    DistributedNotificationCenter.default().postNotificationName(
                        voiceEndedNotification,
                        object: nil,
                        userInfo: nil,
                        deliverImmediately: true
                    )
                }
                log("Voice protocol ended; draining queued audio")
                settledOutput?.voiceEnded()
            }
        }
    }
    if validateCapture { log("Capture validation: packets=\(decodedPackets) peak=\(maximumPeak)") }
} catch {
    log("Fatal error: \(error.localizedDescription)")
    exit(EXIT_FAILURE)
}
