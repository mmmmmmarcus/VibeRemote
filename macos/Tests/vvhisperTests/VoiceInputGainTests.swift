import Foundation
import RemoteAudioProtocol
import XCTest
@testable import vvhisper

final class VoiceInputGainTests: XCTestCase {
    private final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [Float] = []
        func append(_ chunk: [Float]) { lock.lock(); value += chunk; lock.unlock() }
        func read() -> [Float] { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testSoundcoreGainFeedsBothStreamingAndFinalAudio() throws {
        // Synthetic 20 ms sine packet, shared with the existing decoder test.
        let packet = try XCTUnwrap(Data(base64Encoded: "SIFZrL24LvWisk6yEIsYo13toc6UKbnxVjxf6sqIqubbDZhamQgqVrEtR7AMoZl+8e6CJk+SeRCRhWqM8dRBWaRzbZeh4JE4S+xv8ak1QvHgI8D4QuyGnGxKLBqM+RszGbw7IZ6DlbkRagtY4A=="))
        let padded = packet + Data(repeating: 0, count: 160 - packet.count)
        let baseline = try SoundcoreAudioSource(onSamples: { _ in })
        _ = try baseline.append(padded)
        let original = baseline.stop().samples
        let streamed = Samples()
        let gain = VoiceInputGain(decibels: 12)
        let boosted = try SoundcoreAudioSource(gain: gain, onSamples: { streamed.append($0) })
        let level = try boosted.append(padded)
        let final = boosted.stop()
        XCTAssertEqual(final.samples, gain.apply(original))
        XCTAssertEqual(streamed.read(), final.samples)
        XCTAssertEqual(level, final.rms, accuracy: 0.000001)
        XCTAssertGreaterThan(final.rms, DictationAudio(samples: original).rms)
    }

    func testSiriGainCoversResampledStreamingAndFinalTail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent(DictationAudioFile.fileName)
        let started = Date()
        let header = DictationAudioFile.Header(session: UUID(), startedAt: started, complete: true)
        var data = header.encoded()
        for i in 0..<9_600 {
            var sample = Float(sin(Double(i) * 0.05) * 0.05)
            withUnsafeBytes(of: &sample) { data.append(contentsOf: $0) }
        }
        try data.write(to: path)
        func capture(_ gain: VoiceInputGain) -> (final: [Float], streamed: [Float]) {
            let received = expectation(description: "Siri samples delivered")
            let streamed = Samples()
            let reader = DictationBridgeAudioReader(path: path.path, holdStartedAt: started,
                excluding: [], followsLaterSessions: false, gain: gain) {
                    streamed.append($0)
                    received.fulfill()
                }
            reader.start()
            wait(for: [received], timeout: 2)
            return (reader.stop().samples, streamed.read())
        }
        let baseline = capture(VoiceInputGain())
        let gain = VoiceInputGain(decibels: 12)
        let boosted = capture(gain)
        XCTAssertEqual(boosted.final, gain.apply(baseline.final))
        XCTAssertEqual(boosted.streamed, gain.apply(baseline.streamed))
        XCTAssertFalse(boosted.final.isEmpty)
        XCTAssertGreaterThan(DictationAudio(samples: boosted.final).rms, 0.1)
    }
}
