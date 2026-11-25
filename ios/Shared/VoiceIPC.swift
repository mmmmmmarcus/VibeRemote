import Foundation

struct VoiceCommand: Codable, Equatable {
    enum Phase: String, Codable { case recording, finish, cancel }
    var id: UUID
    var phase: Phase
    var updatedAt: Date
    // Only a release over the language key opts this hold into translation.
    // Optional for compatibility with commands from an older installed extension.
    var translate: Bool? = nil
}
struct VoiceReply: Codable {
    // Outer bound only: 1.5–5 s of final ASR, one ≤6 s retry, ≤3 s polishing
    // (≤8 s translation), plus IPC margin. KeyboardVoiceSession.Budget owns the steps.
    static let finalWait: TimeInterval = 25
    var id: UUID
    var text: String
    var isFinal: Bool
    var error: String?
    var updatedAt = Date()
    var polishing: Bool?
    var notice: String?
}
struct VoiceReadiness: Codable {
    var ready: Bool
    var updatedAt = Date()
    var expiresAt: Date
    var isFresh: Bool { ready && Date().timeIntervalSince(updatedAt) < 2 && expiresAt > Date() }
}

/// A short-lived request to arm the host microphone, never to start recording.
/// The URL carries only a nonce; the matching request must exist in our App Group.
struct VoiceActivationRequest: Codable, Equatable {
    var id = UUID()
    var createdAt = Date()
    var returnBundleIdentifier: String?
    var returnDestination: String? {
        guard let value = returnBundleIdentifier, (3...255).contains(value.utf8.count),
              value.contains("."), value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_").contains($0) }),
              !value.hasPrefix("com.apple.UIKit"),
              !["com.vvhisper.ios", "com.vvhisper.ios.keyboard", "com.apple.springboard", "com.apple.backboardd"].contains(value) else { return nil }
        return value
    }
    func isFresh(at now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(createdAt)
        return age >= 0 && age < 10
    }
    var url: URL { URL(string: "vvhisper://voice?request=\(id.uuidString)")! }
    func accepts(_ url: URL, at now: Date = Date()) -> Bool {
        guard isFresh(at: now), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "vvhisper", parts.host == "voice", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              parts.queryItems?.count == 1, let item = parts.queryItems?.first else { return false }
        return item.name == "request" && item.value == id.uuidString
    }
}
/// Each file has one writer. Atomic replacement prevents readers observing partial JSON.
/// Credentials and audio never cross this boundary.
enum VoiceIPC {
    static let group = "group.com.vvhisper.ios"
    static var root: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) }
    static func read<T: Decodable>(_ name: String, as: T.Type) -> T? {
        guard let url = root?.appendingPathComponent(name), let data = try? Data(contentsOf: url), data.count < 131_072 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    static func write<T: Encodable>(_ object: T, to name: String) throws {
        guard let root else { throw CocoaError(.fileNoSuchFile) }
        let data = try JSONEncoder().encode(object)
        try data.write(to: root.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func remove(_ name: String) { if let url = root?.appendingPathComponent(name) { try? FileManager.default.removeItem(at: url) } }
}

/// Tap commits on release; crossing the threshold consumes the tap entirely.
struct HoldGate {
    static let threshold = 0.38
    private(set) var pressedAt: TimeInterval?
    private(set) var isHolding = false
    mutating func press(at time: TimeInterval) { pressedAt = time; isHolding = false }
    mutating func advance(to time: TimeInterval) -> Bool {
        guard let pressedAt, !isHolding, time - pressedAt >= Self.threshold else { return false }
        isHolding = true
        return true
    }
    mutating func release() -> Bool {
        let isTap = pressedAt != nil && !isHolding
        pressedAt = nil; isHolding = false
        return isTap
    }
    mutating func cancel() { pressedAt = nil; isHolding = false }
}
