import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Passive aluminum-remote FC reports. Wire layout documented by
/// https://github.com/azais-corentin/siri-remote/blob/main/src/decoder.rs
/// No HID/GATT ownership changes are needed alongside microphone capture.
struct RemoteTextTouchFrame: Equatable {
    let sender: UInt64
    let time: Date
    let generation: RemoteGeneration
    let count: Int
    let x: Int
    let y: Int

    static func decode(_ bytes: [UInt8], sender: UInt64, time: Date) -> Self? {
        guard [11, 18].contains(bytes.count), bytes[0] == 0x32 else { return nil }
        var points: [(Int, Int)] = []
        for offset in stride(from: 4, to: bytes.count, by: 7) {
            // Hover is the physical lift edge, often before the contact ellipse zeros.
            guard bytes[offset + 6] & 2 == 0,
                  bytes[offset + 3] != 0 || bytes[offset + 4] != 0 || bytes[offset + 5] != 0 else { continue }
            let packed = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16
            func signed(_ v: Int) -> Int { v & 0x800 == 0 ? v : v - 4096 }
            points.append((signed(packed & 0xfff), signed((packed >> 12) & 0xfff)))
        }
        return Self(sender: sender, time: time, generation: .aluminumClickpad, count: points.count,
                    x: points.first?.0 ?? 0, y: points.first?.1 ?? 0)
    }

    /// Black-glass A1513 touch reports arrive on the same 0x0023 ATT
    /// characteristic as voice. Only the documented 13/20-byte 0x32 reports
    /// reach this decoder, so 99-byte Opus frames cannot be mistaken for touch.
    static func decodeGlass(_ bytes: [UInt8], sender: UInt64, time: Date) -> Self? {
        guard [13, 20].contains(bytes.count), bytes[2] == 0x32 else { return nil }
        var points: [(Int, Int)] = []
        for offset in stride(from: 6, to: bytes.count, by: 7) {
            // The black-glass firmware keeps byte 0 at one on its final lift
            // reports. The contact ellipse and pressure at offsets 3...5 of the
            // finger record are the reliable physical-contact edge instead.
            guard bytes[offset + 3] != 0 || bytes[offset + 4] != 0 || bytes[offset + 5] != 0 else { continue }
            // Keep coordinates on roughly the same raw scale as the aluminum
            // report so the shared shake and movement thresholds feel alike.
            let x = Int(bytes[offset]) + 255 * Int(bytes[offset + 1] & 0x07) - 230
            let wrappedY = (bytes[offset + 2] & 0x80 != 0
                            ? Int(bytes[offset + 2])
                            : Int(bytes[offset + 2]) + 255) - 188
            points.append((x, wrappedY * 15))
        }
        return Self(sender: sender, time: time, generation: .glassTouchSurface,
                    count: points.count, x: points.first?.0 ?? 0, y: points.first?.1 ?? 0)
    }
}

/// One quick, forceful out-and-back motion enters caret mode while the same finger
/// remains down. Coordinates for both remotes are normalized to a similar raw scale by
/// their decoders, so one physical gesture threshold serves both generations.
struct RemoteCaretShakeGate {
    private struct Contact {
        let sender: UInt64
        let generation: RemoteGeneration
        var pivotX: Int
        var pivotY: Int
        var directionX: Double?
        var directionY: Double?
        var reversals: Int
        var firstStrokeAt: Date?
        var latest: RemoteTextTouchFrame
    }
    private var contact: Contact?
    let strokeDistance: Double
    let maximumDuration: TimeInterval
    let maximumFrameGap: TimeInterval
    let reversalCosine: Double

    init(strokeDistance: Double = 240, maximumDuration: TimeInterval = 0.9,
         maximumFrameGap: TimeInterval = 0.25, reversalCosine: Double = -0.65) {
        self.strokeDistance = strokeDistance
        self.maximumDuration = maximumDuration
        self.maximumFrameGap = maximumFrameGap
        self.reversalCosine = reversalCosine
    }

    var isTracking: Bool { contact != nil }
    var latest: RemoteTextTouchFrame? { contact?.latest }

    mutating func reset() { contact = nil }

    mutating func observe(_ frame: RemoteTextTouchFrame) -> Bool {
        guard frame.count == 1 else {
            reset()
            return false
        }
        guard var current = contact, current.sender == frame.sender,
              current.generation == frame.generation,
              frame.time > current.latest.time,
              frame.time.timeIntervalSince(current.latest.time) <= maximumFrameGap else {
            contact = Contact(sender: frame.sender, generation: frame.generation,
                              pivotX: frame.x, pivotY: frame.y,
                              directionX: nil, directionY: nil, reversals: 0,
                              firstStrokeAt: nil, latest: frame)
            return false
        }
        current.latest = frame
        if let start = current.firstStrokeAt,
           frame.time.timeIntervalSince(start) > maximumDuration {
            current.pivotX = frame.x
            current.pivotY = frame.y
            current.directionX = nil
            current.directionY = nil
            current.reversals = 0
            current.firstStrokeAt = nil
            contact = current
            return false
        }
        let dx = Double(frame.x - current.pivotX)
        let dy = Double(frame.y - current.pivotY)
        let distance = hypot(dx, dy)
        guard distance >= strokeDistance else { contact = current; return false }
        let unitX = dx / distance, unitY = dy / distance
        if let oldX = current.directionX, let oldY = current.directionY {
            let dot = unitX * oldX + unitY * oldY
            // Ordinary dragging can bend or turn. Only a strong return along the
            // preceding path counts as an intentional shake reversal.
            guard dot <= reversalCosine else { contact = current; return false }
            current.reversals += 1
        } else {
            current.firstStrokeAt = frame.time
        }
        current.pivotX = frame.x
        current.pivotY = frame.y
        current.directionX = unitX
        current.directionY = unitY
        let activated = current.reversals >= 1 &&
            frame.time.timeIntervalSince(current.firstStrokeAt ?? frame.time) <= maximumDuration
        contact = current
        return activated
    }
}


/// UTF-16 offsets are always whole grapheme boundaries, including emoji and combining marks.
enum CaretNavigation {
    static func boundaries(_ text: String) -> [Int] {
        var result = [0], offset = 0
        for character in text { offset += String(character).utf16.count; result.append(offset) }
        return result
    }
    static func nearest(to point: CGPoint, positions: [Int: CGRect], current: Int) -> Int? {
        func distance(_ r: CGRect) -> CGFloat { hypot(r.minX - point.x, (r.midY - point.y) * 1.8) }
        // Used when lifting/confirming. During the drag, the preview follows the
        // finger freely instead of sticking to any of these insertion stops.
        guard let best = positions.min(by: {
            let left = distance($0.value), right = distance($1.value)
            return left == right ? $0.key < $1.key : left < right
        }) else { return nil }
        if let old = positions[current], abs(distance(old) - distance(best.value)) < 0.001 { return current }
        return best.key
    }
    static func preview(at point: CGPoint, height: CGFloat, editor: CGRect) -> CGRect {
        let h = min(height, editor.height)
        let x = min(max(point.x, editor.minX), editor.maxX)
        let y = min(max(point.y - h / 2, editor.minY), editor.maxY - h)
        return CGRect(x: x, y: y, width: 2, height: h)
    }
}

/// Accumulate slow intentional motion, but absorb small back-and-forth finger jitter.
/// This is a spatial dead band, not a per-frame cutoff (which loses slow gestures).
struct CaretMotionFilter {
    private var remainder = CGPoint.zero
    mutating func reset() { remainder = .zero }
    mutating func movement(dx: Int, dy: Int) -> CGPoint {
        remainder.x += CGFloat(dx) * 0.07
        remainder.y -= CGFloat(dy) * 0.07
        let length = hypot(remainder.x, remainder.y)
        let deadBand: CGFloat = 1.25
        guard length > deadBand else { return .zero }
        let fraction = (length - deadBand) / length
        let result = CGPoint(x: remainder.x * fraction, y: remainder.y * fraction)
        remainder.x -= result.x; remainder.y -= result.y
        return result
    }
}

/// Some AX providers return a collapsed range whose origin is one line above its
/// actual insertion point. Calibrate against nonempty glyph ranges, never against
/// another zero-length range (which would repeat the same error at commit time).
enum CaretRangeGeometry {
    enum Correction: String {
        case none, topOrigin
        func apply(to rect: CGRect) -> CGRect {
            self == .topOrigin ? rect.offsetBy(dx: 0, dy: rect.height) : rect
        }
    }
    static func correction(text: String, near offset: Int,
                           bounds: (NSRange) -> CGRect?) -> Correction? {
        let stops = CaretNavigation.boundaries(text)
        let ns = text as NSString
        let candidates = (0..<max(0, stops.count - 1)).sorted {
            abs(stops[$0] - offset) < abs(stops[$1] - offset)
        }
        for i in candidates.prefix(8) {
            let range = NSRange(location: stops[i], length: stops[i + 1] - stops[i])
            guard ns.substring(with: range).rangeOfCharacter(from: .newlines) == nil,
                  let glyph = bounds(range), glyph.width > 0, glyph.height > 0,
                  let collapsed = bounds(NSRange(location: range.location, length: 0)),
                  abs(glyph.height - collapsed.height) < 1 else { continue }
            let delta = glyph.minY - collapsed.minY
            if abs(delta) < 0.75 { return Correction.none }
            if abs(delta - collapsed.height) < 0.75 { return .topOrigin }
        }
        return nil
    }
}

/// Marker indices can belong to the entire web document. Instead, walk opaque
/// markers from verified editor-local anchors and validate each traversed segment.
struct CaretMarkerNavigator<Marker> {
    let text: String
    var markers: [Int: Marker]
    mutating func marker(at target: Int, step: (Marker, Bool) -> (Marker, String)?) -> Marker? {
        let value = text as NSString
        guard target >= 0, target <= value.length else { return nil }
        if let known = markers[target] { return known }
        guard let nearest = markers.keys.min(by: { abs($0 - target) < abs($1 - target) }),
              var marker = markers[nearest] else { return nil }
        var offset = nearest
        for _ in 0..<64 {
            let forward = target > offset
            guard let (next, segment) = step(marker, forward), !segment.isEmpty else { return nil }
            let count = segment.utf16.count
            let nextOffset = offset + (forward ? count : -count)
            let start = min(offset, nextOffset)
            guard start >= 0, max(offset, nextOffset) <= value.length,
                  value.substring(with: NSRange(location: start, length: count)) == segment,
                  forward ? nextOffset <= target : nextOffset >= target else { return nil }
            markers[nextOffset] = next
            if nextOffset == target { return next }
            offset = nextOffset; marker = next
        }
        return nil
    }
}

/// Decoration never moves the insertion point. Convert through the actual window
/// and backing layer, including when the bubble extends above the editor.
enum CaretOverlayGeometry {
    static func position(caret: CGRect, editor: CGRect) -> CGPoint {
        CGPoint(x: caret.minX - editor.minX, y: caret.midY - editor.minY)
    }
    @MainActor
    static func layerPosition(caret: CGRect, primaryScreenTop: CGFloat, in view: NSView) -> CGPoint? {
        guard let window = view.window, view.layer != nil else { return nil }
        let screen = CGPoint(x: caret.minX, y: primaryScreenTop - caret.midY)
        let inWindow = window.convertPoint(fromScreen: screen)
        let inView = view.convert(inWindow, from: nil)
        return view.convertToLayer(inView)
    }
    static func aligned(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 0.75 && abs(lhs.midY - rhs.midY) < 0.75
    }
}

struct CaretButtonGate {
    enum Intent: Equatable { case exit, exitVoice, consume, pass }
    private(set) var held: Set<String> = []
    mutating func handle(button: String, down: Bool, device: String, active: Bool) -> Intent {
        let key = device + ":" + button
        if !down { return held.remove(key) != nil ? .consume : .pass }
        if held.contains(key) { return .consume }
        if active && ["siri", "power"].contains(button) {
            held.insert(key); return button == "siri" ? .exitVoice : .exit
        }
        return .pass
    }
}

@MainActor
final class RemoteCaretController {
    private final class MarkerGeometry {
        let element: AXUIElement
        let provider: AXUIElement
        var navigator: CaretMarkerNavigator<AXTextMarker>
        init(element: AXUIElement, provider: AXUIElement, navigator: CaretMarkerNavigator<AXTextMarker>) {
            self.element = element; self.provider = provider; self.navigator = navigator
        }
    }
    private struct Editor {
        let element: AXUIElement
        let pid: pid_t
        let text: String
        let selection: CFRange
        let bounds: CGRect
    }
    var onVoiceSuppression: ((Bool) -> Void)?
    private var editor: Editor?
    private var positions: [Int: CGRect] = [:]
    private var remaining: [Int] = []
    private var destination = 0
    private var displayedCaret: (offset: Int, rect: CGRect)?
    private var aim = CGPoint.zero
    private var isDragging = false
    private var lastTouch: RemoteTextTouchFrame?
    private var motion = CaretMotionFilter()
    private var ignoreTouchUntil = Date.distantPast
    private var owner: UInt64?
    private var active = false
    private var activeGeneration: RemoteGeneration?
    private var shakeGesture = RemoteCaretShakeGate()
    private var buttons = CaretButtonGate()
    private var swallowedReturns: Set<Int> = []
    private var notifiedSuppression = false
    private var timer: Timer?
    private var voiceBlockedByPress = false
    private let overlay = CaretOverlay()
    private var lastRead = Date.distantPast
    private var geometryCorrection: (element: AXUIElement, mode: CaretRangeGeometry.Correction)?
    private var markerGeometry: MarkerGeometry?
    private var diagnosingEntry = false
    var isActive: Bool { active }

    func reset() { buttons = .init(); swallowedReturns.removeAll(); voiceBlockedByPress = false; cancel() }
    func stop() { reset() }

    /// Surface clicks never enter caret mode. The black-glass click remains Enter;
    /// the aluminum click is reserved while Power remains its submit button.
    func button(_ button: String, pressed down: Bool, device: String,
                generation: RemoteGeneration) -> Bool {
        if button == "select" {
            if down { cancel() }
            return false
        }
        let intent = buttons.handle(button: button, down: down, device: device, active: active)
        switch intent {
        case .exitVoice:
            voiceBlockedByPress = true; cancel(); return true
        case .exit:
            cancel(); return true
        case .consume:
            if !down {
                lastTouch = nil; motion.reset()
                // Releasing the mechanical click moves the finger too. Establish
                // a fresh contact baseline after the short release settling period.
                ignoreTouchUntil = Date().addingTimeInterval(0.1)
            }
            return true
        case .pass:
            if down {
                // A cancelled dictation hold stays muted through its release tail;
                // only the next ordinary Siri press may start a fresh voice session.
                if button == "siri" { voiceBlockedByPress = false }
                cancel()
            }
            return false
        }
    }

    func keyboardInput(code: Int?, down: Bool) -> Bool {
        if let code, swallowedReturns.contains(code) {
            if !down { swallowedReturns.remove(code) }
            return true
        }
        guard down else { return false }
        let consume = active && (code == 36 || code == 76)
        if consume, let code { swallowedReturns.insert(code) }
        cancel()
        return consume
    }

    func receive(_ frame: RemoteTextTouchFrame) {
        guard Date().timeIntervalSince(frame.time) <= 0.18 else { cancel(); return }
        if active {
            guard activeGeneration == frame.generation else { return }
            guard owner == nil || owner == frame.sender else { return }
            owner = frame.sender
            if frame.count != 1 {
                commit()
                return
            }
            guard buttons.held.isEmpty, frame.time >= ignoreTouchUntil else {
                lastTouch = nil; motion.reset(); return
            }
            defer { lastTouch = frame }
            guard let last = lastTouch, frame.time > last.time,
                  frame.time.timeIntervalSince(last.time) < 0.25 else {
                motion.reset()
                if !isDragging, let shown = displayedCaret { aim = CGPoint(x: shown.rect.minX, y: shown.rect.midY) }
                return
            }
            let dx = frame.x - last.x, dy = frame.y - last.y
            guard abs(dx) < 700, abs(dy) < 700, let editor else { return }
            let movement = motion.movement(dx: dx, dy: dy)
            guard movement != .zero else { return }
            isDragging = true
            aim.x = min(max(aim.x + movement.x, editor.bounds.minX), editor.bounds.maxX - 1)
            aim.y = min(max(aim.y + movement.y, editor.bounds.minY), editor.bounds.maxY - 1)
            if Date().timeIntervalSince(lastRead) > 0.025 {
                lastRead = Date()
                guard valid() else { cancel(); return }
                refreshDestination(in: editor)
            }
            if let target = displayedCaret {
                let free = CaretNavigation.preview(at: aim, height: target.rect.height, editor: editor.bounds)
                overlay.show(caret: free, editor: editor.bounds, progress: 1, tracking: true)
            }
        } else {
            guard buttons.held.isEmpty else { shakeGesture.reset(); return }
            if shakeGesture.observe(frame) { beginShakeGesture() }
        }
    }

    private func beginShakeGesture() {
        guard let frame = shakeGesture.latest else { return }
        begin(owner: frame.sender, generation: frame.generation)
        if active { lastTouch = frame }
    }

    private func begin(owner: UInt64? = nil, generation: RemoteGeneration = .aluminumClickpad) {
        diagnosingEntry = true
        defer { diagnosingEntry = false }
        guard let candidate = observe(), let rect = caret(candidate.selection.location, in: candidate) else { cancel(); return }
        editor = candidate; active = true; activeGeneration = generation
        self.owner = owner; lastTouch = nil
        isDragging = false
        motion.reset()
        destination = candidate.selection.location
        displayedCaret = (destination, rect)
        positions = [destination: rect]; aim = CGPoint(x: rect.minX, y: rect.midY)
        remaining = CaretNavigation.boundaries(candidate.text).sorted { abs($0 - destination) < abs($1 - destination) }
        publishSuppression(true)
        gatherPositions()
        overlay.show(caret: rect, editor: candidate.bounds, progress: 1)
        startWatchdog()
        rmDebug("Caret positioning entered: generation=\(generation.rawValue) caretAX=\(rect) overlayError=\(overlay.alignmentError(caret: rect))")
    }

    private func commit() {
        // Lift resolves the freely moving preview to the nearest insertion point
        // before committing the real selection.
        if isDragging, !settle() { return }
        guard valid(), let editor, let displayedCaret,
              let freshRect = caret(displayedCaret.offset, in: editor),
              CaretOverlayGeometry.aligned(freshRect, displayedCaret.rect) else {
            // Scrolling/reflow can change glyph geometry without changing AXValue.
            // Never commit a stale screen position to a different visible location.
            cancel(); return
        }
        var range = CFRange(location: displayedCaret.offset, length: 0)
        if let value = AXValueCreate(.cfRange, &range),
           AXUIElementSetAttributeValue(editor.element, kAXSelectedTextRangeAttribute as CFString, value) == .success {
            if let actual = observe(), actual.pid == editor.pid, CFEqual(actual.element, editor.element),
               actual.selection.location == displayedCaret.offset {
                let landed = caret(actual.selection.location, in: actual)
                let delta = landed.map { $0.midY - displayedCaret.rect.midY }
                rmDebug("Caret position committed and selection verified: geometryDeltaY=\(delta.map(String.init(describing:)) ?? "unavailable")")
            } else { rmDebug("Caret position requested; selection acknowledgement unavailable") }
        } else { rmDebug("Caret position commit unavailable") }
        cancel()
    }

    func cancel() {
        active = false; activeGeneration = nil; shakeGesture.reset()
        editor = nil; displayedCaret = nil; positions.removeAll(); remaining.removeAll()
        isDragging = false
        geometryCorrection = nil
        markerGeometry = nil
        lastTouch = nil; motion.reset(); ignoreTouchUntil = .distantPast
        owner = nil; timer?.invalidate(); timer = nil
        overlay.hide()
        publishSuppression(voiceBlockedByPress)
    }

    private func refreshDestination(in editor: Editor) {
        gatherPositions()
        if let offset = offset(at: aim, in: editor), let rect = caret(offset, in: editor) { positions[offset] = rect }
        if let next = CaretNavigation.nearest(to: aim, positions: positions, current: destination), let rect = positions[next] {
            destination = next; displayedCaret = (next, rect)
        }
    }

    /// Resolve the free preview to a real insertion boundary before commit.
    @discardableResult
    private func settle() -> Bool {
        guard active, valid(), let editor else { cancel(); return false }
        refreshDestination(in: editor)
        guard let shown = displayedCaret, let fresh = caret(shown.offset, in: editor),
              CaretOverlayGeometry.aligned(fresh, shown.rect) else { cancel(); return false }
        isDragging = false
        displayedCaret = (shown.offset, fresh)
        aim = CGPoint(x: fresh.minX, y: fresh.midY)
        overlay.show(caret: fresh, editor: editor.bounds, progress: 1, tracking: true)
        return true
    }

    private func publishSuppression(_ suppressed: Bool) {
        guard suppressed != notifiedSuppression else { return }
        notifiedSuppression = suppressed
        onVoiceSuppression?(suppressed)
    }

    private func startWatchdog() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.active, self.valid() else { self.cancel(); return }
                self.gatherPositions()
            }
        }
        timer = t; RunLoop.main.add(t, forMode: .common)
    }

    private func valid() -> Bool {
        guard let editor, let now = observe() else { return false }
        return now.pid == editor.pid && CFEqual(now.element, editor.element) && now.text == editor.text &&
            now.selection.location == editor.selection.location && now.selection.length == editor.selection.length && now.bounds == editor.bounds
    }

    private func gatherPositions() {
        guard let editor else { return }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.018
        var count = 0
        while !remaining.isEmpty, count < 16, ProcessInfo.processInfo.systemUptime < deadline {
            let offset = remaining.removeFirst(); count += 1
            if let rect = caret(offset, in: editor) { positions[offset] = rect }
        }
    }

    private func attribute(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef? = nil) -> CFTypeRef? {
        var value: CFTypeRef?
        let status = parameter.map { AXUIElementCopyParameterizedAttributeValue(element, name as CFString, $0, &value) }
            ?? AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return status == .success ? value : nil
    }
    private func unpack<T: BitwiseCopyable>(_ raw: CFTypeRef?, _ type: AXValueType, _ result: inout T) -> Bool {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
        let value = unsafeBitCast(raw, to: AXValue.self)
        return AXValueGetType(value) == type && AXValueGetValue(value, type, &result)
    }
    private func observe() -> Editor? {
        func blocked(_ reason: String) -> Editor? { entryDiagnostic(reason); return nil }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.02)
        guard let raw = attribute(application, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return blocked("focused element unavailable") }
        let element = unsafeBitCast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.015)
        var writable = DarwinBoolean(false)
        let role = attribute(element, kAXRoleAttribute) as? String ?? "unavailable"
        guard [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role) else { return blocked("unsupported role \(role)") }
        guard attribute(element, kAXSubroleAttribute) as? String != kAXSecureTextFieldSubrole else { return blocked("secure field") }
        guard attribute(element, "AXTextInputMarkedTextMarkerRange") == nil else { return blocked("marked text present") }
        let writableStatus = AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &writable)
        guard writableStatus == .success, writable.boolValue else { return blocked("selection not writable status=\(writableStatus.rawValue)") }
        guard let text = attribute(element, kAXValueAttribute) as? String, text.utf16.count <= 16_384 else { return blocked("text value unavailable or too large") }
        var selection = CFRange(), position = CGPoint.zero, size = CGSize.zero
        guard unpack(attribute(element, kAXSelectedTextRangeAttribute), .cfRange, &selection), selection.length == 0,
              CaretNavigation.boundaries(text).contains(selection.location),
              unpack(attribute(element, kAXPositionAttribute), .cgPoint, &position),
              unpack(attribute(element, kAXSizeAttribute), .cgSize, &size), size.width > 0, size.height > 0,
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite else { return blocked("selection or editor bounds unavailable") }
        return Editor(element: element, pid: app.processIdentifier, text: text, selection: selection, bounds: CGRect(origin: position, size: size))
    }
    private func caret(_ offset: Int, in editor: Editor) -> CGRect? {
        if let context = markerGeometry, !CFEqual(context.element, editor.element) { markerGeometry = nil }
        func bounds(_ requested: NSRange) -> CGRect? {
            if let context = markerGeometry { return markerBounds(requested, in: context) }
            var range = CFRange(location: requested.location, length: requested.length), rect = CGRect.zero
            guard let value = AXValueCreate(.cfRange, &range),
                  unpack(attribute(editor.element, kAXBoundsForRangeParameterizedAttribute, value), .cgRect, &rect),
                  rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite,
                  rect.height.isFinite, rect.height > 0 else { entryDiagnostic("range bounds unavailable (collapsed=\(requested.length == 0))"); return nil }
            entryDiagnostic("range geometry (collapsed=\(requested.length == 0)): \(rect)")
            return rect
        }
        if geometryCorrection.map({ !CFEqual($0.element, editor.element) }) ?? true {
            var mode = CaretRangeGeometry.correction(text: editor.text, near: offset, bounds: bounds)
            if mode == nil, markerGeometry == nil {
                markerGeometry = makeMarkerGeometry(editor)
                if markerGeometry != nil {
                    mode = CaretRangeGeometry.correction(text: editor.text, near: offset, bounds: bounds)
                }
            }
            guard let mode else {
                // No reliable glyph geometry (including an empty editor): do not
                // show a falsely positioned caret or guess a one-line adjustment.
                entryDiagnostic("calibration unavailable (empty=\(editor.text.isEmpty))")
                return nil
            }
            geometryCorrection = (editor.element, mode)
            rmDebug("Caret AX geometry calibrated: \(mode.rawValue), source=\(markerGeometry == nil ? "ranges" : "text-markers")")
        }
        guard let raw = bounds(NSRange(location: offset, length: 0)),
              let rect = geometryCorrection?.mode.apply(to: raw),
              editor.bounds.insetBy(dx: -1, dy: 0).contains(CGPoint(x: rect.minX, y: rect.midY)) else { entryDiagnostic("caret outside editor or unavailable"); return nil }
        // Keep the native caret anchor even for a partially visible line; clipping
        // the stem must not change the underlying insertion geometry.
        return CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)
    }
    private func entryDiagnostic(_ reason: String) {
        guard diagnosingEntry else { return }
        rmDebug("Caret entry [\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown")]: \(reason)")
    }
    private func makeMarkerGeometry(_ editor: Editor) -> MarkerGeometry? {
        var candidate: AXUIElement? = editor.element
        for _ in 0..<6 {
            guard let provider = candidate else { break }
            AXUIElementSetMessagingTimeout(provider, 0.015)
            if let raw = attribute(provider, "AXTextMarkerRangeForUIElement", editor.element),
               CFGetTypeID(raw) == AXTextMarkerRangeGetTypeID(),
               let value = attribute(provider, "AXStringForTextMarkerRange", raw) as? String,
               value == editor.text {
                let range = unsafeBitCast(raw, to: AXTextMarkerRange.self)
                var markers = [0: AXTextMarkerRangeCopyStartMarker(range)]
                markers[editor.text.utf16.count] = AXTextMarkerRangeCopyEndMarker(range)
                // Anchor at the real selection too, so a long editor does not need
                // to be walked from its first character before the overlay appears.
                if let selection = attribute(provider, "AXSelectedTextMarkerRange"),
                   CFGetTypeID(selection) == AXTextMarkerRangeGetTypeID() {
                    let selected = unsafeBitCast(selection, to: AXTextMarkerRange.self)
                    let current = AXTextMarkerRangeCopyStartMarker(selected)
                    let prefix = AXTextMarkerRangeCreate(nil, AXTextMarkerRangeCopyStartMarker(range), current)
                    let expected = (editor.text as NSString).substring(to: editor.selection.location)
                    if attribute(provider, "AXStringForTextMarkerRange", prefix) as? String == expected {
                        markers[editor.selection.location] = current
                    }
                }
                entryDiagnostic("verified editor-local text markers")
                return MarkerGeometry(element: editor.element, provider: provider, navigator: CaretMarkerNavigator(text: editor.text, markers: markers))
            }
            guard let parent = attribute(provider, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            candidate = unsafeBitCast(parent, to: AXUIElement.self)
        }
        entryDiagnostic("editor-local text markers unavailable")
        return nil
    }
    private func markerBounds(_ range: NSRange, in context: MarkerGeometry) -> CGRect? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.03
        func marker(_ offset: Int) -> AXTextMarker? {
            context.navigator.marker(at: offset) { current, forward in
                guard ProcessInfo.processInfo.systemUptime < deadline,
                      let raw = attribute(context.provider, forward ? "AXNextTextMarkerForTextMarker" : "AXPreviousTextMarkerForTextMarker", current),
                      CFGetTypeID(raw) == AXTextMarkerGetTypeID() else { return nil }
                let next = unsafeBitCast(raw, to: AXTextMarker.self)
                let span = AXTextMarkerRangeCreate(nil, forward ? current : next, forward ? next : current)
                guard let segment = attribute(context.provider, "AXStringForTextMarkerRange", span) as? String else { return nil }
                return (next, segment)
            }
        }
        guard let start = marker(range.location), let end = marker(range.location + range.length) else { return nil }
        let span = AXTextMarkerRangeCreate(nil, start, end)
        var rect = CGRect.zero
        guard unpack(attribute(context.provider, "AXBoundsForTextMarkerRange", span), .cgRect, &rect),
              rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite,
              rect.height.isFinite, rect.height > 0 else { entryDiagnostic("text-marker bounds unavailable"); return nil }
        entryDiagnostic("text-marker geometry (collapsed=\(range.length == 0)): \(rect)")
        return rect
    }
    private func offset(at point: CGPoint, in editor: Editor) -> Int? {
        var p = point, range = CFRange()
        guard let value = AXValueCreate(.cgPoint, &p),
              unpack(attribute(editor.element, kAXRangeForPositionParameterizedAttribute, value), .cfRange, &range) else { return nil }
        return CaretNavigation.boundaries(editor.text).min { abs($0 - range.location) < abs($1 - range.location) }
    }
}

import QuartzCore

/// Figma 1345:6560, exported at 4x; the source SVG is bundled alongside it.
/// Only the straight 2 pt stem adapts to the editor's line height.
@MainActor
enum CaretBubbleArtwork {
    static func image(appearance: NSAppearance, bundle: Bundle = SettingsAssets.bundle, includeSymbol: Bool = true) -> CGImage? {
        guard let url = bundle.url(forResource: "CaretBubble", withExtension: "png"),
              let silhouette = NSImage(contentsOf: url),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 128,
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: 4, y: 4)
        appearance.performAsCurrentDrawingAppearance {
            silhouette.draw(in: CGRect(x: 0, y: 0, width: 24, height: 32))
            NSColor.labelColor.setFill()
            CGRect(x: 0, y: 0, width: 24, height: 32).fill(using: .sourceAtop)
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.textBackgroundColor]))
            if includeSymbol, let symbol = NSImage(systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) {
                let size = symbol.size
                // Unflipped drawing: the bubble center is 12 pt below the top.
                symbol.draw(in: CGRect(x: 12 - size.width / 2, y: 20 - size.height / 2,
                                       width: size.width, height: size.height))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }
}

@MainActor
final class CaretOverlay {
    /// Draw in AppKit's ordinary bottom-left coordinates. No custom CALayer origin,
    /// geometry flipping or anchorPoint participates in caret placement.
    final class Canvas: NSView {
        var lineHeight: CGFloat = 16
        var clipBottom: CGFloat = 0
        var clipHeight: CGFloat = 16
        var opacity: CGFloat = 0
        var expansion: CGFloat = 0
        var artwork: NSImage?
        var previewArtwork: NSImage?
        var symbolOpacity: CGFloat = 0
        var insertionBottom = CGPoint(x: 14, y: 2)
        var stemRect: CGRect { CGRect(x: insertionBottom.x - 1, y: insertionBottom.y, width: 2, height: lineHeight) }
        override var isOpaque: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.clear.setFill(); dirtyRect.fill(using: .copy)
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            context.setAlpha(opacity)
            context.setShadow(offset: .zero, blur: 1, color: NSColor.textBackgroundColor.cgColor)
            context.saveGState()
            context.clip(to: CGRect(x: stemRect.minX - 1, y: stemRect.minY + clipBottom, width: 4, height: clipHeight))
            NSColor.labelColor.setFill()
            NSBezierPath(roundedRect: stemRect, xRadius: 1, yRadius: 1).fill()
            context.restoreGState()
            let size = CGSize(width: 24 * expansion, height: 32 * expansion)
            let bubbleRect = CGRect(x: stemRect.midX - size.width / 2, y: stemRect.maxY,
                                    width: size.width, height: size.height)
            previewArtwork?.draw(in: bubbleRect, from: .zero, operation: .sourceOver,
                                 fraction: 1, respectFlipped: false, hints: nil)
            if symbolOpacity > 0 {
                // Composite the symbol-bearing image over the identical silhouette,
                // so the symbol fades in without dimming the bubble underneath it.
                artwork?.draw(in: bubbleRect, from: .zero, operation: .sourceOver,
                              fraction: symbolOpacity, respectFlipped: false, hints: nil)
            }
            context.restoreGState()
        }
    }
    final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }
    private(set) var panel: Panel?
    private(set) var canvas: Canvas?
    private var timer: Timer?
    private var artworkAppearance: NSAppearance.Name?
    private var warnedMissingArtwork = false
    private var targetOpacity: CGFloat = 0
    private var targetExpansion: CGFloat = 0
    private var targetSymbolOpacity: CGFloat = 0

    func show(caret: CGRect, editor: CGRect, progress: CGFloat, tracking: Bool = false, present: Bool = true) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        if panel == nil {
            let window = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            window.ignoresMouseEvents = true; window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            let view = Canvas()
            window.contentView = view
            panel = window; canvas = view
        }
        guard let panel, let canvas else { return }
        // Window bottom = native caret bottom - 2 pt. The stem is drawn at y=2,
        // so its bottom coincides with the native insertion rectangle exactly.
        let frame = CGRect(x: caret.minX - 14, y: top - caret.maxY - 2,
                           width: 28, height: caret.height + 36)
        panel.setFrame(frame, display: false)
        canvas.frame = CGRect(origin: .zero, size: panel.frame.size)
        // NSWindow can round its origin to a screen pixel. Preserve the fractional
        // text position inside the view rather than rounding the insertion point.
        canvas.insertionBottom = canvas.convert(panel.convertPoint(fromScreen:
            CGPoint(x: caret.minX, y: top - caret.maxY)), from: nil)
        canvas.lineHeight = caret.height
        canvas.clipBottom = max(0, caret.maxY - editor.maxY)
        canvas.clipHeight = max(0, min(caret.maxY, editor.maxY) - max(caret.minY, editor.minY))
        let appearance = canvas.effectiveAppearance
        if artworkAppearance != appearance.name || canvas.artwork == nil || canvas.previewArtwork == nil {
            if let image = CaretBubbleArtwork.image(appearance: appearance),
               let plain = CaretBubbleArtwork.image(appearance: appearance, includeSymbol: false) {
                canvas.artwork = NSImage(cgImage: image, size: CGSize(width: 24, height: 32))
                canvas.previewArtwork = NSImage(cgImage: plain, size: CGSize(width: 24, height: 32))
                artworkAppearance = appearance.name
                rmDebug("Caret bubble artwork ready: \(image.width)x\(image.height)")
            } else if !warnedMissingArtwork {
                warnedMissingArtwork = true
                rmDebug("Caret bubble artwork unavailable: \(SettingsAssets.bundle.bundlePath)")
            }
        }
        let preview = progress < 1
        let expansion: CGFloat = preview ? 0.6 : 1
        let symbolOpacity: CGFloat = preview ? 0 : 1
        // The stem covers the native insertion caret at full final color from the
        // first frame; only the bubble grows during preparation.
        canvas.opacity = 1
        if preview { canvas.symbolOpacity = 0 }
        if targetOpacity != 1 || expansion != targetExpansion || symbolOpacity != targetSymbolOpacity {
            transition(opacity: 1, expansion: expansion, symbolOpacity: symbolOpacity, duration: 0.2)
        }
        canvas.needsDisplay = true
        if present { panel.orderFrontRegardless() }
    }
    /// Compare the actual native view point to the AX target, independent of layers.
    func alignmentError(caret: CGRect) -> String {
        guard let panel, let canvas else { return "unavailable" }
        let stem = canvas.stemRect
        let actual = panel.convertPoint(toScreen: canvas.convert(CGPoint(x: stem.midX, y: stem.midY), to: nil))
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return String(format: "dx=%.2f dy=%.2f", actual.x - caret.minX, top - actual.y - caret.midY)
    }
    func hide() {
        guard panel?.isVisible == true else { return }
        transition(opacity: 0, expansion: 0, symbolOpacity: 0, duration: 0.16)
    }
    private func transition(opacity: CGFloat, expansion: CGFloat, symbolOpacity: CGFloat, duration: TimeInterval) {
        guard let canvas else { return }
        timer?.invalidate(); timer = nil
        targetOpacity = opacity; targetExpansion = expansion; targetSymbolOpacity = symbolOpacity
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let fromOpacity = canvas.opacity, fromExpansion = canvas.expansion
        let fromSymbolOpacity = canvas.symbolOpacity
        let started = ProcessInfo.processInfo.systemUptime
        let length = reduced ? 0.08 : duration
        if reduced { canvas.expansion = expansion }
        let animation = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] tick in
            let keepRunning = MainActor.assumeIsolated {
                guard let self, let canvas = self.canvas else { return false }
                let elapsed = min(1, (ProcessInfo.processInfo.systemUptime - started) / length)
                let eased = 1 - pow(1 - elapsed, 3)
                canvas.opacity = fromOpacity + (opacity - fromOpacity) * eased
                canvas.symbolOpacity = fromSymbolOpacity + (symbolOpacity - fromSymbolOpacity) * eased
                if !reduced { canvas.expansion = fromExpansion + (expansion - fromExpansion) * eased }
                canvas.needsDisplay = true
                if elapsed == 1 {
                    self.timer = nil
                    if opacity == 0 { self.panel?.orderOut(nil) }
                }
                return elapsed < 1
            }
            if !keepRunning { tick.invalidate() }
        }
        timer = animation
        RunLoop.main.add(animation, forMode: .common)
    }
}
