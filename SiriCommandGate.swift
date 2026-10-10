import Foundation

/// A short Siri tap opens Command; a hold retains the configured dictation action.
/// Menu/caret ownership is resolved before starting this gate. Once owned, both
/// edges remain here even when focus or menu visibility changes during a hold.
@MainActor
final class SiriCommandGate {
    static let holdDelay: TimeInterval = 0.25
    private struct Press {
        let beganAt: TimeInterval
        let physicalStart: Date
        let generation: RemoteGeneration
        let timer: DispatchWorkItem
        var forwarded = false
    }
    private var presses: [String: Press] = [:]
    var openCommand: (() -> Void)?
    var holdEdge: ((Bool, RemoteGeneration, Date) -> Void)?
    func owns(device: String) -> Bool { presses[device] != nil }

    func handle(button: String, pressed: Bool, device: String, generation: RemoteGeneration,
                now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard button == "siri" else { return false }
        if pressed {
            if presses[device] != nil { return true }
            let timer = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, var entry = self.presses[device], !entry.forwarded else { return }
                    entry.forwarded = true; self.presses[device] = entry
                    self.holdEdge?(true, entry.generation, entry.physicalStart)
                }
            }
            presses[device] = Press(beganAt: now, physicalStart: Date(), generation: generation, timer: timer)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDelay, execute: timer)
            return true
        }
        guard let entry = presses.removeValue(forKey: device) else { return false }
        entry.timer.cancel()
        if entry.forwarded {
            holdEdge?(false, entry.generation, entry.physicalStart)
        } else if now - entry.beganAt >= Self.holdDelay {
            // A delayed main run loop must not reinterpret a hold as a tap.
            holdEdge?(true, entry.generation, entry.physicalStart)
            holdEdge?(false, entry.generation, entry.physicalStart)
        } else { openCommand?() }
        return true
    }
    func reset() {
        let outgoing = presses; presses.removeAll()
        for entry in outgoing.values {
            entry.timer.cancel()
            if entry.forwarded { holdEdge?(false, entry.generation, entry.physicalStart) }
        }
    }
}
