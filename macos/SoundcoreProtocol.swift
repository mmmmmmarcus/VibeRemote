import Foundation
import CryptoKit
import CommonCrypto

// Interoperability reference: https://github.com/tacshi/Soundcore (MIT, Rocky Shi).
// Only the BLE microphone transport; no archive, deletion, binding or firmware commands.
enum SoundcoreProtocol {
    static let service = "020CF5DA-0000-1000-8000-00805F9B34FB"
    static let write = "00007777-0000-1000-8000-00805F9B34FB"
    static let notify = "00008888-0000-1000-8000-00805F9B34FB"

    /// Discovery hints mirror lib/ble/advertisement.dart in tacshi/Soundcore.
    /// They identify candidates only: connection still requires D3200's GATT
    /// service, characteristics, device-info response and secure handshake.
    static func discoveryMatch(name: String?, services: [String], manufacturer: Data = Data()) -> String? {
        let name = name?.lowercased() ?? ""
        if services.contains(where: { value in
            let compact = value.lowercased().replacingOccurrences(of: "-", with: "")
            let head = value.lowercased().split(separator: "-").first.map(String.init) ?? ""
            return compact.contains("020cf5da") || compact.contains("daf50c02") ||
                compact == "f5da" || compact.hasSuffix("f5da") || head.contains("f5da") || head.hasPrefix("daf5")
        }) { return "service" }
        if name.contains("soundcore") || name.contains("soundcor") || name.contains("d3200") ||
            (name.contains("work") && name.contains("sound")) || name.contains("录音") ||
            (name.contains("anker") && name.contains("record")) { return "name" }
        if manufacturer.count >= 14 {
            let mark = String(decoding: manufacturer.dropFirst(8).prefix(6).map { $0 & 0x7F }, as: UTF8.self).lowercased()
            if mark.contains("sound") || mark.contains("scor") { return "manufacturer mark" }
        }
        let hex = manufacturer.map { String(format: "%02x", $0) }.joined()
        if hex.contains("f5da") || hex.contains("020cf5") { return "manufacturer service" }
        return nil
    }

    static func matches(name: String?, services: [String], manufacturer: Data = Data()) -> Bool {
        discoveryMatch(name: name, services: services, manufacturer: manufacturer) != nil
    }

    static func discoveryName(advertised: String?, peripheral: String?) -> String? {
        for candidate in [advertised, peripheral] {
            if let name = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        }
        return nil
    }

    struct Packet: Equatable {
        let status: UInt8
        let type: UInt8
        let command: UInt8
        let payload: [UInt8]
        var succeeded: Bool { status & 15 == 1 && payload != [0xFF] }
    }

    static func command(_ type: UInt8, _ id: UInt8, _ payload: [UInt8] = []) -> Data {
        precondition(payload.count <= 65525)
        let length = payload.count + 10
        var bytes: [UInt8] = [8, 0xEE, 0, 0, 0, type, id, UInt8(length & 255), UInt8(length >> 8)] + payload
        bytes.append(bytes.reduce(0, &+))
        return Data(bytes)
    }

    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 |
        UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }
    static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    static func battery(_ value: UInt8) -> Int? {
        value <= 9 ? (Int(value) + 1) * 10 : (value <= 100 ? Int(value) : nil)
    }

    struct Parser {
        private(set) var buffer: [UInt8] = []
        mutating func append(_ data: Data) -> [Packet] {
            buffer.append(contentsOf: data)
            var packets: [Packet] = []
            var offset = 0
            while buffer.count - offset >= 10 {
                guard Array(buffer[offset..<(offset + 4)]) == [9, 255, 0, 0] else { offset += 1; continue }
                let length = Int(buffer[offset + 7]) | Int(buffer[offset + 8]) << 8
                guard length >= 10 else { offset += 1; continue }
                guard buffer.count - offset >= length else { break }
                let end = offset + length
                guard buffer[offset..<(end - 1)].reduce(UInt8(0), &+) == buffer[end - 1] else {
                    offset += 1; continue
                }
                packets.append(Packet(status: buffer[offset + 4], type: buffer[offset + 5],
                                      command: buffer[offset + 6], payload: Array(buffer[(offset + 9)..<(end - 1)])))
                offset = end
            }
            buffer.removeFirst(offset)
            // A length field is UInt16. Garbage can never retain an unbounded receive buffer.
            if buffer.count > 65535 { buffer = Array(buffer.suffix(9)) }
            return packets
        }
    }

    struct DeviceInfo {
        let battery: Int?
        let caseBattery: Int?
        let firmware: String
        let recording: Bool?
        init?(_ payload: [UInt8]) {
            guard payload.count >= 8 else { return nil }
            battery = SoundcoreProtocol.battery(payload[1])
            firmware = String(bytes: payload[3..<8].prefix { $0 != 0 }, encoding: .ascii) ?? "Unknown"
            caseBattery = payload.count > 38 ? SoundcoreProtocol.battery(payload[38]) : nil
            recording = payload.count > 50 ? payload[50] == 1 : nil
        }
    }

    /// Microphone pause and transport completion are different device events.
    /// Keep the verified transfer across holds; opening it again while paused
    /// returns header metadata 4 on D3200 instead of establishing a new stream.
    struct LiveTransport {
        private(set) var fileID: UInt32?
        private(set) var confirmed = false
        mutating func request(_ id: UInt32) { fileID = id; confirmed = false }
        mutating func confirm(_ id: UInt32) {
            guard id == fileID else { return }
            confirmed = true
        }
        func canResume(_ id: UInt32) -> Bool { confirmed && id == fileID }
        mutating func finish() { fileID = nil; confirmed = false }
    }

    struct CaptureBaseline {
        private(set) var frames: [UInt32: UInt32] = [:]
        private(set) var page: UInt16 = 0
        private var currentID: UInt32 = 0

        /// nil requests the next metadata page; a non-nil ID is ready (0 means
        /// there was no active recording before this hold).
        mutating func append(_ payload: [UInt8], withEndTime: Bool) throws -> UInt32? {
            guard payload.count >= 2 else { throw Failure.invalidInventory }
            let count = Int(payload[0]) | Int(payload[1]) << 8
            let width = withEndTime ? 12 : 8
            let end = 2 + count * width
            guard payload.count >= end + 8 else { throw Failure.invalidInventory }
            for offset in stride(from: 2, to: end, by: width) {
                frames[u32(payload, offset)] = u32(payload, offset + width - 4) / 20
            }
            let current = u32(payload, end)
            if page == 0 { currentID = current }
            guard current == currentID else { throw Failure.invalidInventory }
            if currentID == 0 || frames[currentID] != nil { return currentID }
            guard count == 10, page < 255 else { throw Failure.invalidInventory }
            page += 1
            return nil
        }
    }

    struct LiveWindow {
        private(set) var next: UInt32 = 0
        private(set) var started = false
        let discardBefore: UInt32
        mutating func accepts(_ sequence: UInt32) throws -> Bool {
            // 04.92 realtimeFlag=1 begins at the current live packet (observed 24),
            // not necessarily zero. Ignore any pre-hold replay, then anchor once.
            guard sequence >= discardBefore else { return false }
            if !started {
                guard sequence < UInt32.max else { throw Failure.sequenceGap }
                started = true
                next = sequence + 1
                return true
            }
            if sequence < next { return false }
            guard sequence == next, sequence < UInt32.max else { throw Failure.sequenceGap }
            next += 1
            return true
        }
    }

    struct Slice {
        let sequence: UInt32
        let bytes: [UInt8]
        static func parse(_ payload: [UInt8]) throws -> [Slice] {
            guard !payload.isEmpty, payload.count % 166 == 0 else { throw Failure.invalidSlices }
            return stride(from: 0, to: payload.count, by: 166).map { offset in
                Slice(sequence: u32(payload, offset), bytes: Array(payload[(offset + 5)..<(offset + 165)]))
            }
        }
    }

    enum Failure: String, Error, LocalizedError {
        case handshake = "Soundcore could not establish an audio session. Reconnect and try again."
        case invalidInventory = "Soundcore’s current microphone session could not be located safely."
        case invalidHead = "Soundcore returned an unexpected audio header."
        case invalidKey = "Soundcore audio key format is not supported on this firmware."
        case invalidSlices = "Soundcore sent a malformed audio packet."
        case sequenceGap = "Soundcore audio was interrupted. Move it closer and try again."
        case decode = "Soundcore audio could not be decoded."
        var errorDescription: String? { rawValue }
    }

    final class Crypto {
        let privateKey = P256.KeyAgreement.PrivateKey()
        private(set) var sessionKey: Data?
        private var fileKey: Data?
        private var nonce: [UInt8] = []
        var publicKey: [UInt8] { Array(privateKey.publicKey.x963Representation) }

        func handshake(_ payload: [UInt8]) throws {
            sessionKey = nil
            guard payload.count >= 97 else { throw Failure.handshake }
            let peer = try P256.KeyAgreement.PublicKey(x963Representation: Data(payload.prefix(65)))
            let secret = try privateKey.sharedSecretFromKeyAgreement(with: peer)
            let check = secret.withUnsafeBytes { Array($0) }
            guard zip(check, payload[65..<97]).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
                throw Failure.handshake
            }
            sessionKey = secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data([1, 2, 3]),
                                                       sharedInfo: Data([1, 2, 3]), outputByteCount: 32)
                .withUnsafeBytes { Data($0) }
        }

        func openHead(_ payload: [UInt8], expectedID: UInt32) throws {
            fileKey = nil
            // RealtimeBleStream validates packet rejection and unwraps the key;
            // it does not gate live headers on AudioFileSecretKey.errorCode.
            // Keep matching-ID and cryptographic validation, never decode raw fallback.
            guard let sessionKey, payload.count >= 87, u32(payload, 0) == expectedID
                else { throw Failure.invalidHead }
            let plain = try Self.ctr(Data(payload[24..<70]), key: sessionKey, iv: Data(payload[70..<86]))
            // Validate all 14 magic bytes before accepting the following 32-byte AES key.
            guard plain.prefix(14) == Data("soundcored3200".utf8) else { throw Failure.invalidKey }
            fileKey = Data(plain.suffix(32))
            nonce = Array(payload[8..<24])
        }

        func decrypt(_ slice: Slice) throws -> Data {
            guard let fileKey, nonce.count == 16 else { throw Failure.invalidKey }
            let counter = slice.sequence.multipliedReportingOverflow(by: 10)
            guard !counter.overflow else { throw Failure.invalidSlices }
            let suffix = (0..<4).reversed().map { UInt8(truncatingIfNeeded: counter.partialValue >> ($0 * 8)) }
            return try Self.ctr(Data(slice.bytes), key: fileKey, iv: Data(nonce.prefix(12)) + Data(suffix))
        }

        static func ctr(_ data: Data, key: Data, iv: Data) throws -> Data {
            guard key.count == 32, iv.count == 16 else { throw Failure.invalidKey }
            var cryptor: CCCryptorRef?
            let status = key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCryptorCreateWithMode(CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                           CCPadding(ccNoPadding), ivBytes.baseAddress, keyBytes.baseAddress,
                                           key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
                }
            }
            guard status == kCCSuccess, let cryptor else { throw Failure.invalidKey }
            defer { CCCryptorRelease(cryptor) }
            var output = Data(count: data.count + 16)
            let capacity = output.count
            var moved = 0
            let result = output.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    CCCryptorUpdate(cryptor, source.baseAddress, data.count, destination.baseAddress, capacity, &moved)
                }
            }
            guard result == kCCSuccess, moved == data.count else { throw Failure.invalidKey }
            return Data(output.prefix(moved))
        }
    }
}

/// Reconnect only a device that previously completed the D3200 handshake.
/// A fresh advertisement (or system-connected peripheral) is still required;
/// a remembered CoreBluetooth UUID alone never proves that a device is awake.
struct SoundcoreReconnectPolicy {
    struct Identity: Codable, Equatable {
        let peripheralID: UUID
        let address: Data?

        func matches(peripheralID: UUID, address: Data?) -> Bool {
            if let known = self.address, let address { return known == address }
            return self.peripheralID == peripheralID
        }
    }

    var identity: Identity?
    private(set) var paused = false
    private var failures = 0
    var enabled: Bool { identity != nil && !paused }

    mutating func pause() { paused = true }
    mutating func resume() { paused = false; failures = 0 }
    mutating func verified(peripheralID: UUID, address: Data?) {
        let knownAddress = address ?? (identity?.peripheralID == peripheralID ? identity?.address : nil)
        identity = Identity(peripheralID: peripheralID, address: knownAddress)
        resume()
    }
    mutating func retryDelay() -> Int {
        let delay = min(30, 3 * (1 << min(failures, 4)))
        failures += 1
        return delay
    }
}

/// A quick accidental tap may finish before the first BLE packet; an ordinary
/// hold with no packets is a transport failure, not a silent microphone.
enum SoundcoreAudioHealth {
    static func needsRecovery(frames: Int, elapsed: TimeInterval) -> Bool {
        frames == 0 && elapsed >= 1.5
    }
}
