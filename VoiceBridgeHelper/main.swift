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

private final class VirtualAudioOutput {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    init(format: AVAudioFormat) throws {
        let (deviceID, deviceName) = try preferredOutputDevice()
        let outputNode = engine.outputNode
        guard let audioUnit = outputNode.audioUnit else {
            throw BridgeError.audioFormat
        }
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

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.volume = 0.75
        try engine.start()
        // Keep the player node running for the lifetime of the bridge ("keep stream
        // warm"). The Siri Remote firmware already gates the microphone to physical
        // button holds, so leaving the node warm only removes per-press start-up
        // latency; it never stops between sessions and thus can never deadlock on a
        // stop issued from a scheduleBuffer completion callback.
        player.play()
        log("Output device set to: \(deviceName)")
    }

    func voiceStarted() {
        if !player.isPlaying {
            player.play()
        }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        if !player.isPlaying {
            player.play()
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: nil)
    }

    func voiceEnded() {
        // The output stream stays warm between voice sessions; nothing to tear down.
    }
}

private struct PendingL2CAPPacket {
    let expectedLength: Int
    var bytes: [UInt8]
}

private enum VoiceEvent {
    case started
    case packet(Data)
    case ended
}

private struct SiriRemotePacketParser {
    private var pendingByHandle: [UInt16: PendingL2CAPPacket] = [:]
    private var oldFrame: [UInt8] = []
    private var oldVoiceActive = false
    private var newVoiceActive = false
    private var directVoiceActive = false
    private var lastLine: String?

    mutating func events(from line: String) -> [VoiceEvent] {
        // PacketLogger can occasionally repeat an identical rendered record. Feeding
        // duplicates to the stateful Opus decoder produces stutter and buffer growth.
        guard line != lastLine else { return [] }
        lastLine = line

        if line.hasPrefix("HID REPORT ") {
            return directHIDEvents(from: line)
        }

        guard let marker = line.range(of: " RECV ") else { return [] }
        let bytes = line[marker.upperBound...]
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { UInt8($0, radix: 16) }
        guard bytes.count >= 4 else { return [] }

        var output = oldProtocolEvents(from: bytes)
        output.append(contentsOf: l2capEvents(from: bytes))
        return output
    }

    private mutating func directHIDEvents(from line: String) -> [VoiceEvent] {
        guard let marker = line.range(of: " data=") else { return [] }
        var bytes = line[marker.upperBound...]
            .split(whereSeparator: { $0.isWhitespace })
            .compactMap { UInt8($0, radix: 16) }
        guard !bytes.isEmpty else { return [] }

        // macOS may include its synthetic 0xFF report ID in the callback buffer. The Gen-3
        // microphone payload itself is exactly 99 bytes, so remove only that unambiguous prefix.
        if bytes.count == 100, bytes.first == 0xFF {
            bytes.removeFirst()
        }

        // Gen-3 direct HID microphone layout (99 bytes): two prefix bytes, a little-endian
        // sequence, one Opus length byte, the Opus packet, then zero padding. A zero-length
        // report is the button-release sentinel.
        if bytes.count == 99 {
            let packetLength = Int(bytes[4])
            if packetLength == 0 {
                guard directVoiceActive else { return [] }
                directVoiceActive = false
                return [.ended]
            }
            guard packetLength <= 94, 5 + packetLength <= bytes.count else { return [] }
            let packet = Data(bytes[5..<(5 + packetLength)])
            guard packet.contains(where: { $0 != 0 }) else { return [] }
            var output: [VoiceEvent] = []
            if !directVoiceActive {
                directVoiceActive = true
                output.append(.started)
            }
            output.append(.packet(packet))
            return output
        }

        // Retain the old PacketLogger-era encapsulation parser as a compatibility fallback for
        // earlier remote generations that expose 1B 35 / 1B 39 inside their buffered report.
        var output: [VoiceEvent] = []
        var offset = 0
        while offset + 1 < bytes.count {
            guard bytes[offset] == 0x1B else {
                offset += 1
                continue
            }
            switch bytes[offset + 1] {
            case 0x35:
                guard offset + 7 < bytes.count else { return output }
                let packetLength = Int(bytes[offset + 7])
                let end = offset + 8 + packetLength
                guard packetLength > 0, end <= bytes.count else {
                    offset += 2
                    continue
                }
                output.append(contentsOf: events(fromL2CAPPayload: Array(bytes[offset..<end])))
                offset = end
            case 0x39:
                output.append(contentsOf: events(fromL2CAPPayload: [0x1B, 0x39]))
                offset += 2
            default:
                offset += 2
            }
        }
        return output
    }

    private mutating func oldProtocolEvents(from bytes: [UInt8]) -> [VoiceEvent] {
        let oldStart: [UInt8] = [0x1B, 0x23, 0x00, 0x00, 0x10]
        let oldEnd: [UInt8] = [0x1B, 0x23, 0x00, 0x10, 0x00]
        if bytes.suffix(oldStart.count).elementsEqual(oldStart) {
            oldFrame.removeAll(keepingCapacity: true)
            oldVoiceActive = true
            return [.started]
        }
        if bytes.suffix(oldEnd.count).elementsEqual(oldEnd) {
            var events: [VoiceEvent] = []
            if let packet = validatedOldFrame() {
                events.append(.packet(packet))
            }
            oldFrame.removeAll(keepingCapacity: true)
            if oldVoiceActive { events.append(.ended) }
            oldVoiceActive = false
            return events
        }
        guard oldVoiceActive, bytes.count == 31 else { return [] }

        if bytes[0] == 0x40, bytes[1] == 0x20, bytes[18] == 0xB8 {
            var events: [VoiceEvent] = []
            if let packet = validatedOldFrame() {
                events.append(.packet(packet))
            }
            oldFrame = Array(bytes[17...])
            return events
        }
        guard !oldFrame.isEmpty, bytes[1] == 0x10 else { return [] }
        oldFrame.append(contentsOf: bytes.dropFirst(4))
        return []
    }

    private func validatedOldFrame() -> Data? {
        guard let packetLength = oldFrame.first.map(Int.init),
              packetLength > 0,
              oldFrame.count >= packetLength + 1 else {
            return nil
        }
        return Data(oldFrame[1..<(packetLength + 1)])
    }

    private mutating func l2capEvents(from bytes: [UInt8]) -> [VoiceEvent] {
        let handle = UInt16(bytes[0]) | (UInt16(bytes[1] & 0x0F) << 8)
        let packetBoundaryFlag = (bytes[1] >> 4) & 0x03
        let aclPayloadLength = Int(UInt16(bytes[2]) | (UInt16(bytes[3]) << 8))
        let availableEnd = min(bytes.count, 4 + aclPayloadLength)
        guard availableEnd >= 4 else { return [] }

        if packetBoundaryFlag == 0x02 {
            guard availableEnd >= 8 else { return [] }
            let l2capLength = Int(UInt16(bytes[4]) | (UInt16(bytes[5]) << 8))
            guard l2capLength > 0 else { return [] }
            let payload = Array(bytes[8..<availableEnd])
            if payload.count >= l2capLength {
                pendingByHandle.removeValue(forKey: handle)
                return events(fromL2CAPPayload: Array(payload.prefix(l2capLength)))
            }
            pendingByHandle[handle] = PendingL2CAPPacket(
                expectedLength: l2capLength,
                bytes: payload
            )
            return []
        }

        if packetBoundaryFlag == 0x01, var pending = pendingByHandle[handle] {
            pending.bytes.append(contentsOf: bytes[4..<availableEnd])
            if pending.bytes.count >= pending.expectedLength {
                pendingByHandle.removeValue(forKey: handle)
                return events(
                    fromL2CAPPayload: Array(pending.bytes.prefix(pending.expectedLength))
                )
            }
            pendingByHandle[handle] = pending
        }
        return []
    }

    private mutating func events(fromL2CAPPayload bytes: [UInt8]) -> [VoiceEvent] {
        guard bytes.count >= 2, bytes[0] == 0x1B else { return [] }
        switch bytes[1] {
        case 0x35:
            guard bytes.count >= 8 else { return [] }
            let packetLength = Int(bytes[7])
            guard packetLength > 0, bytes.count >= 8 + packetLength else { return [] }
            let packet = Data(bytes[8..<(8 + packetLength)])
            guard packet.contains(where: { $0 != 0 }) else { return [] }
            var events: [VoiceEvent] = []
            if !newVoiceActive {
                newVoiceActive = true
                events.append(.started)
            }
            events.append(.packet(packet))
            return events
        case 0x39:
            guard newVoiceActive else { return [] }
            newVoiceActive = false
            return [.ended]
        default:
            return []
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

do {
    let decoder = try OpusDecoder()
    let audioOutput = try VirtualAudioOutput(format: decoder.pcmFormat)
    var parser = SiriRemotePacketParser()
    var decodedPackets = 0
    var directHIDReports = 0

    // PacketLogger replays the Bluetooth stack's buffered history when a capture starts,
    // which would re-decode the previous voice session into the output device. Skip
    // records older than helper launch until the first live record arrives.
    let staleCutoff = Date().addingTimeInterval(-1.5)
    let captureYear = Calendar.current.component(.year, from: Date())
    var reachedLiveCapture = false
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
        for event in parser.events(from: line) {
            switch event {
            case .started:
                audioOutput.voiceStarted()
                log("Voice started")
            case .packet(let packet):
                do {
                    if let buffer = try decoder.decode(packet) {
                        audioOutput.enqueue(buffer)
                        decodedPackets += 1
                        if decodedPackets == 1 || decodedPackets % 50 == 0 {
                            log("Decoded audio packets: \(decodedPackets)")
                        }
                    }
                } catch {
                    log("Error: \(error.localizedDescription)")
                }
            case .ended:
                audioOutput.voiceEnded()
                log("Voice ended")
            }
        }
    }
} catch {
    log("Fatal error: \(error.localizedDescription)")
    exit(EXIT_FAILURE)
}
