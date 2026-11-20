import Foundation

/// Per-device software gain, latched for a capture and applied before ASR and metering.
public struct VoiceInputGain: Equatable, Sendable {
    public static let range: ClosedRange<Double> = 0...24
    public let decibels: Double
    public var multiplier: Float { Float(pow(10, decibels / 20)) }

    public init(decibels: Double = 0) {
        self.decibels = Self.range.contains(decibels) ? decibels.rounded() : 0
    }

    public static func key(_ device: VoiceInputDevice) -> String {
        "voiceInputGain.\(device.rawValue).decibels"
    }

    public static func load(_ device: VoiceInputDevice, defaults: UserDefaults = .standard) -> Self {
        Self(decibels: defaults.double(forKey: key(device)))
    }

    public func apply(_ samples: [Float]) -> [Float] {
        guard decibels > 0 else { return samples }
        let scale = multiplier
        // Keep amplified PCM in range for both float streaming and integer WAV encoding.
        return samples.map { $0.isFinite ? min(1, max(-1, $0 * scale)) : 0 }
    }
}
