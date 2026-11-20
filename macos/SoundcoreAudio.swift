import AVFoundation
import Foundation
import RemoteAudioProtocol

/// Memory-only audio for one dictation hold. All mutable state and the native decoder
/// are serialized; stop detaches delivery before returning the final clip.
final class SoundcoreAudioSource: DictationAudioSource, @unchecked Sendable {
    private let gain: VoiceInputGain
    private let lock = NSLock()
    private var samples: [Float] = []
    private var callback: (@Sendable ([Float]) -> Void)?
    private var stopped = false
    private let converter: AVAudioConverter
    private let compressedFormat: AVAudioFormat
    private let pcmFormat: AVAudioFormat
    private(set) var frames = 0

    init(gain: VoiceInputGain = VoiceInputGain(), onSamples: @escaping @Sendable ([Float]) -> Void) throws {
        var description = AudioStreamBasicDescription(mSampleRate: 16_000, mFormatID: kAudioFormatOpus,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 320, mBytesPerFrame: 0,
            mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let compressed = AVAudioFormat(streamDescription: &description),
              let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                      channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: compressed, to: pcm) else {
            throw SoundcoreProtocol.Failure.decode
        }
        self.gain = gain
        self.compressedFormat = compressed
        self.pcmFormat = pcm
        converter.primeMethod = .none
        // Raw BLE Opus has no container pre-skip. Do not apply the converter's
        // default leading trim to the first microphone packet.
        converter.primeInfo = AVAudioConverterPrimeInfo(leadingFrames: 0, trailingFrames: 0)
        self.converter = converter
        callback = onSamples
    }

    func append(_ decrypted: Data) throws -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return 0 }
        // The D3200 protocol pads each Opus packet to a fixed 160 bytes.
        var packet = decrypted
        while packet.count > 1 && packet.last == 0 { packet.removeLast() }
        let compressed = AVAudioCompressedBuffer(format: compressedFormat, packetCapacity: 1,
                                                maximumPacketSize: packet.count)
        compressed.packetCount = 1
        compressed.byteLength = UInt32(packet.count)
        packet.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { memcpy(compressed.data, base, packet.count) }
        }
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 320, mDataByteSize: UInt32(packet.count))
        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 1920) else {
            throw SoundcoreProtocol.Failure.decode
        }
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return compressed
        }
        guard result != .error, let channel = output.floatChannelData?[0] else {
            throw SoundcoreProtocol.Failure.decode
        }
        let decoded = gain.apply(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
        guard samples.count + decoded.count <= 16_000 * 120 else { throw SoundcoreProtocol.Failure.invalidSlices }
        samples.append(contentsOf: decoded)
        frames += 1
        callback?(decoded)
        return DictationLevelMeter.rms(decoded)
    }

    func stop() -> DictationAudio {
        lock.lock()
        defer { lock.unlock() }
        stopped = true
        callback = nil
        let audio = DictationAudio(samples: samples)
        samples.removeAll()
        return audio
    }
}
