import Foundation
import Security

/// Host-only preferences and credentials. Never shared with the keyboard.
struct DictationPolishSettings {
    var enabled = true
    static func load(_ defaults: UserDefaults = .standard) -> Self {
        var settings = Self()
        settings.enabled = defaults.object(forKey: "polishDictation") as? Bool ?? true
        return settings
    }
    func save(_ defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: "polishDictation")
    }
}

enum ArkPolishKeychain {
    // A different provider: never read, migrate, or fall back to ASR/OpenRouter keys.
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.vvhisper.ios.volcengine-ark", kSecAttrAccount as String: "api-key"]
    }
    static func read() -> String? {
        var query = query; query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw DictationError("Enter an API key.") }
        let data = Data(key.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw DictationError("Couldn’t save your key.") }
        } else if status != errSecSuccess { throw DictationError("Couldn’t save your key.") }
    }
    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DictationError("Couldn’t remove your key.") }
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
