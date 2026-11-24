import Foundation

/// A disposable meter reading, never microphone audio or recognition progress.
struct VoiceLevel: Codable, Equatable {
    static let filename = "level.json"
    static let lifetime: TimeInterval = 0.3
    var id: UUID
    var value: Double
    var updatedAt: Date

    func isFresh(for id: UUID, at now: Date) -> Bool {
        let age = now.timeIntervalSince(updatedAt)
        return self.id == id && value.isFinite && (0...1).contains(value)
            && age >= 0 && age < Self.lifetime
    }

    /// Mono floating-point PCM from the existing 16 kHz ASR path. Bound the
    /// useful speech range to -55…-15 dBFS; never retain samples in the meter.
    static func measure(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var energy = 0.0
        for sample in samples {
            guard sample.isFinite else { return 0 }
            let value = min(1, max(-1, Double(sample)))
            energy += value * value
        }
        return normalizedRMS(sqrt(energy / Double(samples.count)))
    }
    static func normalizedRMS(_ rms: Double) -> Double {
        guard rms.isFinite, rms > 0 else { return 0 }
        let decibels = 20 * log10(min(1, rms))
        return min(1, max(0, (decibels + 55) / 40))
    }
}

/// Session ownership, freshness and the prototype's asymmetric voice envelope.
/// Driven by existing bounded IPC polling, with no display link or idle frames.
struct QuietKeys {
    private(set) var sessionID: UUID?
    private(set) var level = 0.0
    private var sample: VoiceLevel?
    private var lastAdvance: Date?

    mutating func start(id: UUID, at now: Date) {
        self = QuietKeys(); sessionID = id; lastAdvance = now
    }
    mutating func reset() { self = QuietKeys() }
    mutating func advance(_ incoming: VoiceLevel?, at now: Date, reducedMotion: Bool) {
        guard let sessionID else { return }
        if let incoming, incoming.isFresh(for: sessionID, at: now),
           sample == nil || incoming.updatedAt > sample!.updatedAt { sample = incoming }
        let raw = sample.flatMap { $0.isFresh(for: sessionID, at: now) ? $0.value : nil } ?? 0
        // A gentler lift keeps ordinary speech near the center while louder
        // speech still reaches full width. This changes visuals, never PCM gain.
        let target = raw <= 0.06 ? 0 : pow((raw - 0.06) / 0.94, 0.65)
        let dt = max(0, now.timeIntervalSince(lastAdvance ?? now))
        lastAdvance = now
        if reducedMotion { level = target > 0 ? 0.24 : 0; return }
        let tau = target > level ? 0.035 : 0.14
        level += (target - level) * (1 - exp(-dt / tau))
        if abs(target - level) < 0.001 { level = target }
    }
    static func strength(level: Double, position: Double) -> Double {
        guard level > 0 else { return 0 }
        let threshold = 0.06 + abs(position - 0.5) * 2 * 0.86
        let x = min(1, max(0, (level - threshold + 0.11) / 0.22))
        return x * x * (3 - 2 * x)
    }
}
