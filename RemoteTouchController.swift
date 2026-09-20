import AppKit
import ApplicationServices
import NativeTouch

@MainActor
final class RemoteTouchController {
    static weak var active: RemoteTouchController?
    private var enabled = false
    private var retry: Timer?
    private var gestures: [UInt64: RemoteTouchGesture] = [:]
    private var lastFrameAt = Date.distantPast
    var onStatus: ((Bool, String) -> Void)?

    func start() {
        stop(); enabled = true; Self.active = self
        attach()
        retry = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.enabled, Date().timeIntervalSince(self.lastFrameAt) > 5 else { return }
                self.attach()
            }
        }
    }
    func stop() {
        enabled = false; retry?.invalidate(); retry = nil
        vr_touch_stop(); gestures.removeAll(); Self.active = nil
    }
    private func attach() {
        guard AXIsProcessTrusted() else { onStatus?(false,"Touch needs Accessibility permission"); return }
        gestures.removeAll()
        let count = vr_touch_start { device, count, x, y, timestamp in
            // Copy scalar data before the framework recycles its frame buffer.
            DispatchQueue.main.async {
                RemoteTouchController.active?.frame(device: device, count: Int(count), x: Double(x), y: Double(y), time: timestamp)
            }
        }
        onStatus?(count > 0, count > 0 ? "Touch ready · slide to move, tap to click" : (count < 0 ? "Touch API unavailable" : "Waiting for a remote touch surface"))
        rmDebug("🖐 Touch surfaces attached: \(count)")
    }
    private func frame(device: UInt64, count: Int, x: Double, y: Double, time: Double) {
        guard enabled else { return }
        if Date().timeIntervalSince(lastFrameAt) > 5 { rmDebug("🖐 Touch frames received") }
        lastFrameAt = Date()
        let action = gestures[device, default: RemoteTouchGesture()].frame(count: count, x: x, y: y, time: time)
        guard let action, let location = CGEvent(source: nil)?.location else { return }
        switch action {
        case .move(let dx, let dy):
            let proposed = CGPoint(x: location.x+dx,y:location.y+dy)
            let screenIDs = NSScreen.screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
            let frames = screenIDs.map { CGDisplayBounds($0) }
            let target = frames.contains(where: { $0.contains(proposed) }) ? proposed : frames.map { rect in
                CGPoint(x: min(max(proposed.x,rect.minX),rect.maxX-1), y: min(max(proposed.y,rect.minY),rect.maxY-1))
            }.min(by: { hypot($0.x-proposed.x,$0.y-proposed.y) < hypot($1.x-proposed.x,$1.y-proposed.y) }) ?? location
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)?.post(tap: .cghidEventTap)
        case .scroll(let pixels):
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(pixels), wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
        case .click:
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }
}
