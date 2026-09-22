import AppKit
import QuartzCore

/// Accessibility uses global top-left coordinates; AppKit windows use bottom-left
/// coordinates. Keep the primary display's origin for every display, including those
/// above or to the left of it. These reads never move the caret or change selection.
struct AdvancedMenuTextAnchor: Sendable {
    let rect: CGRect
    let source: String

    static func appKitRect(_ rect: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func presentationRect(textAnchor: Self?, mouseLocation: NSPoint, primaryScreenTop: CGFloat) -> NSRect {
        // NSEvent mouse coordinates are already AppKit screen coordinates.
        textAnchor.map { appKitRect($0.rect, primaryScreenTop: primaryScreenTop) }
            ?? NSRect(origin: mouseLocation, size: .zero)
    }

    static func read(pid: pid_t) -> Self? {
        let deadline = ProcessInfo.processInfo.systemUptime + 0.2
        let app = AXUIElementCreateApplication(pid)
        func attribute(_ element: AXUIElement, _ name: String, parameter: CFTypeRef? = nil) -> CFTypeRef? {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            AXUIElementSetMessagingTimeout(element, 0.035)
            var result: CFTypeRef?
            let status = parameter.map { AXUIElementCopyParameterizedAttributeValue(element, name as CFString, $0, &result) }
                ?? AXUIElementCopyAttributeValue(element, name as CFString, &result)
            return status == .success ? result : nil
        }
        func element(_ raw: CFTypeRef?) -> AXUIElement? {
            guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            return unsafeBitCast(raw, to: AXUIElement.self)
        }
        func value<T: BitwiseCopyable>(_ raw: CFTypeRef?, type: AXValueType, into result: inout T) -> Bool {
            guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return false }
            let boxed = unsafeBitCast(raw, to: AXValue.self)
            return AXValueGetType(boxed) == type && AXValueGetValue(boxed, type, &result)
        }
        func bounds(_ raw: CFTypeRef?) -> CGRect? {
            var rect = CGRect.zero
            guard value(raw, type: .cgRect, into: &rect), rect.height > 0, rect.width >= 0,
                  rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite else { return nil }
            return rect
        }
        let focus = element(attribute(app, kAXFocusedUIElementAttribute))
        var current = focus
        for _ in 0..<5 {
            guard let candidate = current else { break }
            var selection = CFRange()
            if value(attribute(candidate, kAXSelectedTextRangeAttribute), type: .cfRange, into: &selection),
               selection.location >= 0, selection.length >= 0, selection.location <= Int.max - selection.length {
                var caret = CFRange(location: selection.location + selection.length, length: 0)
                if let range = AXValueCreate(.cfRange, &caret),
                   let rect = bounds(attribute(candidate, kAXBoundsForRangeParameterizedAttribute, parameter: range)) {
                    return Self(rect: rect, source: "caret")
                }
            }
            // Chromium/WebKit may expose the selection as a text marker on the web area.
            if let marker = attribute(candidate, "AXSelectedTextMarkerRange"),
               let rect = bounds(attribute(candidate, "AXBoundsForTextMarkerRange", parameter: marker)) {
                return Self(rect: rect, source: "text-selection")
            }
            current = element(attribute(candidate, kAXParentAttribute))
        }
        // No text geometry: let the caller use the mouse position captured at opening.
        return nil
    }
}

enum AdvancedMenuAction: String, CaseIterable, Sendable {
    case deleteAll, skill, previousSession, nextSession
    var title: String {
        switch self {
        case .deleteAll: return "Delete all"
        case .skill: return "Skill"
        case .previousSession: return "Previous Session"
        case .nextSession: return "Next Session"
        }
    }
}

/// A click owns its release even when the menu is dismissed meanwhile. A stale release
/// may be consumed but can never execute an action in a later menu presentation.
struct AdvancedMenuInputState {
    enum Command: Equatable { case showMenu, dismissMenu, perform(AdvancedMenuAction) }
    struct Result { let consumed: Bool; var command: Command? = nil }
    private struct Key: Hashable { let device: String; let button: String }
    private struct Press { let command: Command; let session: UUID?; let beganAt: TimeInterval; var executed = false }
    static let holdDuration: TimeInterval = 0.25
    private var presses: [Key: Press] = [:]
    private(set) var session: UUID?
    private(set) var owner: String?
    var isVisible: Bool { session != nil }
    static let auxiliaryButtons: Set<String> = ["back", "menu", "tv", "playPause", "mute", "volumeUp", "volumeDown"]
    static func trigger(for generation: RemoteGeneration) -> String { generation == .glassTouchSurface ? "playPause" : "mute" }
    static func action(button: String, generation: RemoteGeneration) -> AdvancedMenuAction? {
        switch button {
        case "back", "menu": return .deleteAll
        case "tv": return .skill
        case "volumeUp": return .previousSession
        case "volumeDown": return .nextSession
        default: return nil
        }
    }
    mutating func show(owner: String?) { session = UUID(); self.owner = owner }
    mutating func dismiss() { session = nil; owner = nil }
    mutating func reset() { dismiss(); presses.removeAll() }
    mutating func handle(button: String, pressed: Bool, device: String, generation: RemoteGeneration, time: TimeInterval = Date.timeIntervalSinceReferenceDate) -> Result {
        let key = Key(device: device, button: button)
        if pressed {
            if presses[key] != nil { return Result(consumed: true) }
            if button == Self.trigger(for: generation) {
                if !isVisible {
                    show(owner: device)
                    presses[key] = Press(command: .showMenu, session: session, beganAt: time)
                    return Result(consumed: true, command: .showMenu)
                }
                presses[key] = Press(command: .dismissMenu, session: owner == nil || owner == device ? session : nil, beganAt: time)
                return Result(consumed: true)
            }
            if isVisible, owner == nil || owner == device, let action = Self.action(button: button, generation: generation) {
                let trigger = Key(device: device, button: Self.trigger(for: generation))
                let held = presses[trigger]?.session == session
                presses[key] = Press(command: .perform(action), session: session, beganAt: time, executed: held)
                return Result(consumed: true, command: held ? .perform(action) : nil)
            }
            return Result(consumed: false)
        }
        guard let press = presses.removeValue(forKey: key) else { return Result(consumed: false) }
        guard press.session == session, isVisible, !press.executed else { return Result(consumed: true) }
        switch press.command {
        case .showMenu:
            return Result(consumed: true, command: time - press.beganAt >= Self.holdDuration ? .dismissMenu : nil)
        case .dismissMenu: return Result(consumed: true, command: .dismissMenu)
        case .perform: return Result(consumed: true, command: press.command)
        }
    }
}

@MainActor
final class AdvancedMenuController {
    static let contentPadding: CGFloat = 40
    static let menuSize = NSSize(width: 160, height: 204)
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }
    private final class Canvas: NSView { override var isFlipped: Bool { true } }
    final class ShadowView: NSView {
        override var isFlipped: Bool { true }
        var buttonFrames: [NSRect] = [] { didSet { renderedShadow = nil; needsDisplay = true } }
        private var renderedShadow: NSImage?
        private var renderedScale: CGFloat = 0
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            let scale = window?.backingScaleFactor ?? 2
            if renderedShadow == nil || renderedScale != scale {
                renderedShadow = makeShadow(scale: scale)
                renderedScale = scale
            }
            renderedShadow?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                                 respectFlipped: true, hints: nil)
        }
        private func makeShadow(scale: CGFloat) -> NSImage? {
            let width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
            guard width > 0, height > 0,
                  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap),
                  let pixels = bitmap.bitmapData else { return nil }
            bitmap.size = bounds.size
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: scale, y: scale)
            context.cgContext.translateBy(x: 0, y: bounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            let silhouette = NSBezierPath()
            for frame in buttonFrames {
                silhouette.append(NSBezierPath(roundedRect: frame, xRadius: 18, yRadius: 18))
            }
            // The caster stays offscreen. Knock out only the glass interior, with
            // one device pixel of antialiasing. An exterior feather creates a bright
            // moat between the glass rim and its shadow, making it look like a glow.
            let distance = bounds.width + 64
            let caster = silhouette.copy() as! NSBezierPath
            let translation = AffineTransform(translationByX: -distance, byY: 0)
            caster.transform(using: translation)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
            // NSShadow offsets and blur are in device space, unlike the scaled path.
            shadow.shadowBlurRadius = 18 * scale
            shadow.shadowOffset = NSSize(width: distance * scale, height: -8 * scale)
            shadow.set()
            NSColor.black.setFill()
            caster.fill()
            context.cgContext.flush()
            for y in 0..<height {
                for x in 0..<width {
                    let point = NSPoint(x: (CGFloat(x) + 0.5) / scale, y: (CGFloat(y) + 0.5) / scale)
                    var distance = CGFloat.greatestFiniteMagnitude
                    for frame in buttonFrames {
                        let radius = min(18, min(frame.width, frame.height) / 2)
                        let dx = abs(point.x - frame.midX) - (frame.width / 2 - radius)
                        let dy = abs(point.y - frame.midY) - (frame.height / 2 - radius)
                        distance = min(distance, hypot(max(dx, 0), max(dy, 0)) + min(max(dx, dy), 0) - radius)
                    }
                    let opacity = min(1, max(0, distance * scale))
                    if opacity < 1 {
                        // All four channels are premultiplied; attenuate them together.
                        let offset = y * bitmap.bytesPerRow + x * 4
                        for channel in 0..<4 {
                            pixels[offset + channel] = UInt8((CGFloat(pixels[offset + channel]) * opacity).rounded())
                        }
                    }
                }
            }
            let image = NSImage(size: bounds.size)
            image.addRepresentation(bitmap)
            return image
        }
    }
    private(set) var input = AdvancedMenuInputState()
    private(set) var targetPID: pid_t?
    private var panel: Panel?
    private var animatedContent: NSView?
    private var collapsedPosition: CGPoint?
    private var closingPanel: Panel?
    private var dismissalCompletion: DispatchWorkItem?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    var onAction: ((AdvancedMenuAction, pid_t) -> Void)?
    var isVisible: Bool { input.isVisible }

    func handle(button: String, pressed: Bool, device: String, generation: RemoteGeneration, time: TimeInterval = Date.timeIntervalSinceReferenceDate) -> Bool {
        let result = input.handle(button: button, pressed: pressed, device: device, generation: generation, time: time)
        switch result.command {
        case .showMenu: preparePresentation(generation: generation)
        case .dismissMenu: dismiss()
        case .perform(let action): perform(action)
        case nil: break
        }
        return result.consumed
    }
    func show(generation: RemoteGeneration = .aluminumClickpad, owner: String? = nil) {
        dismiss()
        input.show(owner: owner)
        preparePresentation(generation: generation)
    }
    private func preparePresentation(generation: RemoteGeneration) {
        finishDismissal()
        guard let target = NSWorkspace.shared.frontmostApplication else { dismiss(); return }
        targetPID = target.processIdentifier
        let session = input.session
        let pid = target.processIdentifier
        let bundleID = target.bundleIdentifier
        let mouseLocation = NSEvent.mouseLocation
        // AX is cross-process IPC; never block the remote/media event tap while reading it.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let anchor = AdvancedMenuTextAnchor.read(pid: pid)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.input.session == session, self.input.isVisible else { return }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { self.dismiss(); return }
                self.present(generation: generation, pid: pid, bundleID: bundleID, textAnchor: anchor, mouseLocation: mouseLocation)
            }
        }
    }

    private func present(generation: RemoteGeneration, pid: pid_t, bundleID: String?, textAnchor: AdvancedMenuTextAnchor?, mouseLocation: NSPoint) {
        let padding = Self.contentPadding
        let size = Self.menuSize
        let screens = NSScreen.screens
        let fallbackScreen = NSScreen.main ?? screens.first
        let fallbackFrame = fallbackScreen?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let anchor = AdvancedMenuTextAnchor.presentationRect(
            textAnchor: textAnchor, mouseLocation: mouseLocation,
            primaryScreenTop: screens.first?.frame.maxY ?? fallbackFrame.maxY)
        let screen = screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? fallbackScreen
        let frame = Self.frame(anchor: anchor, size: size, screen: screen?.visibleFrame ?? fallbackFrame)
        let window = Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("VibeRemote.AdvancedMenu")
        window.title = "Advanced Menu"
        window.isOpaque = false; window.backgroundColor = .clear
        // A second WindowServer shadow can outline the translucent shadow pixels,
        // producing a hard contour around the entire group. Use only our soft shadow.
        window.hasShadow = false; window.hidesOnDeactivate = false
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        let glassGroup = NSGlassEffectContainerView(frame: NSRect(origin: .zero, size: size))
        glassGroup.spacing = 0
        // Keep the material fully composited: lowering group alpha blends sharp
        // background detail back through the blur. AppKit owns accessibility variants.
        glassGroup.alphaValue = 1
        let canvas = Canvas(frame: glassGroup.bounds)
        glassGroup.contentView = canvas
        let root = Canvas(frame: glassGroup.frame)
        let shadow = ShadowView(frame: root.bounds)
        root.addSubview(glassGroup)
        // Glass must sample the actual background, not our custom shadow. The
        // foreground shadow is transparent throughout every glass button's interior.
        root.addSubview(shadow)
        // AppKit's window root layer has no superlayer. Give the animated group a
        // real, stationary parent so caret-based position animation has a stable space.
        window.contentView = Self.animationHost(containing: root)
        let x = padding, y = padding
        func glass(_ frame: NSRect) -> NSView {
            shadow.buttonFrames.append(frame)
            let view = NSGlassEffectView(frame: frame)
            view.style = .regular; view.cornerRadius = 18; view.effectIsInteractive = true
            let content = Canvas(frame: view.bounds); view.contentView = content
            canvas.addSubview(view); return content
        }
        func button(_ action: AdvancedMenuAction?, symbol: String, in view: NSView, frame: NSRect) {
            let button = NSButton(frame: frame)
            button.isBordered = false; button.imagePosition = .imageOnly
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: action?.title ?? "Close Advanced Menu")?.withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
            button.contentTintColor = .labelColor
            button.alphaValue = action == nil ? 0.55 : 1
            button.target = self
            button.action = action == nil ? #selector(closeClicked) : #selector(actionClicked(_:))
            button.identifier = NSUserInterfaceItemIdentifier(action?.rawValue ?? "close")
            button.setAccessibilityIdentifier("advanced.\(action?.rawValue ?? "close")")
            button.setAccessibilityLabel(action?.title ?? "Close Advanced Menu")
            view.addSubview(button)
        }
        let clear = glass(NSRect(x: x, y: y, width: 36, height: 36))
        button(.deleteAll, symbol: "delete.left.fill", in: clear, frame: clear.bounds)
        let skill = glass(NSRect(x: x+44, y: y, width: 36, height: 36))
        let skillSymbol = RemoteInputHandler.skillPickerTrigger(for: bundleID).text == "$" ? "dollarsign" : "line.diagonal"
        button(.skill, symbol: skillSymbol, in: skill, frame: skill.bounds)

        let close = glass(NSRect(x: x, y: y+88, width: 36, height: 36))
        button(nil, symbol: "xmark", in: close, frame: close.bounds)
        let sessions = glass(NSRect(x: x+44, y: y+44, width: 36, height: 80))
        button(.previousSession, symbol: "arrowshape.up.fill", in: sessions, frame: NSRect(x: 4, y: 4, width: 28, height: 28))
        button(.nextSession, symbol: "arrowshape.down.fill", in: sessions, frame: NSRect(x: 4, y: 48, width: 28, height: 28))
        shadow.needsDisplay = true
        panel = window
        animatedContent = root
        collapsedPosition = nil
        root.wantsLayer = true
        window.setFrame(frame, display: false)
        // Install the group animation before exposing the first visible frame.
        window.alphaValue = 0
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        animateAppearance(root, caretOnScreen: NSPoint(x: anchor.minX, y: anchor.midY))
        window.alphaValue = 1
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismiss() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { if event.window !== self?.panel { self?.dismiss() } }
            return event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let activatedPID = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, let activatedPID, activatedPID != self.targetPID else { return }
                self.dismiss()
            }
        }
        rmDebug("Advanced Menu opened for pid=\(pid) app=\(bundleID ?? "unknown") anchor=\(textAnchor?.source ?? "mouse") rect=\(anchor) frame=\(window.frame)")
    }
    static func frame(anchor: NSRect, size: NSSize, screen: NSRect) -> NSRect {
        // Keep the visible lower-left corner beside the caret and grow upward.
        // Only fall below the caret when there is not enough space above it.
        let proposedX = anchor.minX + 12 - contentPadding
        let below = anchor.minY - 12 - (size.height - contentPadding)
        let above = anchor.maxY + 12 - contentPadding
        let proposedY = above + size.height <= screen.maxY - 8 ? above : below
        let x = min(max(proposedX, screen.minX + 8), max(screen.minX + 8, screen.maxX - size.width - 8))
        let y = min(max(proposedY, screen.minY + 8), max(screen.minY + 8, screen.maxY - size.height - 8))
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
    static let appearanceStartScale: CGFloat = 0.20
    static func animationHost(containing content: NSView) -> NSView {
        let host = Canvas(frame: content.bounds)
        host.wantsLayer = true
        host.addSubview(content)
        content.wantsLayer = true
        return host
    }
    static func appearanceGeometry(in view: NSView, caretOnScreen: NSPoint) -> (caret: CGPoint, start: CGPoint, end: CGPoint)? {
        guard let window = view.window, let layer = view.layer, let parent = layer.superlayer else { return nil }
        let inWindow = window.convertPoint(fromScreen: caretOnScreen)
        let inView = view.convert(inWindow, from: nil)
        let inLayer = view.convertToLayer(inView)
        let caret = layer.convert(inLayer, to: parent)
        // Layer position lives in the parent's coordinates; its transform lives in
        // local coordinates. Animating them separately avoids flipped-Y translations.
        let end = layer.position
        let start = CGPoint(x: caret.x + appearanceStartScale * (end.x - caret.x),
                            y: caret.y + appearanceStartScale * (end.y - caret.y))
        return (caret, start, end)
    }
    private func animateAppearance(_ view: NSView, caretOnScreen: NSPoint) {
        guard let layer = view.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.16 / 1.1
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "appearance.opacity")
        guard let geometry = Self.appearanceGeometry(in: view, caretOnScreen: caretOnScreen) else { return }
        collapsedPosition = geometry.start
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // Keep the total entrance 1.1x faster than the previous critically damped
        // spring, including the small rebound (about 1.2% beyond the final size).
        let previousSpring = CASpringAnimation()
        previousSpring.mass = 1; previousSpring.stiffness = 500; previousSpring.damping = 45
        let entranceDuration = previousSpring.settlingDuration / 1.1
        func spring(_ keyPath: String) -> CASpringAnimation {
            let animation = CASpringAnimation(keyPath: keyPath)
            animation.mass = 1; animation.stiffness = 500
            animation.damping = 2 * sqrt(animation.mass * animation.stiffness) * 0.8
            animation.duration = animation.settlingDuration
            return animation
        }
        let scale = spring("transform.scale")
        scale.fromValue = Self.appearanceStartScale; scale.toValue = 1
        let position = spring("position")
        position.fromValue = NSValue(point: geometry.start); position.toValue = NSValue(point: geometry.end)
        let group = CAAnimationGroup()
        group.animations = [scale, position]; group.duration = scale.duration
        group.speed = Float(group.duration / entranceDuration)
        layer.add(group, forKey: "appearance.fromCaret")
        rmDebug("Advanced Menu animation: caretScreen=\(caretOnScreen) caretInParent=\(geometry.caret) start=\(geometry.start) end=\(geometry.end)")
    }
    @discardableResult
    static func animateDismissal(layer: CALayer, destination: CGPoint?, reduceMotion: Bool) -> TimeInterval {
        // Sample the displayed pose before removing entrance animations. A quick
        // release must reverse from its current size, not jump to the full-size menu.
        let displayed = layer.presentation() ?? layer
        let opacity = displayed.opacity
        let transform = displayed.transform
        let position = displayed.position
        let duration = reduceMotion ? 0.12 : 0.20
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = opacity; fade.toValue = 0
        var animations: [CAAnimation] = [fade]
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: "appearance.opacity")
        layer.removeAnimation(forKey: "appearance.fromCaret")
        layer.opacity = 0
        layer.transform = transform; layer.position = position
        if !reduceMotion, let destination {
            let collapsed = CATransform3DMakeScale(appearanceStartScale, appearanceStartScale, 1)
            let scale = CABasicAnimation(keyPath: "transform")
            scale.fromValue = NSValue(caTransform3D: transform); scale.toValue = NSValue(caTransform3D: collapsed)
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: position); move.toValue = NSValue(point: destination)
            animations += [scale, move]
            layer.transform = collapsed; layer.position = destination
        }
        for animation in animations { animation.duration = duration }
        let group = CAAnimationGroup()
        group.animations = animations; group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(group, forKey: "dismissal.toCaret")
        CATransaction.commit()
        return duration
    }
    private func finishDismissal() {
        dismissalCompletion?.cancel(); dismissalCompletion = nil
        closingPanel?.orderOut(nil); closingPanel = nil
    }
    func dismiss() {
        input.dismiss(); targetPID = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }; outsideMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }; activationObserver = nil
        guard let outgoing = panel else { return }
        panel = nil
        let layer = animatedContent?.layer
        animatedContent = nil
        let destination = collapsedPosition; collapsedPosition = nil
        finishDismissal()
        // The action and input state complete immediately. The departing window is
        // visual only and must not block clicks or execute a second menu action.
        outgoing.ignoresMouseEvents = true
        guard let layer else { outgoing.orderOut(nil); return }
        let duration = Self.animateDismissal(layer: layer, destination: destination,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        closingPanel = outgoing
        let completion = DispatchWorkItem { [weak self, weak outgoing] in
            MainActor.assumeIsolated {
                guard let outgoing else { return }
                outgoing.orderOut(nil)
                if self?.closingPanel === outgoing {
                    self?.closingPanel = nil; self?.dismissalCompletion = nil
                }
            }
        }
        dismissalCompletion = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: completion)
    }
    func reset() { dismiss(); input.reset() }
    private func perform(_ action: AdvancedMenuAction) {
        guard let pid = targetPID, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            rmDebug("Advanced Menu: \(action.rawValue) cancelled because focus changed")
            dismiss(); return
        }
        rmDebug("Advanced Menu: selected \(action.rawValue) for pid=\(pid)")
        dismiss()
        // Let input callbacks and the nonactivating panel finish before posting shortcuts.
        DispatchQueue.main.async { [weak self] in self?.onAction?(action, pid) }
    }
    @objc private func actionClicked(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue, let action = AdvancedMenuAction(rawValue: name) else { return }
        perform(action)
    }
    @objc private func closeClicked() { dismiss() }
}
