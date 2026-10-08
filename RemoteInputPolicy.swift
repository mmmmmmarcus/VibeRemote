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
    static func action(button: String, generation: RemoteGeneration, siriAction: ButtonAction) -> ButtonAction {
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
