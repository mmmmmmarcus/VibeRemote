import Foundation
import Security
import CryptoKit

enum ConfigurationFile {
    static func bookmark(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }
    static func resolve(_ bookmark: Data) throws -> (url: URL, bookmark: Data) {
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        return (url, stale ? try self.bookmark(url) : bookmark)
    }
    static func boundedRead(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: EncryptedConfiguration.maximumBytes + 1) ?? Data()
        guard data.count <= EncryptedConfiguration.maximumBytes else { throw ConfigurationError.invalidFile }
        return data
    }
    static func read(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(ConfigurationError.fileAccess)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
            result = Result {
                guard NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinated)?.isEmpty != false else { throw ConfigurationError.conflict }
                return try boundedRead(coordinated)
            }
        }
        if coordinationError != nil { throw ConfigurationError.fileAccess }
        return try result.get()
    }
    /// Compare under the coordination lock. Never overwrite a newer file.
    static func write(_ data: Data, to url: URL, expected: Data?) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<Void, Error> = .failure(ConfigurationError.fileAccess)
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            result = Result {
                guard NSFileVersion.unresolvedConflictVersionsOfItem(at: coordinated)?.isEmpty != false else { throw ConfigurationError.conflict }
                if let expected, try boundedRead(coordinated) != expected { throw ConfigurationError.conflict }
                try data.write(to: coordinated, options: .atomic)
                #if os(macOS)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: coordinated.path)
                #endif
            }
        }
        if coordinationError != nil { throw ConfigurationError.fileAccess }
        try result.get()
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Password storage is local only. Existing ASR/Ark Keychain items are untouched.
enum ConfigurationFilePassword {
    private static func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.vvhisper.configuration.file-password",
            kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
        #if os(iOS)
        if let group = Bundle.main.object(forInfoDictionaryKey: "VVVoiceKeychainGroup") as? String {
            query[kSecAttrAccessGroup as String] = group
        }
        #endif
        return query
    }
    static func read(_ account: String) throws -> String {
        var query = query(account); query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let password = String(data: data, encoding: .utf8) else { throw ConfigurationError.fileAccess }
        return password
    }
    static func save(_ password: String, account: String) throws {
        let query = query(account), data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw ConfigurationError.storage }
        } else if status != errSecSuccess { throw ConfigurationError.storage }
    }
    static func remove(_ account: String) { SecItemDelete(query(account) as CFDictionary) }
}

/// Three-way, field-level merge. Missing fields never delete credentials.
enum ConfigurationMerge {
    enum Resolution { case automatic, local, file }
    static func values(_ document: PortableConfiguration) -> [String: String] {
        var values: [String: String] = [:]
        values["seedASR"] = document.credentials?.seedASR
        values["polishing"] = document.credentials?.polishing
        values["polishDictation"] = document.settings.polishDictation.map(String.init)
        values["sentencePunctuation"] = document.settings.sentencePunctuation.map(String.init)
        return values
    }
    static func hashes(_ document: PortableConfiguration) -> [String: String] {
        values(document).mapValues { ConfigurationFile.digest(Data($0.utf8)) }
    }
    static func merge(local: PortableConfiguration, file: PortableConfiguration,
                      baseline: [String: String], resolution: Resolution) throws -> PortableConfiguration {
        let localValues = values(local), remoteValues = values(file)
        var result = localValues
        for (field, remote) in remoteValues {
            guard let local = localValues[field], local != remote else { result[field] = remote; continue }
            switch resolution {
            case .local: break
            case .file: result[field] = remote
            case .automatic:
                let old = baseline[field]
                if old == nil {
                    if field == "seedASR" || field == "polishing" { throw ConfigurationError.conflict }
                    result[field] = remote
                } else {
                    let localChanged = old != ConfigurationFile.digest(Data(local.utf8))
                    let remoteChanged = old != ConfigurationFile.digest(Data(remote.utf8))
                    if localChanged && remoteChanged { throw ConfigurationError.conflict }
                    if remoteChanged { result[field] = remote }
                }
            }
        }
        return PortableConfiguration(settings: .init(polishDictation: result["polishDictation"].map { $0 == "true" },
                                                     sentencePunctuation: result["sentencePunctuation"].map { $0 == "true" }),
                                     credentials: .init(seedASR: result["seedASR"], polishing: result["polishing"]))
    }
}
