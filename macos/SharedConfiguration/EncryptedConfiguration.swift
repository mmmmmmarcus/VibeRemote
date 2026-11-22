import Foundation
import CryptoKit
import CommonCrypto
import Security

/// Portable v1 envelope. Password bytes are UTF-8, without trimming or normalization.
/// AES-256-GCM, PBKDF2-HMAC-SHA256/600000, fresh 16-byte salt and 12-byte nonce.
enum EncryptedConfiguration {
    static let maximumBytes = 131_072
    static let rounds = 600_000
    static let authenticatedData = Data("vvhisper-config:v1".utf8)
    struct Envelope: Codable {
        var format = "vvhisper.encrypted"
        var version = 1
        var kdf = "pbkdf2-sha256"
        var iterations = rounds
        var cipher = "aes-256-gcm"
        var salt: Data
        var nonce: Data
        /// Ciphertext followed by the 16-byte authentication tag.
        var ciphertext: Data
    }
    static func validatePassword(_ password: String) throws {
        guard (8...256).contains(password.unicodeScalars.count) else { throw ConfigurationError.passwordLength }
    }
    private static func random(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw ConfigurationError.storage }
        return Data(bytes)
    }
    private static func key(_ password: String, salt: Data) throws -> SymmetricKey {
        try validatePassword(password)
        let bytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeBytes { pass in
            salt.withUnsafeBytes { salt in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                    pass.baseAddress!.assumingMemoryBound(to: Int8.self), bytes.count,
                    salt.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw ConfigurationError.storage }
        defer { _ = derived.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        return SymmetricKey(data: derived)
    }
    static func seal(_ document: PortableConfiguration, password: String) throws -> Data {
        let salt = try random(16), nonce = try random(12)
        let box = try AES.GCM.seal(document.encoded(), using: key(password, salt: salt),
                                   nonce: AES.GCM.Nonce(data: nonce), authenticating: authenticatedData)
        let envelope = Envelope(salt: salt, nonce: nonce, ciphertext: box.ciphertext + box.tag)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }
    static func open(_ data: Data, password: String) throws -> PortableConfiguration {
        guard data.count <= maximumBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.format == "vvhisper.encrypted", envelope.version == 1,
              envelope.kdf == "pbkdf2-sha256", envelope.iterations == rounds,
              envelope.cipher == "aes-256-gcm", envelope.salt.count == 16,
              envelope.nonce.count == 12, envelope.ciphertext.count >= 16,
              envelope.ciphertext.count <= PortableConfiguration.maximumBytes + 16 else { throw ConfigurationError.invalidFile }
        let derived = try key(password, salt: envelope.salt)
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: envelope.nonce),
                ciphertext: envelope.ciphertext.dropLast(16), tag: envelope.ciphertext.suffix(16))
            plaintext = try AES.GCM.open(box, using: derived, authenticating: authenticatedData)
        } catch { throw ConfigurationError.decryption }
        return try PortableConfiguration.decode(plaintext)
    }
}
