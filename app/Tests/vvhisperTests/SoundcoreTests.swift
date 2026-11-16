import CryptoKit
import XCTest
@testable import vvhisper

final class SoundcoreTests: XCTestCase {
    private func response(_ type: UInt8, _ command: UInt8, _ payload: [UInt8], status: UInt8 = 1) -> Data {
        var bytes = Array(SoundcoreProtocol.command(type, command, payload))
        bytes[0] = 9; bytes[1] = 255; bytes[4] = status
        bytes[bytes.count - 1] = bytes.dropLast().reduce(0, &+)
        return Data(bytes)
    }

    func testReconnectRequiresVerifiedIdentityAndSurvivesTransientIDs() throws {
        var policy = SoundcoreReconnectPolicy()
        XCTAssertFalse(policy.enabled)
        let original = UUID()
        let address = Data([1, 2, 3, 4, 5, 6])
        policy.verified(peripheralID: original, address: address)
        XCTAssertTrue(policy.enabled)
        let saved = try JSONEncoder().encode(XCTUnwrap(policy.identity))
        let identity = try JSONDecoder().decode(SoundcoreReconnectPolicy.Identity.self, from: saved)
        XCTAssertTrue(identity.matches(peripheralID: UUID(), address: address))
        XCTAssertTrue(identity.matches(peripheralID: original, address: nil))
        XCTAssertFalse(identity.matches(peripheralID: UUID(), address: nil))
        XCTAssertFalse(identity.matches(peripheralID: original, address: Data(repeating: 7, count: 6)))
        // System-connected lookups lack advertisements: preserve a known address.
        policy.verified(peripheralID: original, address: nil)
        XCTAssertEqual(policy.identity?.address, address)
    }

    func testReconnectPauseAndBoundedRetryResetOnlyOnSuccessOrUserResume() {
        var policy = SoundcoreReconnectPolicy()
        policy.verified(peripheralID: UUID(), address: nil)
        XCTAssertEqual((0..<7).map { _ in policy.retryDelay() }, [3, 6, 12, 24, 30, 30, 30])
        policy.pause()
        XCTAssertFalse(policy.enabled)
        XCTAssertNotNil(policy.identity)
        policy.resume()
        XCTAssertTrue(policy.enabled)
        XCTAssertEqual(policy.retryDelay(), 3)
        policy.verified(peripheralID: UUID(), address: nil)
        XCTAssertEqual(policy.retryDelay(), 3)
    }

    func testMissingAudioRecoversWithoutTreatingTapsOrSilentPacketsAsFailure() {
        XCTAssertFalse(SoundcoreAudioHealth.needsRecovery(frames: 0, elapsed: 0.2))
        XCTAssertFalse(SoundcoreAudioHealth.needsRecovery(frames: 0, elapsed: 1.49))
        XCTAssertTrue(SoundcoreAudioHealth.needsRecovery(frames: 0, elapsed: 1.5))
        XCTAssertTrue(SoundcoreAudioHealth.needsRecovery(frames: 0, elapsed: 8))
        // Received packets with a quiet signal still prove the transport works.
        XCTAssertFalse(SoundcoreAudioHealth.needsRecovery(frames: 1, elapsed: 8))
    }

    func testNativeDecoderReceivesSyntheticOpusWithoutSavingAudio() throws {
        // 20 ms 440 Hz sine, ffmpeg libopus 32 kbps, 16 kHz mono. No user audio.
        let packet = Data(base64Encoded: "SIFZrL24LvWisk6yEIsYo13toc6UKbnxVjxf6sqIqubbDZhamQgqVrEtR7AMoZl+8e6CJk+SeRCRhWqM8dRBWaRzbZeh4JE4S+xv8ak1QvHgI8D4QuyGnGxKLBqM+RszGbw7IZ6DlbkRagtY4A==")!
        let source = try SoundcoreAudioSource(onSamples: { _ in })
        _ = try source.append(packet + Data(repeating: 0, count: 160 - packet.count))
        let audio = source.stop()
        XCTAssertEqual(audio.samples.count, 320)
        XCTAssertGreaterThan(audio.rms, 0.001)
        XCTAssertTrue(source.stop().samples.isEmpty)
    }

    func testKnownCommandAndFragmentedNotifications() {
        XCTAssertEqual(Array(SoundcoreProtocol.command(1, 1)), [8, 238, 0, 0, 0, 1, 1, 10, 0, 2])
        let packet = response(1, 3, [9, 4])
        for split in 0...packet.count {
            var parser = SoundcoreProtocol.Parser()
            let result = parser.append(Data(packet.prefix(split))) + parser.append(Data(packet.dropFirst(split)))
            XCTAssertEqual(result.map(\.payload), [[9, 4]])
            XCTAssertTrue(parser.buffer.isEmpty)
        }
    }

    func testParserResynchronizesAndBoundsGarbage() {
        var parser = SoundcoreProtocol.Parser()
        var broken = response(1, 3, [1, 2])
        broken[broken.count - 1] ^= 1
        let good = response(0x18, 0x82, [1])
        let decoded = parser.append(Data(repeating: 0x44, count: 100_000) + broken + good + good)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertTrue(parser.buffer.isEmpty)
        XCTAssertFalse(SoundcoreProtocol.Packet(status: 1, type: 1, command: 1, payload: [255]).succeeded)
    }

    func testReferenceDiscoveryVariantsAndEmptyNameFallback() {
        for name in ["soundcor", "声阔录音卡", "Anker Recorder", "sound work"] {
            XCTAssertTrue(SoundcoreProtocol.matches(name: name, services: []), name)
        }
        for service in ["F5DA", "0000F5DA-0000-1000-8000-00805F9B34FB", "DAF50C02-0000-1000-8000-00805F9B34FB"] {
            XCTAssertTrue(SoundcoreProtocol.matches(name: nil, services: [service]), service)
        }
        let flaggedMark = Data(repeating: 0, count: 8) + Data("SOUNDC".utf8.map { $0 | 0x80 })
        XCTAssertTrue(SoundcoreProtocol.matches(name: nil, services: [], manufacturer: flaggedMark))
        XCTAssertTrue(SoundcoreProtocol.matches(name: nil, services: [], manufacturer: Data([0x02, 0x0C, 0xF5])))
        XCTAssertEqual(SoundcoreProtocol.discoveryName(advertised: "  ", peripheral: "D3200"), "D3200")
        XCTAssertEqual(SoundcoreProtocol.discoveryName(advertised: " soundcore Work ", peripheral: "Old"), "soundcore Work")
        XCTAssertNil(SoundcoreProtocol.discoveryName(advertised: "", peripheral: "  "))
        XCTAssertFalse(SoundcoreProtocol.matches(name: "Work Keyboard", services: ["180F"]))
    }

    func testDiscoveryNeverTreatsUnnamedPeripheralsAsSoundcore() {
        XCTAssertFalse(SoundcoreProtocol.matches(name: nil, services: []))
        XCTAssertFalse(SoundcoreProtocol.matches(name: "Headphones", services: ["180F"]))
        XCTAssertTrue(SoundcoreProtocol.matches(name: nil, services: [SoundcoreProtocol.service.lowercased()]))
        XCTAssertTrue(SoundcoreProtocol.matches(name: "soundcore Work", services: []))
        XCTAssertTrue(SoundcoreProtocol.matches(name: "D3200", services: []))
        XCTAssertTrue(SoundcoreProtocol.matches(name: nil, services: [], manufacturer: Data(repeating: 0, count: 8) + Data("soundc".utf8)))
        XCTAssertFalse(SoundcoreProtocol.matches(name: nil, services: [], manufacturer: Data("soundc".utf8)))
    }

    func testDeviceInfoAndBatteryBuckets() {
        XCTAssertNil(SoundcoreProtocol.DeviceInfo([1, 9]))
        var payload = [UInt8](repeating: 0, count: 51)
        payload[1] = 9; payload[38] = 4; payload[50] = 1
        payload.replaceSubrange(3..<8, with: Array("04.73".utf8))
        let info = SoundcoreProtocol.DeviceInfo(payload)
        XCTAssertEqual(info?.battery, 100)
        XCTAssertEqual(info?.caseBattery, 50)
        XCTAssertEqual(info?.firmware, "04.73")
        XCTAssertEqual(info?.recording, true)
        XCTAssertNil(SoundcoreProtocol.battery(255))
        XCTAssertEqual(SoundcoreProtocol.battery(72), 72)
    }

    func testLiveWindowDropsEarlierSpeechAndDuplicatesButRejectsGaps() throws {
        var window = SoundcoreProtocol.LiveWindow(discardBefore: 2)
        XCTAssertFalse(try window.accepts(0))
        XCTAssertFalse(try window.accepts(1))
        XCTAssertTrue(try window.accepts(2))
        XCTAssertFalse(try window.accepts(2))
        XCTAssertThrowsError(try window.accepts(4))
        XCTAssertEqual(window.next, 3)
        XCTAssertTrue(try window.accepts(3))
    }

    func testLiveStreamAnchorsAtCurrentPacketButNeverReplaysPreHoldSpeech() throws {
        var fresh = SoundcoreProtocol.LiveWindow(discardBefore: 0)
        XCTAssertTrue(try fresh.accepts(24))
        XCTAssertTrue(try fresh.accepts(25))
        XCTAssertFalse(try fresh.accepts(24))
        XCTAssertThrowsError(try fresh.accepts(27))
        var resumed = SoundcoreProtocol.LiveWindow(discardBefore: 100)
        XCTAssertFalse(try resumed.accepts(24))
        XCTAssertFalse(try resumed.accepts(99))
        XCTAssertFalse(resumed.started)
        XCTAssertTrue(try resumed.accepts(124))
        XCTAssertTrue(try resumed.accepts(125))
        XCTAssertThrowsError(try resumed.accepts(127))
    }

    func testCaptureBoundaryFindsCurrentRecordingBeyondFirstMetadataPage() throws {
        func page(_ ids: [UInt32], current: UInt32) -> [UInt8] {
            var result = [UInt8(ids.count), 0]
            for id in ids {
                result += SoundcoreProtocol.littleEndian(id) + SoundcoreProtocol.littleEndian(0)
                    + SoundcoreProtocol.littleEndian(id * 20)
            }
            return result + SoundcoreProtocol.littleEndian(current) + SoundcoreProtocol.littleEndian(0)
        }
        var baseline = SoundcoreProtocol.CaptureBaseline()
        XCTAssertNil(try baseline.append(page(Array(1...10), current: 11), withEndTime: true))
        XCTAssertEqual(baseline.page, 1)
        XCTAssertEqual(try baseline.append(page([11], current: 11), withEndTime: true), 11)
        XCTAssertEqual(baseline.frames[11], 11)
        var missing = SoundcoreProtocol.CaptureBaseline()
        XCTAssertThrowsError(try missing.append(page([1, 2], current: 11), withEndTime: true))
        var switched = SoundcoreProtocol.CaptureBaseline()
        XCTAssertNil(try switched.append(page(Array(1...10), current: 11), withEndTime: true))
        XCTAssertThrowsError(try switched.append(page([11], current: 12), withEndTime: true))
    }

    func testLiveTransportSurvivesHoldBoundariesButNotFileOrLinkChanges() throws {
        var transport = SoundcoreProtocol.LiveTransport()
        XCTAssertFalse(transport.canResume(10))
        transport.request(10)
        XCTAssertFalse(transport.canResume(10))
        transport.confirm(11)
        XCTAssertFalse(transport.canResume(10))
        transport.confirm(10)
        for _ in 0..<20 {
            // Separate capture windows must not clear the device's transfer.
            var hold = SoundcoreProtocol.LiveWindow(discardBefore: 120)
            XCTAssertFalse(try hold.accepts(119))
            XCTAssertTrue(try hold.accepts(120))
            XCTAssertTrue(transport.canResume(10))
        }
        XCTAssertFalse(transport.canResume(11))
        transport.request(11)
        XCTAssertFalse(transport.canResume(10))
        XCTAssertFalse(transport.canResume(11))
        transport.confirm(11)
        XCTAssertTrue(transport.canResume(11))
        transport.finish()
        XCTAssertFalse(transport.canResume(11))
    }

    func testSlicesRejectTruncationAndPreserveSequence() throws {
        let raw = SoundcoreProtocol.littleEndian(256) + [0] + [UInt8](repeating: 42, count: 160) + [0]
        let slices = try SoundcoreProtocol.Slice.parse(raw + raw)
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices[0].sequence, 256)
        XCTAssertEqual(slices[0].bytes.count, 160)
        XCTAssertThrowsError(try SoundcoreProtocol.Slice.parse(Array(raw.dropLast())))
        XCTAssertThrowsError(try SoundcoreProtocol.Slice.parse([]))
    }

    func testAESCTRMatchesNIST256Vector() throws {
        func hex(_ value: String) -> Data {
            let chars = Array(value)
            return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! })
        }
        let key = hex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        let iv = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let plain = hex("6bc1bee22e409f96e93d7e117393172a")
        XCTAssertEqual(try SoundcoreProtocol.Crypto.ctr(plain, key: key, iv: iv),
                       hex("601ec313775789a5b7a7f504bbf3d228"))
    }

    func testHandshakeChecksPeerAndHeaderBelongsToRequestedSession() throws {
        let crypto = SoundcoreProtocol.Crypto()
        let peer = P256.KeyAgreement.PrivateKey()
        let appPublic = try P256.KeyAgreement.PublicKey(x963Representation: Data(crypto.publicKey))
        let shared = try peer.sharedSecretFromKeyAgreement(with: appPublic)
        let payload = Array(peer.publicKey.x963Representation) + shared.withUnsafeBytes { Array($0) }
        try crypto.handshake(payload)
        let session = try XCTUnwrap(crypto.sessionKey)
        let nonce = Data(repeating: 3, count: 16)
        let fileKey = Data((0..<32).map(UInt8.init))
        let material = Data("soundcored3200".utf8) + fileKey
        let encryptedKey = try SoundcoreProtocol.Crypto.ctr(material, key: session, iv: nonce)
        let head = SoundcoreProtocol.littleEndian(42) + [0, 0, 0, 0] + Array(nonce) + Array(encryptedKey) + Array(nonce) + [0]
        XCTAssertThrowsError(try crypto.openHead(head, expectedID: 43))
        // Upstream realtime_stream.dart accepts a valid wrapped key even when
        // the trailing metadata byte is 4 (observed on this device on resume).
        var resumedHead = head
        resumedHead[86] = 4
        try crypto.openHead(resumedHead, expectedID: 42)
        var corruptHead = resumedHead
        corruptHead[24] ^= 1
        XCTAssertThrowsError(try crypto.openHead(corruptHead, expectedID: 42))
        try crypto.openHead(resumedHead, expectedID: 42)
        let plain = Data(repeating: 0xAB, count: 160)
        let iv = Data(nonce.prefix(12)) + Data([0, 0, 0, 10])
        let encrypted = try SoundcoreProtocol.Crypto.ctr(plain, key: fileKey, iv: iv)
        XCTAssertEqual(try crypto.decrypt(.init(sequence: 1, bytes: Array(encrypted))), plain)
        var wrong = payload; wrong[96] ^= 1
        XCTAssertThrowsError(try crypto.handshake(wrong))
        XCTAssertNil(crypto.sessionKey)
    }
}
