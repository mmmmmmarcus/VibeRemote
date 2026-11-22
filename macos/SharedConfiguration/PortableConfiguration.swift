import Foundation

/// Versioned, platform-independent transfer document. Credentials are optional and never logged.
struct PortableConfiguration: Codable, Equatable, Sendable {
    var format = "vvhisper"
    var version = 1
    var settings: Settings
    var credentials: Credentials?
    struct Settings: Codable, Equatable, Sendable {
        var polishDictation: Bool?
        var sentencePunctuation: Bool?
    }
    struct Credentials: Codable, Equatable, Sendable {
        var seedASR: String?
        var polishing: String?
    }
    static let maximumBytes = 65_536
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw ConfigurationError.invalidFile }
        guard let value = try? JSONDecoder().decode(Self.self, from: data),
              value.format == "vvhisper", value.version == 1 else { throw ConfigurationError.invalidFile }
        for key in [value.credentials?.seedASR, value.credentials?.polishing].compactMap({ $0 }) {
            guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  key.utf8.count <= 8192, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else {
                throw ConfigurationError.invalidFile
            }
        }
        return value
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        _ = try Self.decode(data)
        return data
    }
}

enum ConfigurationError: LocalizedError, Equatable {
    case invalidFile, storage, rollback, passwordLength, decryption, fileAccess, conflict
    var errorDescription: String? {
        switch self {
        case .passwordLength: return "Use a password of 8–256 characters. A long, unique passphrase is recommended."
        case .decryption: return "The password is incorrect or the encrypted file was changed. No settings were imported."
        case .fileAccess: return "The sync file is unavailable. Download it in Files or Finder, or choose it again. Your local keys still work."
        case .conflict: return "The file changed or has unresolved cloud versions. Sync paused to protect your settings. Review the file and try again."
        case .invalidFile: return "This is not a supported vvhisper config.json file. No settings were changed."
        case .storage: return "Couldn’t save the configuration securely. Existing settings were retained."
        case .rollback: return "A key could not be restored after a storage error. Check both saved keys before dictating."
        }
    }
}
