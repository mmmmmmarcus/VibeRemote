import Foundation

/// Device families have independent settings, shared by the app and user-session voice helper.
public enum VoiceInputDevice: String, CaseIterable, Sendable {
    case siriGlass, siriAluminum, soundcore
    public var enabledKey: String { "voiceReleaseBuffer.\(rawValue).enabled" }
    public var durationKey: String { "voiceReleaseBuffer.\(rawValue).seconds" }
}

public struct VoiceReleaseBuffer: Equatable, Sendable {
    public static let range: ClosedRange<TimeInterval> = 0.1...2
    public let enabled: Bool
    public let duration: TimeInterval
    public var effectiveDuration: TimeInterval { enabled ? duration : 0 }

    public init(enabled: Bool = true, duration: TimeInterval = 1) {
        self.enabled = enabled
        self.duration = Self.range.contains(duration) ? (duration * 10).rounded() / 10 : 1
    }
    public static func load(_ device: VoiceInputDevice, defaults: UserDefaults = .standard) -> Self {
        Self(enabled: defaults.object(forKey: device.enabledKey) == nil ? true : defaults.bool(forKey: device.enabledKey),
             duration: defaults.object(forKey: device.durationKey) == nil ? 1 : defaults.double(forKey: device.durationKey))
    }
}

/// A cancelled or superseded timer must never stop a later microphone hold.
public struct VoiceReleaseCountdown {
    public init() {}
    public private(set) var token: UUID?
    public private(set) var deadline: TimeInterval?
    public mutating func begin(now: TimeInterval, duration: TimeInterval) -> UUID? {
        guard token == nil else { return nil }
        let next = UUID()
        token = next
        deadline = now + max(0, duration)
        return next
    }
    @discardableResult public mutating func cancel() -> Bool {
        let pending = token != nil
        token = nil; deadline = nil
        return pending
    }
    public mutating func consume(_ expected: UUID, now: TimeInterval) -> Bool {
        guard token == expected, let deadline, now >= deadline else { return false }
        cancel()
        return true
    }
}
