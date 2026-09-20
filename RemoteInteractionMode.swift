import Foundation

enum RemoteInteractionMode: String, CaseIterable, Sendable {
    case audio, touch
    var toggled: Self { self == .audio ? .touch : .audio }
    var title: String { self == .audio ? "Audio & Buttons" : "Touch (Experimental)" }
    static func load() -> Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "remoteInteractionMode") ?? "") ?? .audio
    }
}

/// Only these two physical buttons may replace their generation-specific default with a
/// mode toggle. An absent mute button is never moved onto another first-generation key.
enum RemoteModeSwitchMapping {
    static let eligibleButtons: Set<String> = ["playPause", "mute"]
    static let defaultsKey = "modeSwitchButtons"
    static func usesPassiveCapture(generation: RemoteGeneration, packetLogger: Bool, mediaTap: Bool) -> Bool {
        packetLogger && mediaTap && generation != .glassTouchSurface
    }
    static func load(from defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? []).intersection(eligibleButtons)
    }
    static func action(button: String, defaultAction: ButtonAction, enabled: Set<String>) -> ButtonAction {
        eligibleButtons.contains(button) && enabled.contains(button) ? .toggleInteractionMode : defaultAction
    }
}

/// Release-triggered and device-scoped: repeats, orphan releases and another remote's
/// release cannot cause a second mode transition. A mode change clears in-flight presses.
struct RemoteModeSwitchPressTracker {
    private struct Press: Hashable { let device: UInt64; let button: String }
    private var presses: Set<Press> = []
    mutating func handle(device: UInt64, button: String, pressed: Bool, enabled: Bool) -> Bool {
        let key = Press(device: device, button: button)
        guard enabled else { presses.remove(key); return false }
        if pressed { presses.insert(key); return false }
        return presses.remove(key) != nil
    }
    mutating func reset() { presses.removeAll() }
}

/// Correlate source-less NX media events with remote-only PacketLogger observations.
/// Retain both edges because a complete quick tap can arrive before the deferred NX down.
struct RemoteMediaEventCorrelation {
    private struct Marker { let button: String; let pressed: Bool; let sender: UInt64; let time: TimeInterval }
    private var markers: [Marker] = []
    private var held: [String: (sender: UInt64, time: TimeInterval)] = [:]
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

/// Pure gesture planning, independent of the private transport and synthetic events.
struct RemoteTouchGesture {
    enum Action: Equatable { case move(Double, Double), scroll(Double), click }
    private var last: (Double, Double)?
    private var startTime = 0.0
    private var travel = 0.0
    private var previousCount = 0
    private var mayTap = false
    mutating func frame(count: Int, x: Double, y: Double, time: Double) -> Action? {
        guard count > 0 else {
            let tap = previousCount == 1 && mayTap && time - startTime < 0.3 && travel < 0.025
            last = nil; previousCount = 0; mayTap = false
            return tap ? .click : nil
        }
        defer { last = (x,y); previousCount = count }
        guard let last, previousCount == count, time >= startTime else {
            startTime = time; travel = 0; mayTap = count == 1 && previousCount == 0
            return nil
        }
        let dx = x-last.0, dy = y-last.1
        travel += hypot(dx,dy)
        guard abs(dx) < 0.25 && abs(dy) < 0.25 else { mayTap = false; return nil }
        if count == 2 { mayTap = false; return .scroll(dy * 350) }
        guard count == 1 else { mayTap = false; return nil }
        return .move(dx * 1400, -dy * 1400)
    }
}
