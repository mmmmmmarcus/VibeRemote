import Foundation

/// Shared non-secret preferences, latched once per hold.
struct DictationPolishSettings {
    var enabled = true
    static func load(_ defaults: UserDefaults = VoiceConfiguration.defaults) -> Self {
        var settings = Self()
        settings.enabled = defaults.object(forKey: "polishDictation") as? Bool ?? true
        return settings
    }
    func save(_ defaults: UserDefaults = VoiceConfiguration.defaults) {
        defaults.set(enabled, forKey: "polishDictation")
    }
}

/// Cancelled or superseded requests never invoke their completion, even if a
/// transport ignores cancellation. Document ownership is rechecked by the keyboard.
@MainActor final class DictationPolishSession {
    private var task: Task<Void, Never>?
    private var generation = UUID()
    func start(text: String, settings: DictationPolishSettings, key: String?, translate: Bool = false,
               load: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await DictationPolisher.session.data(for: $0) },
               completion: @escaping (DictationPolisher.Result) -> Void) {
        cancel()
        let generation = generation
        task = Task { [weak self] in
            let result = await DictationPolisher.polish(text, enabled: settings.enabled, key: key, translate: translate, load: load)
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            self.task = nil; completion(result)
        }
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil }
    isolated deinit { task?.cancel() }
}
