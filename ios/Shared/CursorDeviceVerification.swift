#if DEBUG
import Foundation

/// Explicit local QA only. Synthetic fixture, no user text or coordinates are stored.
enum CursorDeviceVerification {
    struct Request: Codable {
        let id: UUID
        let createdAt: Date
        var legacyAcknowledgement = false
        var fixture: String { "vvhisper \(id.uuidString.prefix(8)) 0123456789" }
        var isFresh: Bool { Date().timeIntervalSince(createdAt) < 20 }
    }
    struct Result: Codable {
        let id: UUID
        let heldAfterPause: Bool
        let released: Bool
        let events: [String]
        var customHapticPlayed: Bool?
        var hapticErrorCode: Int?
    }
    struct Report: Codable {
        let id: UUID
        let heldAfterPause: Bool
        let released: Bool
        let textUnchanged: Bool
        let expectedCaret: Int
        let actualCaret: Int
        let timedOut: Bool
        let events: [String]
        var customHapticPlayed: Bool?
        var hapticErrorCode: Int?
        var passed: Bool { heldAfterPause && released && textUnchanged && expectedCaret == actualCaret && !timedOut }
    }
}
#endif
