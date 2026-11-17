import Foundation

/// A bounded ready session, measured from microphone activation, never from a hold.
struct VoiceSessionLifetime {
    let startedAt: Date
    var minutes: Int
    var expiresAt: Date { startedAt.addingTimeInterval(TimeInterval(KeyboardPreferences.normalizedSessionMinutes(minutes) * 60)) }
    func hasExpired(at now: Date) -> Bool { now >= expiresAt }
}
