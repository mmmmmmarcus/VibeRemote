import Foundation

/// Product-defined button behavior. Only Siri has a persisted user assignment.
enum RemoteButtonMapping {
    static func shouldAwaitMediaSource(generation: RemoteGeneration, passiveCapture: Bool) -> Bool {
        // Glass uses HID observations; aluminum's passive path keeps its single owner.
        generation != .unknown || passiveCapture
    }
    static func usesPassiveCapture(generation: RemoteGeneration, packetLogger: Bool, mediaTap: Bool) -> Bool {
        packetLogger && mediaTap && generation != .glassTouchSurface
    }
    /// `overrides` are the user's per-button choices for this generation from Settings' pills,
    /// keyed by `overrideKey`. A stored choice that is no longer offered falls back to default.
    static func action(button: String, generation: RemoteGeneration, siriAction: ButtonAction,
                       overrides: [String: ButtonAction] = [:]) -> ButtonAction {
        if let chosen = overrides[overrideKey(button)],
           choices(button: button, generation: generation)?.contains(chosen) == true {
            return chosen
        }
        return defaultAction(button: button, generation: generation, siriAction: siriAction)
    }

    static func defaultAction(button: String, generation: RemoteGeneration, siriAction: ButtonAction) -> ButtonAction {
        guard !generation.absentButtonKeys.contains(button) else { return .none }
        if button == AdvancedMenuInputState.trigger(for: generation) { return .advancedMenu }
        if button == "playPause" { return .skillPicker }
        if button == "select" {
            // During caret positioning the controller consumes this click to confirm.
            // Outside positioning only the old remote uses it as Enter (no Power key).
            return generation == .glassTouchSurface ? .enterKey : .none
        }
        let baseline = remoteButtonDescriptors.first { $0.key == button }?.defaultAction ?? .none
        return generation.action(for: button, defaultAction: baseline, siriAction: siriAction)
    }

    /// The 1st-gen Menu button reports HID "menu"; the aluminum Back reports "back". Both are
    /// the guide's "back" control, so one stored choice covers whichever usage arrives.
    static func overrideKey(_ button: String) -> String { button == "menu" ? "back" : button }

    /// Everything the user may pick for a non-Siri button, the button's own default first; nil
    /// for controls with a fixed role (Advanced Menu opener, caret confirmation, the clickpad
    /// ring, directions) and for buttons this remote does not have. Siri has its own list,
    /// `isAssignableToSiriButton`. TV only takes instant actions: its tap waits for release so
    /// a 0.5 s hold can open Computer Use, which would strand a repeat or a held key.
    static func choices(button: String, generation: RemoteGeneration) -> [ButtonAction]? {
        let button = overrideKey(button)
        guard !generation.absentButtonKeys.contains(button),
              button != AdvancedMenuInputState.trigger(for: generation),
              ["back", "tv", "playPause", "volumeUp", "volumeDown", "power"].contains(button)
        else { return nil }
        let menu: [ButtonAction] = [.enterKey, .shiftEnter, .commandEnter, .backspace, .escKey, .ctrlC,
                                    .undo, .redo, .bulletIndent, .bulletOutdent, .skillPicker,
                                    .slashSkill, .dollarSkill, .launchAgentClient, .none]
        let baseline = defaultAction(button: button, generation: generation, siriAction: .spaceKey)
        let offered = button == "tv" ? menu.filter(\.isInstant) : menu
        return [baseline] + offered.filter { $0 != baseline }
    }
}

/// NX events on this Apple Silicon Mac carry mach ticks; other event sources use
/// nanoseconds. Normalize against the current uptime without losing the original
/// event time during a blocked main run loop. Never match stale or future events.
enum RemoteMediaEventClock {
    static func uptime(timestamp: UInt64, now: TimeInterval, numer: UInt32, denom: UInt32) -> TimeInterval? {
        guard timestamp != 0 else { return now }
        guard numer > 0, denom > 0 else { return nil }
        let nanoseconds = Double(timestamp) / 1_000_000_000
        let ticks = nanoseconds * Double(numer) / Double(denom)
        return [nanoseconds, ticks]
            .filter { now - $0 >= -0.03 && now - $0 <= 3 }
            .min { abs(now - $0) < abs(now - $1) }
    }
}

/// Correlate source-less NX media events with remote-only HID or PacketLogger observations.
/// Retain both edges because a complete quick tap can arrive before the deferred NX down.
struct RemoteMediaEventCorrelation {
    private struct Marker { let button: String; let pressed: Bool; let sender: UInt64; let time: TimeInterval }
    private var markers: [Marker] = []
    private var held: [String: (sender: UInt64, time: TimeInterval)] = [:]
    func nearestDelta(button: String, pressed: Bool, now: TimeInterval) -> TimeInterval? {
        markers.filter { $0.button == button && $0.pressed == pressed }
            .map { now - $0.time }.min { abs($0) < abs($1) }
    }
    mutating func record(button: String, pressed: Bool, sender: UInt64, now: TimeInterval) {
        markers.removeAll { now - $0.time > 3 }
        markers.append(Marker(button: button, pressed: pressed, sender: sender, time: now))
        if markers.count > 32 { markers.removeFirst(markers.count - 32) }
    }
    mutating func resolve(button: String, pressed: Bool, repeating: Bool, now: TimeInterval) -> UInt64? {
        markers.removeAll { now - $0.time > 3 }
        if let index = markers.firstIndex(where: { $0.button == button && $0.pressed == pressed && now - $0.time >= -0.03 && now - $0.time <= 0.18 }) {
            let sender = markers.remove(at: index).sender
            if pressed { held[button] = (sender, now) } else { held.removeValue(forKey: button) }
            return sender
        }
        guard pressed, repeating, let hold = held[button], now - hold.time <= 5 else { return nil }
        return hold.sender
    }
}

/// Long-pressing TV opens the computer-use agent; a tap keeps TV's own action. A plain
/// Shift+Enter tap is deferred to release so the hold can become the agent instead. The
/// 1st-gen TV doubles as a modifier, so its press passes through and a chorded hold never
/// opens the agent.
struct AgentButtonGate {
    static let button = "tv"
    static let holdDuration: TimeInterval = 0.5

    enum Release: Equatable {
        /// Run the button's normal release handling.
        case passThrough
        /// The deferred press was a tap: run the press and release now.
        case tap
        /// Open the agent; `passThrough` also runs the normal release first.
        case openAgent(passThrough: Bool)
    }

    private var pressedAt: TimeInterval?
    private var deferred = false

    /// Returns true when the press must not run the button's action yet.
    mutating func press(at time: TimeInterval, defersTap: Bool) -> Bool {
        pressedAt = time
        deferred = defersTap
        return defersTap
    }

    mutating func release(at time: TimeInterval, chorded: Bool) -> Release {
        guard let start = pressedAt else { return .passThrough }
        pressedAt = nil
        let held = time - start >= Self.holdDuration
        if deferred { return held ? .openAgent(passThrough: false) : .tap }
        return held && !chorded ? .openAgent(passThrough: true) : .passThrough
    }

    mutating func reset() { pressedAt = nil; deferred = false }
}
