import Foundation

/// Shared, independent of optional LLM polishing. Capture once per hold.
struct DictationOutputSettings {
    static let punctuationKey = DictationSentencePunctuation.preferenceKey
    var sentencePunctuation = true

    static func load(_ defaults: UserDefaults = VoiceConfiguration.defaults) -> Self {
        Self(sentencePunctuation: defaults.object(forKey: punctuationKey) as? Bool ?? true)
    }
    func save(_ defaults: UserDefaults = VoiceConfiguration.defaults) {
        defaults.set(sentencePunctuation, forKey: Self.punctuationKey)
    }
    func finalize(_ text: String) -> String {
        DictationSentencePunctuation.apply(text, enabled: sentencePunctuation)
    }
}
