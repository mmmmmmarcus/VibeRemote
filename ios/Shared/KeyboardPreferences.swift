import Foundation

struct KeyboardPreferences: Codable, Equatable {
    var hapticStrength = 0.45
    var mixedTypingEnabled = false
    var voiceSessionMinutes = 15
    static let voiceSessionChoices = [1, 5, 10, 15, 30, 60]

    init(hapticStrength: Double = 0.45, mixedTypingEnabled: Bool = false, voiceSessionMinutes: Int = 15) {
        self.hapticStrength = Self.normalizedStrength(hapticStrength)
        self.mixedTypingEnabled = mixedTypingEnabled
        self.voiceSessionMinutes = Self.normalizedSessionMinutes(voiceSessionMinutes)
    }

    private enum CodingKeys: String, CodingKey { case hapticStrength, mixedTypingEnabled, voiceSessionMinutes }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hapticStrength = Self.normalizedStrength(try values.decodeIfPresent(Double.self, forKey: .hapticStrength) ?? 0.45)
        // Existing installations have only hapticStrength. Never opt them into an experiment.
        mixedTypingEnabled = try values.decodeIfPresent(Bool.self, forKey: .mixedTypingEnabled) ?? false
        voiceSessionMinutes = Self.normalizedSessionMinutes(try values.decodeIfPresent(Int.self, forKey: .voiceSessionMinutes) ?? 15)
    }

    static func normalizedSessionMinutes(_ value: Int) -> Int {
        voiceSessionChoices.contains(value) ? value : 15
    }
    var voiceSessionTitle: String { "\(voiceSessionMinutes) \(voiceSessionMinutes == 1 ? "minute" : "minutes")" }

    static func normalizedStrength(_ value: Double) -> Double {
        guard value.isFinite else { return 0.45 }
        return (min(1, max(0, value)) * 20).rounded() / 20
    }

    static func load() -> KeyboardPreferences {
        var settings = VoiceIPC.read("keyboard-settings.json", as: Self.self) ?? Self()
        settings.hapticStrength = normalizedStrength(settings.hapticStrength)
        settings.voiceSessionMinutes = normalizedSessionMinutes(settings.voiceSessionMinutes)
        return settings
    }

    func save() throws {
        var settings = self
        settings.hapticStrength = Self.normalizedStrength(hapticStrength)
        settings.voiceSessionMinutes = Self.normalizedSessionMinutes(voiceSessionMinutes)
        try VoiceIPC.write(settings, to: "keyboard-settings.json")
    }
}
