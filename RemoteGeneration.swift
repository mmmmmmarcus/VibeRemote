//
//  RemoteGeneration.swift
//  VibeRemote
//
//  Tells the two Siri Remote hardware families apart and captures every behavioral
//  difference between them in one place.
//

import Foundation

/// One HID interface as macOS presents it. macOS splits a HID-over-GATT remote into one
/// `IOHIDDevice` per top-level collection, so a single physical remote shows up as several
/// of these; classification therefore works on the whole set, never one interface.
struct RemoteInterfaceDescriptor: Equatable, Sendable {
    /// Identifies the *physical* remote. macOS reports the Bluetooth address here for
    /// wireless remotes and an Apple serial for one attached over Lightning.
    let deviceKey: String
    let productName: String?
    let productID: Int
    let transport: String?
    let usagePage: Int
    let usage: Int
    let maxInputReportSize: Int
    let maxFeatureReportSize: Int
    var hardwareRevision: String? = nil

    var isBluetooth: Bool {
        transport?.lowercased().contains("bluetooth") ?? false
    }
}

/// How long the 1st-generation remote stays awake after its most recent button press.
/// The newer remote keeps its firmware-managed connection behavior and never enters this path.
enum FirstGenerationIdleTimeout: Int, CaseIterable, Sendable {
    case fiveMinutes = 300
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case never = 0

    static let defaultsKey = "firstGenerationIdleTimeoutSeconds"
    static let defaultValue: FirstGenerationIdleTimeout = .fiveMinutes

    var title: String {
        switch self {
        case .fiveMinutes: return "After 5 Minutes"
        case .fifteenMinutes: return "After 15 Minutes"
        case .thirtyMinutes: return "After 30 Minutes"
        case .never: return "Never"
        }
    }

    var interval: TimeInterval? {
        self == .never ? nil : TimeInterval(rawValue)
    }

    static func load(from defaults: UserDefaults = .standard) -> FirstGenerationIdleTimeout {
        guard defaults.object(forKey: defaultsKey) != nil,
              let value = FirstGenerationIdleTimeout(rawValue: defaults.integer(forKey: defaultsKey)) else {
            return defaultValue
        }
        return value
    }
}

/// Per-physical-remote idle state. Interfaces for one remote arrive independently, so the
/// tracker keys by Bluetooth address and emits at most one disconnect request per idle period.
struct FirstGenerationIdleTracker: Sendable {
    private struct Entry: Sendable {
        var lastActivity: TimeInterval
        var disconnectRequested = false
    }

    private var entries: [String: Entry] = [:]

    mutating func synchronize(deviceKeys: Set<String>, now: TimeInterval) {
        entries = entries.filter { deviceKeys.contains($0.key) }
        for key in deviceKeys where entries[key] == nil {
            entries[key] = Entry(lastActivity: now)
        }
    }

    mutating func recordActivity(deviceKey: String, now: TimeInterval) {
        entries[deviceKey] = Entry(lastActivity: now)
    }

    mutating func reset(now: TimeInterval) {
        for key in entries.keys {
            entries[key] = Entry(lastActivity: now)
        }
    }

    mutating func takeDueDisconnects(now: TimeInterval, timeout: TimeInterval?) -> [String] {
        guard let timeout else { return [] }
        var due: [String] = []
        for (key, entry) in entries where !entry.disconnectRequested && now - entry.lastActivity >= timeout {
            entries[key]?.disconnectRequested = true
            due.append(key)
        }
        return due.sorted()
    }

    func shouldKeepAlive(deviceKey: String) -> Bool {
        entries[deviceKey]?.disconnectRequested == false
    }

    var isEmpty: Bool { entries.isEmpty }
}

/// The two Siri Remote hardware families VibeRemote supports.
///
/// Button profiles differ by generation. Audio collection availability must also be checked
/// per physical device; report size alone is not a reliable generation discriminator.
enum RemoteGeneration: String, Sendable, CaseIterable {
    /// 1st generation — A1513 / A1844, thin aluminum body with the black glass touch
    /// surface. Six buttons: Menu, TV/Home, Play/Pause, Siri, Volume Up, Volume Down.
    /// No Power button and no Mute button.
    case glassTouchSurface

    /// 2nd/3rd generation — A2540 / A2859, thicker body with the aluminum clickpad ring.
    /// Adds Power and Mute and moves Siri to the side of the remote.
    case aluminumClickpad

    /// Nothing is connected, or the interface set does not look like either family. Treated
    /// as the newer remote everywhere a decision is forced, because that path degrades
    /// gracefully on older hardware while the reverse does not.
    case unknown

    var displayName: String {
        switch self {
        case .glassTouchSurface: return "1st-gen Siri Remote (glass touch surface)"
        case .aluminumClickpad: return "2nd/3rd-gen Siri Remote (aluminum clickpad)"
        case .unknown: return "Siri Remote (generation unknown)"
        }
    }

    var shortName: String {
        switch self {
        case .glassTouchSurface: return "1st-gen"
        case .aluminumClickpad: return "2nd/3rd-gen"
        case .unknown: return "unknown"
        }
    }

    /// Whether this remote has a physical Mute button. The 1st-gen remote does not, so its
    /// button profile moves the mute button's roles onto TV and Play/Pause.
    var hasMuteButton: Bool { self != .glassTouchSurface }

    /// Whether this remote has a physical Power button. The 1st-gen remote does not.
    var hasPowerButton: Bool { self != .glassTouchSurface }
}

extension RemoteGeneration {
    /// How the remote's microphone audio reaches us.
    enum MicrophoneTransport: String, Sendable {
        /// Prefer the dedicated Consumer/0x04 collection. This describes the attempted HID
        /// path, not proof that macOS delivers voice reports to user space.
        case directHIDAudioCollection

        /// Fallback for old remotes without a dedicated collection. The input handler checks
        /// actual collections first; confirmed hardware 0A00 also exposes Consumer/0x04.
        case hidReportSniffing
    }

    var microphoneTransport: MicrophoneTransport {
        switch self {
        case .glassTouchSurface: return .hidReportSniffing
        case .aluminumClickpad, .unknown: return .directHIDAudioCollection
        }
    }

    /// Smallest input report worth feeding to the audio parser. Button reports on the 1st-gen
    /// remote are 2–4 bytes; a 20 ms wideband Opus frame plus its length byte never is.
    static let minimumSniffedReportSize = 16
}

// MARK: - Button profile

extension RemoteGeneration {
    /// How this remote's buttons differ from the 2nd/3rd-gen baseline in
    /// `remoteButtonDescriptors`. Missing-button roles are reassigned here.
    ///
    /// The 1st-gen remote is missing Power and Mute:
    /// - Power is absent; the touch surface keeps the baseline Enter action.
    /// - Mute was the tap-"/"-or-hold-modifier key, and both of its jobs have to go somewhere.
    ///   The modifier moves to TV and the "/" moves to Play/Pause, because those two are the
    ///   only buttons whose baseline action is a single instantaneous press with no hold
    ///   behavior of its own — so adding one is free rather than a trade.
    ///
    ///   TV      → tap: Shift+Enter (unchanged) · hold: modifier (TV+Menu clears the input,
    ///             TV+Play/Pause sends Esc — the same chords the mute button armed)
    ///   Play/Pause → tap: toggle the agent client (unchanged) · hold: type "/"
    ///
    /// Only the physical Siri button uses the configurable action. The touch surface
    /// remains Enter; remapping it cannot enable the firmware-gated microphone.
    var buttonActionOverrides: [String: ButtonAction] {
        switch self {
        case .glassTouchSurface:
            return [
                "tv": .shiftEnterOrModifier,
                "playPause": .agentClientOrSlash,
            ]
        case .aluminumClickpad, .unknown:
            return [:]
        }
    }

    /// Resolve the configurable action for the physical source remote, including when both
    /// generations are connected. Keep the physical button name for release bookkeeping.
    func action(for button: String, defaultAction: ButtonAction, siriAction: ButtonAction) -> ButtonAction {
        if button == "siri" {
            return siriAction
        }
        return buttonActionOverrides[button] ?? defaultAction
    }

    /// Buttons this remote does not have, so the menu can stop advertising them.
    var absentButtonKeys: Set<String> {
        switch self {
        case .glassTouchSurface: return ["mute", "power"]
        case .aluminumClickpad, .unknown: return []
        }
    }
}

// MARK: - Classification

extension RemoteGeneration {
    /// Report size is only a fallback: macOS also advertises 209-byte proxy reports on
    /// the physically confirmed black-glass remote (product 0x026D, hardware 0A00).
    static let largeReportThreshold = 64

    /// Classify one physical remote from all of its HID interfaces.
    static func classify(interfaces: [RemoteInterfaceDescriptor]) -> RemoteGeneration {
        // Lightning charging interfaces have no usable buttons, regardless of report size
        // or a recognized hardware revision. They must never become the active remote.
        let wireless = interfaces.filter { $0.isBluetooth }
        guard !wireless.isEmpty else { return .unknown }

        // Observed on the user's black-glass remote on 2026-09-13, including the 209-byte
        // Consumer audio collection. Do not generalize the revision to other product IDs.
        if wireless.contains(where: {
            $0.productID == 0x026D && $0.hardwareRevision?.uppercased() == "0A00"
        }) {
            return .glassTouchSurface
        }

        if wireless.contains(where: { $0.maxInputReportSize >= largeReportThreshold })
            || wireless.contains(where: { $0.maxFeatureReportSize >= largeReportThreshold }) {
            return .aluminumClickpad
        }
        return .glassTouchSurface
    }

    /// Classify every physical remote in a mixed interface list, keyed by `deviceKey`.
    static func classifyAll(
        interfaces: [RemoteInterfaceDescriptor]
    ) -> [String: RemoteGeneration] {
        Dictionary(grouping: interfaces, by: { $0.deviceKey })
            .mapValues { classify(interfaces: $0) }
    }

    /// The remote the app should treat as active when several are attached at once — which is
    /// the normal state while testing, with one remote paired over Bluetooth and another
    /// plugged in to charge. A wireless remote always wins; a cabled one is never usable.
    static func primary(interfaces: [RemoteInterfaceDescriptor]) -> RemoteGeneration {
        let groups = Dictionary(grouping: interfaces, by: { $0.deviceKey })
        let ranked = groups
            .map { (key: $0.key, interfaces: $0.value, generation: classify(interfaces: $0.value)) }
            .filter { $0.generation != .unknown }
            .sorted { left, right in
                let leftWireless = left.interfaces.contains { $0.isBluetooth }
                let rightWireless = right.interfaces.contains { $0.isBluetooth }
                if leftWireless != rightWireless { return leftWireless }
                if left.interfaces.count != right.interfaces.count {
                    return left.interfaces.count > right.interfaces.count
                }
                return left.key < right.key
            }
        return ranked.first?.generation ?? .unknown
    }
}
