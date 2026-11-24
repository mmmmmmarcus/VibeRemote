import Foundation

@MainActor
enum MobileConfiguration {
    static let sync = ConfigurationSync(defaults: VoiceConfiguration.defaults, transfersCredentials: false, read: { role in
        switch role {
        case .seedASR: return try VoiceKeychain.configurationKey(service: SeedKeychain.service)
        case .polishing: return try VoiceKeychain.configurationKey(service: ArkPolishKeychain.service)
        case .polishDictation: return String(DictationPolishSettings.load().enabled)
        case .sentencePunctuation: return String(DictationOutputSettings.load().sentencePunctuation)
        }
    }, write: { role, value in
        switch role {
        case .seedASR:
            if let value { try SeedKeychain.save(value) } else { try VoiceKeychain.remove(service: SeedKeychain.service) }
        case .polishing:
            if let value { try ArkPolishKeychain.save(value) } else { try ArkPolishKeychain.remove() }
        case .polishDictation, .sentencePunctuation:
            guard let value, ["true", "false"].contains(value) else { throw ConfigurationError.storage }
            VoiceConfiguration.defaults.set(value == "true", forKey: role == .polishDictation ? "polishDictation" : DictationOutputSettings.punctuationKey)
        }
    })
}
