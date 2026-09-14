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
}
