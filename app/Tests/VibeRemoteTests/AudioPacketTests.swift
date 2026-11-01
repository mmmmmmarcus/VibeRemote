import Foundation
import XCTest
@testable import RemoteAudioProtocol

final class AudioPacketTests: XCTestCase {
    private func records(_ payload: [UInt8], handle: UInt16, fragmentSize: Int = 27) -> [String] {
        let l2cap = [UInt8(payload.count & 255), UInt8(payload.count >> 8), 4, 0] + payload
        return stride(from: 0, to: l2cap.count, by: fragmentSize).map { offset in
            let part = Array(l2cap[offset..<min(offset + fragmentSize, l2cap.count)])
            let bytes = [UInt8(handle & 255), UInt8(handle >> 8) | (offset == 0 ? 0x20 : 0x10), UInt8(part.count), 0] + part
            return "test RECV " + bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        }
    }

    func testNewRemoteTrailingPacketDoesNotStartAnotherVoiceSession() {
        var parser = SiriRemotePacketParser()
        func feed(_ payload: [UInt8], at time: TimeInterval, handle: UInt16 = 0x4E) -> [VoiceEvent] {
            records(payload, handle: handle).flatMap { parser.events(from: $0, now: time) }
        }
        let packet = Data([0xB8, 1, 2, 3])
        func frame(_ sequence: UInt8) -> [UInt8] { [0x1B, 0x35, 0, 0, 0, sequence, 0, 4] + Array(packet) }
        XCTAssertEqual(feed(frame(57), at: 1), [.started, .packet(packet)])
        XCTAssertEqual(feed([0x1B, 0x39, 0, 0, 0], at: 1.1), [.ended])
        XCTAssertEqual(feed(frame(58), at: 1.116), [.packet(packet)])
        XCTAssertEqual(feed(frame(59), at: 1.132), [.packet(packet)])
        // A different handle must not be swallowed as the first remote's tail.
        XCTAssertEqual(feed(frame(60), at: 1.14, handle: 0x4F), [.started, .packet(packet)])
        // A reset counter identifies a real, rapid second press.
        XCTAssertEqual(feed(frame(0), at: 1.15), [.started, .packet(packet)])
        XCTAssertEqual(feed([0x1B, 0x39, 0, 0, 0], at: 1.2), [.ended])
        // Even a consecutive counter is a new session after the tail window expires.
        XCTAssertEqual(feed(frame(1), at: 2), [.started, .packet(packet)])
    }

    func testOldRemoteAudioUsesDynamicConnectionHandleAndReassembledPayload() {
        let packet: [UInt8] = [0xB8] + Array(1...66)
        let frame: [UInt8] = [0x1B, 0x23, 0, 1, 2, 3, 4, 5, 6, UInt8(packet.count)] + packet
        for handle: UInt16 in [0x40, 0x43, 0x143] {
            for fragmentSize in [20, 27, 120] {
                var parser = SiriRemotePacketParser()
                func feed(_ payload: [UInt8]) -> [VoiceEvent] {
                    records(payload, handle: handle, fragmentSize: fragmentSize).flatMap { parser.events(from: $0) }
                }
                XCTAssertEqual(feed([0x1B, 0x23, 0, 0, 0x10]), [.started])
                XCTAssertEqual(feed(frame), [.packet(Data(packet))])
                XCTAssertEqual(feed([0x1B, 0x23, 0, 0x10, 0]), [.ended])
                XCTAssertEqual(feed(frame), [])
            }
        }
    }

    private func oldFrame(_ sequence: UInt16, released: Bool, packet: [UInt8]) -> [UInt8] {
        [0x1B, 0x23, 0, 0x10, released ? 0 : 0x10, 0, 0, UInt8(sequence & 255), UInt8(sequence >> 8),
         UInt8(packet.count)] + packet
    }

    func testOldRemoteEndsAtTheReleaseInsteadOfDrainingPostReleaseRecording() {
        var parser = SiriRemotePacketParser()
        let packet: [UInt8] = [0xB8] + Array(1...40)
        func feed(_ payload: [UInt8], at time: TimeInterval) -> [VoiceEvent] {
            records(payload, handle: 0x56).flatMap { parser.events(from: $0, now: time) }
        }
        XCTAssertEqual(feed([0x1B, 0x23, 0, 0, 0x10], at: 10), [.started])
        // Held: frames trail real time because the link carries ~44 of 50 frames/s.
        for sequence: UInt16 in 0..<40 {
            XCTAssertEqual(feed(oldFrame(sequence, released: false, packet: packet), at: 10.05 + Double(sequence) * 0.0225),
                           [.packet(Data(packet))])
        }
        // Released 1.0 s after start: frames 0...65 (release + 0.3 s) are still speech.
        XCTAssertEqual(feed(oldFrame(40, released: true, packet: packet), at: 11.0), [.packet(Data(packet))])
        for sequence: UInt16 in 41...65 {
            XCTAssertEqual(feed(oldFrame(sequence, released: true, packet: packet), at: 11 + Double(sequence - 40) * 0.0225),
                           [.packet(Data(packet))])
        }
        XCTAssertEqual(feed(oldFrame(66, released: true, packet: packet), at: 11.6), [.ended])
        XCTAssertEqual(feed(oldFrame(67, released: true, packet: packet), at: 11.62), [])
        XCTAssertEqual(feed([0x1B, 0x23, 0, 0x10, 0], at: 12.5), [], "The protocol end must not end it twice")
        XCTAssertEqual(feed([0x1B, 0x23, 0, 0, 0x10], at: 13), [.started])
    }

    func testOldRemotePressDuringTheFlushContinuesTheDictationSession() {
        var parser = SiriRemotePacketParser()
        let packet: [UInt8] = [0xB8] + Array(1...40)
        func feed(_ payload: [UInt8], at time: TimeInterval) -> [VoiceEvent] {
            records(payload, handle: 0x56).flatMap { parser.events(from: $0, now: time) }
        }
        XCTAssertEqual(feed([0x1B, 0x23, 0, 0, 0x10], at: 0), [.started])
        XCTAssertEqual(feed(oldFrame(0, released: false, packet: packet), at: 0.05), [.packet(Data(packet))])
        XCTAssertEqual(feed(oldFrame(1, released: true, packet: packet), at: 0.1), [.packet(Data(packet))])
        XCTAssertEqual(feed(oldFrame(30, released: true, packet: packet), at: 0.6), [.ended])
        XCTAssertEqual(feed(oldFrame(31, released: false, packet: packet), at: 0.7), [.started, .packet(Data(packet))])
        XCTAssertEqual(feed(oldFrame(60, released: false, packet: packet), at: 1.4), [.packet(Data(packet))])
        XCTAssertEqual(feed([0x1B, 0x23, 0, 0x10, 0], at: 2), [.ended])
    }

    func testTwoGenerationsCanInterleaveAndOtherHandlesCannotSupplyOldAudio() {
        var parser = SiriRemotePacketParser()
        let oldPacket: [UInt8] = [0xB8] + Array(1...66)
        let newPacket: [UInt8] = [0xB8, 9, 8, 7]
        for line in records([0x1B, 0x23, 0, 0, 0x10], handle: 0x43) { _ = parser.events(from: line) }
        let old = records([0x1B, 0x23, 0, 1, 2, 3, 4, 5, 6, UInt8(oldPacket.count)] + oldPacket, handle: 0x43)
        XCTAssertEqual(parser.events(from: old[0]), [])
        let newer = records([0x1B, 0x35, 0, 0, 0, 0, 0, UInt8(newPacket.count)] + newPacket, handle: 0x44)
        XCTAssertEqual(newer.flatMap { parser.events(from: $0) }, [.started, .packet(Data(newPacket))])
        XCTAssertEqual(old.dropFirst().flatMap { parser.events(from: $0) }, [.packet(Data(oldPacket))])
        let unrelated = records([0x1B, 0x23, 0, 1, 2, 3, 4, 5, 6, UInt8(oldPacket.count)] + oldPacket, handle: 0x45)
        XCTAssertEqual(unrelated.flatMap { parser.events(from: $0) }, [])
        let truncated = records([0x1B, 0x23, 0, 1, 2, 3, 4, 5, 6, 90, 0xB8], handle: 0x43)
        XCTAssertEqual(truncated.flatMap { parser.events(from: $0) }, [])
    }

    func testMediaTrafficCannotSupplyOrResumeAnInterruptedATTFragment() {
        var parser = SiriRemotePacketParser()
        let packet: [UInt8] = [0xB8] + Array(1...66)
        let voice = records([0x1B, 0x23, 0, 1, 2, 3, 4, 5, 6, UInt8(packet.count)] + packet, handle: 0x43)
        _ = records([0x1B, 0x23, 0, 0, 0x10], handle: 0x43).flatMap { parser.events(from: $0) }
        XCTAssertEqual(parser.events(from: voice[0]), [])
        // A new non-ATT packet on the same handle invalidates pending reassembly.
        XCTAssertEqual(parser.events(from: "media RECV 43 20 0C 00 08 00 40 00 1B 35 00 00 00 00 00 00"), [])
        XCTAssertEqual(voice.dropFirst().flatMap { parser.events(from: $0) }, [])
        XCTAssertEqual(voice.flatMap { parser.events(from: $0) }, [.packet(Data(packet))])
        XCTAssertEqual(parser.events(from: "media RECV 44 10 04 00 1B 39 00 00"), [], "Unowned continuations are ignored")
    }

    func testBoundedACLHeaderAcceptsHexCaseAndWhitespaceAndRejectsMalformedHeaders() {
        let payload: [UInt8] = [0x1B, 0x35, 0, 0, 0, 1, 0, 4, 0xB8, 9, 8, 7]
        let line = records(payload, handle: 0x4E)[0]
        let hex = String(line.dropFirst("test RECV ".count)).lowercased().replacingOccurrences(of: " ", with: "\t ")
        var parser = SiriRemotePacketParser()
        XCTAssertEqual(parser.events(from: "test RECV \t" + hex), [.started, .packet(Data([0xB8, 9, 8, 7]))])
        for header in ["4E 2X 00 00", "4E 200 00 00", "4E 20 00", "4E 20 04 00 01 00 40 00"] {
            XCTAssertEqual(parser.events(from: "invalid RECV " + header), [])
        }
    }
}
