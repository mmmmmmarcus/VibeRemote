import Foundation
import Security

/// Only non-secret preferences use the App Group. Bundled private credentials never enter WebKit.
enum VoiceConfiguration {
    static var defaults: UserDefaults { UserDefaults(suiteName: VoiceIPC.group) ?? .standard }
    static var microphoneAllowed: Bool { defaults.bool(forKey: "voiceMicrophoneAllowed") }

    /// Host-only upgrade. Copy existing values without deleting the old keychain items.
    /// A completed migration is never replayed (in particular after removing an Ark key).
    static func migrateHostConfiguration() throws {
        guard Bundle.main.bundleIdentifier == "com.vvhisper.ios" else { return }
        let old = UserDefaults.standard
        guard !old.bool(forKey: "keyboardVoiceMigration.v1") else { return }
        // Existing Keychain items remain untouched; private builds read bundled credentials.
        for key in ["polishDictation", DictationOutputSettings.punctuationKey, "seedAppID"] {
            if defaults.object(forKey: key) == nil, let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
        }
        old.set(true, forKey: "keyboardVoiceMigration.v1")
        for file in ["ready.json", "command.json", "reply.json", "level.json", "activation.json"] { VoiceIPC.remove(file) }
    }
}

enum VoiceKeychain {
    private static func group(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.contains("$(") else { return nil }
        return value
    }
    private static func query(service: String, group: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "api-key", kSecAttrAccessGroup as String: group]
    }
    private static func data(service: String, group: String) throws -> Data? {
        var q = query(service: service, group: group); q[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw DictationError("Couldn’t read the saved voice key. Unlock your device and open vvhisper.") }
        return data
    }
    static func read(service: String) -> String? {
        guard let group = group("VVVoiceKeychainGroup"), let data = try? data(service: service, group: group) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func configurationKey(service: String) throws -> String? {
        guard let group = group("VVVoiceKeychainGroup") else { throw ConfigurationError.storage }
        guard let data = try data(service: service, group: group) else { return nil }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw ConfigurationError.storage }
        return value
    }
    static func save(_ key: String, service: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let group = group("VVVoiceKeychainGroup") else { throw DictationError("Couldn’t save the voice key.") }
        let q = query(service: service, group: group), data = Data(key.utf8)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = q; item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw DictationError("Couldn’t save the voice key.") }
        } else if status != errSecSuccess { throw DictationError("Couldn’t update the voice key.") }
    }
    static func remove(service: String) throws {
        guard let group = group("VVVoiceKeychainGroup") else { throw DictationError("Voice key storage is unavailable.") }
        let status = SecItemDelete(query(service: service, group: group) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DictationError("Couldn’t remove the voice key.") }
    }
    static func migrate(service: String) throws {
        guard let oldGroup = group("VVLegacyKeychainGroup"), let newGroup = group("VVVoiceKeychainGroup") else { throw DictationError("Voice key storage is unavailable.") }
        guard try data(service: service, group: newGroup) == nil,
              let old = try data(service: service, group: oldGroup), let key = String(data: old, encoding: .utf8) else { return }
        try save(key, service: service)
        guard try data(service: service, group: newGroup) == old else { throw DictationError("Couldn’t migrate the saved voice key.") }
    }
}
enum SeedKeychain {
    static let service = "com.vvhisper.ios.seed"
    static func read() -> String? { PrivateCredentials.key("seed") }
    static func save(_ key: String) throws { try VoiceKeychain.save(key, service: service) }

}
enum ArkPolishKeychain {
    static let service = "com.vvhisper.ios.volcengine-ark"
    static func read() -> String? { PrivateCredentials.key("ark") }
    static func save(_ key: String) throws { try VoiceKeychain.save(key, service: service) }
    static func remove() throws { try VoiceKeychain.remove(service: service) }
}
