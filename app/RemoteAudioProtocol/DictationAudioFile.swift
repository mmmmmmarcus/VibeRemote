import Foundation

/// The voice helper's private copy of each decoded voice session, read by VibeRemote Dictation
/// instead of re-recording the virtual device's loopback. The loopback only carries audio once
/// it has been played out, so recording it meant waiting for the output drain plus a grace
/// period after every hold; this file is complete as soon as the remote's protocol ends.
///
/// One file per session, created beside the other bridge runtime files (0700 directory) and
/// atomically renamed into place so a reader never sees a half-written header. Layout, all
/// little-endian: 64-byte header, then 48 kHz mono Float32 samples appended as they decode.
///
///     0  magic "VRDICT01"     8  session UUID (16 bytes)   24  start time (Double bits)
///    32  complete flag (UInt32, written last)               36  sample rate (UInt32)
///
/// The writer appends every sample before it sets the complete flag, so a reader that sees the
/// flag and then reads to end of file has the whole session. It holds speech: the helper
/// deletes it shortly after completion and at launch, like the other private capture files.
public enum DictationAudioFile {
    public static let fileName = "dictation-audio.pcm"
    public static let headerSize = 64
    public static let completeFlagOffset: UInt64 = 32
    public static let sampleRate: Double = 48_000
    public static let bytesPerSample = MemoryLayout<Float32>.size
    /// Matches `DictationRecorder.maximumDuration`: a dropped end marker must not grow forever.
    public static let maximumSamples = Int(300 * sampleRate)
    /// Cross-process signal, posted once the complete flag is written.
    public static let completeNotification = "com.viberemote.voice-audio-complete"
    private static let magic = Array("VRDICT01".utf8)

    public struct Header: Equatable, Sendable {
        public var session: UUID
        public var startedAt: Date
        public var complete: Bool

        public init(session: UUID, startedAt: Date, complete: Bool = false) {
            self.session = session
            self.startedAt = startedAt
            self.complete = complete
        }

        public func encoded() -> Data {
            var data = Data(DictationAudioFile.magic)
            withUnsafeBytes(of: session.uuid) { data.append(contentsOf: $0) }
            append(startedAt.timeIntervalSince1970.bitPattern, to: &data)
            append(UInt32(complete ? 1 : 0), to: &data)
            append(UInt32(DictationAudioFile.sampleRate), to: &data)
            data.append(Data(count: DictationAudioFile.headerSize - data.count))
            return data
        }

        public static func decode(_ data: Data) -> Header? {
            let bytes = [UInt8](data.prefix(DictationAudioFile.headerSize))
            guard bytes.count == DictationAudioFile.headerSize,
                  Array(bytes[0..<8]) == DictationAudioFile.magic,
                  integer(bytes, at: 36, as: UInt32.self) == UInt32(DictationAudioFile.sampleRate) else { return nil }
            let uuid = UUID(uuid: (bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
                                   bytes[16], bytes[17], bytes[18], bytes[19], bytes[20], bytes[21], bytes[22], bytes[23]))
            let started = Double(bitPattern: integer(bytes, at: 24, as: UInt64.self))
            guard started.isFinite else { return nil }
            return Header(session: uuid, startedAt: Date(timeIntervalSince1970: started),
                          complete: integer(bytes, at: 32, as: UInt32.self) == 1)
        }

        private func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        private static func integer<T: FixedWidthInteger>(_ bytes: [UInt8], at offset: Int, as: T.Type) -> T {
            var value: T = 0
            for index in 0..<MemoryLayout<T>.size { value |= T(bytes[offset + index]) << (8 * index) }
            return value
        }
    }

    public static func completeFlag() -> Data {
        withUnsafeBytes(of: UInt32(1).littleEndian) { Data($0) }
    }

    /// Whole samples in `data`, ignoring a trailing partial sample still being written.
    public static func samples(in data: Data) -> [Float] {
        let count = data.count / bytesPerSample
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            (0..<count).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * bytesPerSample, as: UInt32.self))) }
        }
    }
}
