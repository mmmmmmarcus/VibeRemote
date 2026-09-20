import Foundation

private struct PendingL2CAPPacket {
    let expectedLength: Int
    var bytes: [UInt8]
}

public enum VoiceEvent: Equatable {
    case started
    case packet(Data)
    case ended
}

public struct SiriRemotePacketParser {
    public init() {}
    private var pendingByHandle: [UInt16: PendingL2CAPPacket] = [:]
    private var oldVoiceHandles: Set<UInt16> = []
    private struct NewVoiceSession {
        var sequence: UInt16
        var endedAt: TimeInterval?
    }
    private var newVoiceSessions: [UInt16: NewVoiceSession] = [:]
    private var receivedAt: TimeInterval = 0
    private var directVoiceActive = false
    private var lastSniffedPacketAt: Date?
    private var lastLine: String?

    /// Frames arrive every 20 ms while the microphone is live; a gap this long means the
    /// 1st-gen remote's voice session is over.
    private static let sniffedVoiceIdleTimeout: TimeInterval = 0.75

    public mutating func events(from line: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> [VoiceEvent] {
        receivedAt = now
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

        return l2capEvents(from: bytes)
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
        if !output.isEmpty { return output }

        // 1st-gen remote. It predates the dedicated audio collection, so its voice frames are
        // sniffed off whichever ordinary interface carries them and arrive without the Gen-3
        // header: just a length byte followed by the Opus packet, optionally behind a report
        // ID. The framing is confirmed from the Opus TOC byte rather than assumed, so button
        // reports on the same interface cannot be mistaken for audio.
        return lengthPrefixedEvents(from: bytes)
    }

    /// Decode a bare `[length][Opus…]` frame, trying both a leading report-ID byte and none.
    private mutating func lengthPrefixedEvents(from bytes: [UInt8]) -> [VoiceEvent] {
        for prefix in 0...1 {
            guard bytes.count > prefix + 1 else { continue }
            let frame = Array(bytes[prefix...])
            let packetLength = Int(frame[0])
            guard packetLength > 0, packetLength + 1 <= frame.count else { continue }
            let packet = Array(frame[1...packetLength])
            guard Self.isPlausibleSiriRemoteOpusPacket(packet) else { continue }

            var output: [VoiceEvent] = []
            let now = Date()
            // The 1st-gen remote has no end-of-voice report, so a gap in the 20 ms frame
            // cadence is what ends a session. Only the logging depends on this: the output
            // stream stays warm either way.
            if let last = lastSniffedPacketAt,
               now.timeIntervalSince(last) > Self.sniffedVoiceIdleTimeout,
               directVoiceActive {
                directVoiceActive = false
                output.append(.ended)
            }
            lastSniffedPacketAt = now
            if !directVoiceActive {
                directVoiceActive = true
                output.append(.started)
            }
            output.append(.packet(Data(packet)))
            return output
        }
        return []
    }

    /// Both Siri Remote generations encode voice as CELT-only, single-frame Opus packets
    /// (config 16–31, frame-count code 0; 0xB8 — CELT wideband, 20 ms — observed on each).
    /// Requiring that shape is what makes sniffing safe on an interface that also has buttons.
    static func isPlausibleSiriRemoteOpusPacket(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2, let toc = bytes.first else { return false }
        guard toc >> 3 >= 16, toc & 0x03 == 0 else { return false }
        return bytes.contains { $0 != 0 }
    }

    /// Old remotes use ATT handle 0x0023. Parse complete L2CAP payloads rather than
    /// hardcoding the ACL connection handle or assuming 27-byte Bluetooth fragments.
    private mutating func oldProtocolEvents(from bytes: [UInt8], handle: UInt16) -> [VoiceEvent] {
        if bytes == [0x1B, 0x23, 0x00, 0x00, 0x10] {
            return oldVoiceHandles.insert(handle).inserted ? [.started] : []
        }
        if bytes == [0x1B, 0x23, 0x00, 0x10, 0x00] {
            return oldVoiceHandles.remove(handle) != nil ? [.ended] : []
        }
        guard oldVoiceHandles.contains(handle), bytes.count > 10,
              bytes.prefix(3).elementsEqual([0x1B, 0x23, 0x00]) else { return [] }
        let length = Int(bytes[9])
        guard length > 0, bytes.count >= 10 + length else { return [] }
        let packet = Array(bytes[10..<(10 + length)])
        guard Self.isPlausibleSiriRemoteOpusPacket(packet) else { return [] }
        return [.packet(Data(packet))]
    }

    private mutating func l2capEvents(from bytes: [UInt8]) -> [VoiceEvent] {
        let handle = UInt16(bytes[0]) | (UInt16(bytes[1] & 0x0F) << 8)
        let packetBoundaryFlag = (bytes[1] >> 4) & 0x03
        let aclPayloadLength = Int(UInt16(bytes[2]) | (UInt16(bytes[3]) << 8))
        guard bytes.count >= 4 + aclPayloadLength else { return [] }
        let availableEnd = 4 + aclPayloadLength
        guard availableEnd >= 4 else { return [] }

        if packetBoundaryFlag == 0x02 {
            pendingByHandle.removeValue(forKey: handle)
            guard availableEnd >= 8, bytes[6] == 0x04, bytes[7] == 0 else { return [] }
            let l2capLength = Int(UInt16(bytes[4]) | (UInt16(bytes[5]) << 8))
            guard l2capLength > 0 else { return [] }
            let payload = Array(bytes[8..<availableEnd])
            if payload.count >= l2capLength {
                pendingByHandle.removeValue(forKey: handle)
                return events(fromL2CAPPayload: Array(payload.prefix(l2capLength)), handle: handle)
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
                    fromL2CAPPayload: Array(pending.bytes.prefix(pending.expectedLength)), handle: handle
                )
            }
            pendingByHandle[handle] = pending
        }
        return []
    }

    private mutating func events(fromL2CAPPayload bytes: [UInt8], handle: UInt16 = .max) -> [VoiceEvent] {
        guard bytes.count >= 2, bytes[0] == 0x1B else { return [] }
        switch bytes[1] {
        case 0x23:
            return oldProtocolEvents(from: bytes, handle: handle)
        case 0x35:
            guard bytes.count >= 8 else { return [] }
            let packetLength = Int(bytes[7])
            guard packetLength > 0, bytes.count >= 8 + packetLength else { return [] }
            let packet = Data(bytes[8..<(8 + packetLength)])
            guard packet.contains(where: { $0 != 0 }) else { return [] }
            var events: [VoiceEvent] = []
            let sequence = UInt16(bytes[5]) | UInt16(bytes[6]) << 8
            if let previous = newVoiceSessions[handle], let endedAt = previous.endedAt,
               receivedAt - endedAt <= 0.25, sequence == previous.sequence &+ 1 {
                // Real capture: 1B 39 can precede the final 1B 35 by one BLE interval.
                // Preserve that tail in the old buffer; do not reset the HAL ring/session.
                newVoiceSessions[handle]?.sequence = sequence
                return [.packet(packet)]
            }
            if newVoiceSessions[handle] == nil || newVoiceSessions[handle]?.endedAt != nil {
                events.append(.started)
            }
            newVoiceSessions[handle] = NewVoiceSession(sequence: sequence, endedAt: nil)
            events.append(.packet(packet))
            return events
        case 0x39:
            guard newVoiceSessions[handle] != nil, newVoiceSessions[handle]?.endedAt == nil else { return [] }
            newVoiceSessions[handle]?.endedAt = receivedAt
            return [.ended]
        default:
            return []
        }
    }
}
