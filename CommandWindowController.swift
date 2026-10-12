import AppKit
import QuartzCore

private final class RemoteCommandPanel: NSPanel {
    var onCancel: (() -> Void)?
    var acceptsInput = true
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override var canBecomeKey: Bool { acceptsInput }
    override var canBecomeMain: Bool { false }
}

private final class CommandGlassCanvas: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class CommandWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let input = NSTextField(string: "")
    private let message = NSButton(title: "", target: nil, action: nil)
    private let runner = RemoteCommandRunner()
    private let preview = CommandPreviewController()
    private var target: NSRunningApplication?
    private let canvas = CommandGlassCanvas()
    private let bubble = CommandSpeechBubble()
    private let pointer = CommandPointerView()
    private var hasPreview = false
    private var editing = false
    private var stopping = false
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var presentationID = UUID()
    private var taskScreen: NSScreen?
    private static let inputSize = NSSize(width: 342, height: 134)
    // The pointer tip, rather than the bubble midpoint, belongs at screen center.
    private static let pointerTip = NSPoint(x: 36, y: 76)

    init() {
        let size = Self.inputSize
        let panel = RemoteCommandPanel(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "VibeRemote Command"
        panel.identifier = NSUserInterfaceItemIdentifier("VibeRemote.Command")
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true; panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.cancelOperation(nil) }

        canvas.frame = NSRect(origin: .zero, size: size)
        panel.contentView = canvas
        bubble.frame = NSRect(x: 32, y: 22, width: 278, height: 54)
        canvas.addSubview(bubble)
        pointer.frame = NSRect(x: 34, y: 74, width: 32, height: 32)
        canvas.addSubview(pointer)
        let content = bubble.content

        input.placeholderString = "What do you want me to do?"
        input.font = .systemFont(ofSize: 14, weight: .medium)
        input.textColor = .labelColor
        input.isBordered = false; input.isBezeled = false; input.drawsBackground = false
        input.focusRingType = .none; input.delegate = self
        // Focus changes must never submit. Return is handled explicitly below,
        // respecting IME marked text and native dictation's field editor.
        input.cell?.sendsActionOnEndEditing = false
        input.setAccessibilityIdentifier("VibeRemote.Command.Input")
        input.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(input)

        message.isBordered = false
        message.font = .systemFont(ofSize: 13, weight: .medium)
        message.lineBreakMode = .byTruncatingTail
        message.target = self; message.action = #selector(messageClicked)
        message.setAccessibilityIdentifier("VibeRemote.Command.Status")
        message.translatesAutoresizingMaskIntoConstraints = false
        message.isHidden = true
        content.addSubview(message)
        let menu = NSMenu()
        let stopItem = NSMenuItem(title: "停止任务", action: #selector(stop), keyEquivalent: "")
        stopItem.target = self; menu.addItem(stopItem)
        message.menu = menu
        pointer.menu = menu
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            input.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            input.centerYAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            input.heightAnchor.constraint(equalToConstant: 26),
            message.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            message.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            message.topAnchor.constraint(equalTo: content.topAnchor),
            message.heightAnchor.constraint(equalToConstant: 44)
        ])
        runner.onPreview = { [weak self] frame in
            guard let self else { return }
            self.preview.update(frame, on: self.taskScreen)
            self.hasPreview = frame != nil
            if frame != nil, !self.editing, self.runner.foregroundRequest == nil, !self.stopping, self.message.isHidden {
                self.window?.orderOut(nil)
            }
        }
        runner.onFinish = { [weak self] message in
            guard let self else { return }
            if self.runner.failed {
                self.showMessage("Couldn’t finish. Try again.", identifier: "VibeRemote.Command.Error")
                self.message.toolTip = message
                self.message.setAccessibilityHelp(message)
                let id = self.presentationID
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                    guard self?.presentationID == id else { return }
                    self?.dismiss()
                }
            } else { self.dismiss() }
            // Completion dismisses without restoring/stealing focus.
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func animateBubble(appearing: Bool) {
        bubble.animate(appearing: appearing)
    }

    private func showMessage(_ text: String, identifier: String) {
        input.isHidden = true; message.isHidden = false
        message.title = text
        message.setAccessibilityIdentifier(identifier)
        bubble.isHidden = false
        window?.ignoresMouseEvents = false
        window?.alphaValue = 1
        window?.orderFrontRegardless() // Never key or active during a task.
        animateBubble(appearing: true)
    }

    func present() {
        guard let panel = window as? RemoteCommandPanel else { return }
        // A short Siri tap cannot replace, resubmit or implicitly approve a task.
        guard !runner.running else {
            showMessage("Task running · Stop", identifier: "VibeRemote.Command.Stop")
            return
        }
        presentationID = UUID(); editing = true; stopping = false; hasPreview = false
        pointer.setWorking(false)
        bubble.isHidden = false
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            target = NSWorkspace.shared.frontmostApplication
        }
        taskScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        panel.acceptsInput = true; panel.ignoresMouseEvents = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.alphaValue = 1
        input.isHidden = false; message.isHidden = true
        panel.setContentSize(Self.inputSize)
        if let frame = taskScreen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.midX - Self.pointerTip.x,
                                         y: frame.midY - (panel.frame.height - Self.pointerTip.y)))
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil); panel.makeKeyAndOrderFront(nil)
        animateBubble(appearing: true); focusInput(); installOutsideMonitors()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.editing, self.window?.isKeyWindow == true else { return }
            self.focusInput()
        }
    }

    func focusInput() {
        guard editing else { return }
        window?.makeFirstResponder(input)
    }

    func prepareForDictation() {
        guard editing, window?.isKeyWindow == true else { return }
        focusInput()
    }

    private func installOutsideMonitors() {
        removeOutsideMonitors()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            MainActor.assumeIsolated { if self?.editing == true { self?.dismiss() } }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.editing, let window = self.window else { return }
                let point = self.bubble.convert(event.locationInWindow, from: nil)
                if event.window !== window || !self.bubble.bounds.contains(point) { self.dismiss() }
            }
            return event // The original click still reaches its destination.
        }
    }

    private func removeOutsideMonitors() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }; outsideMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }; localMonitor = nil
    }

    @objc private func submit() {
        guard editing, !runner.running else { return }
        let command = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        guard command.utf8.count <= 16_000 else { NSSound.beep(); return }
        do {
            try runner.start(command: command, target: "\(target?.localizedName ?? "Unknown") (\(target?.bundleIdentifier ?? "unknown"))")
            beginExecutionPresentation()
        } catch {
            // Setup failures remain visible briefly rather than masquerading as success.
            beginExecutionPresentation()
            showMessage("Couldn’t start. Try again.", identifier: "VibeRemote.Command.Error")
            message.toolTip = error.localizedDescription
            message.setAccessibilityHelp(error.localizedDescription)
            let id = presentationID
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard self?.presentationID == id else { return }
                self?.dismiss()
            }
        }
    }

    private func beginExecutionPresentation() {
        guard let panel = window as? RemoteCommandPanel else { return }
        editing = false; removeOutsideMonitors()
        input.stringValue = ""
        panel.makeFirstResponder(nil)
        panel.acceptsInput = false; panel.resignKey()
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pointer.setWorking(false)
        animateBubble(appearing: false)
        let id = presentationID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.presentationID == id, !self.editing,
                  self.runner.foregroundRequest == nil, !self.runner.failed,
                  self.message.isHidden else { return }
            self.bubble.isHidden = true
            self.window?.orderOut(nil)
        }
    }

    private func dismiss() {
        preview.hide(); pointer.setWorking(false)
        editing = false; removeOutsideMonitors()
        input.stringValue = ""
        let id = UUID(); presentationID = id
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.presentationID == id else { return }
                self.window?.orderOut(nil)
            }
        }
    }

    @objc private func messageClicked() {
        if runner.running { stop() }
        else { dismiss() }
    }

    @objc private func stop() {
        guard runner.running else { return }
        stopping = true
        runner.cancel(); dismiss()
    }
    func shutdown() { removeOutsideMonitors(); runner.cancel(); preview.hide() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if runner.running { stop() }
        dismiss(); return false
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Use the live field editor, not the possibly stale NSTextField value.
        // Option+Delete is the remote's Back mapping. Never dismiss while an IME
        // composition is active, or when this key is deleting the final character.
        if editing, !runner.running, !textView.hasMarkedText(), textView.string.isEmpty,
           commandSelector == #selector(NSResponder.deleteBackward(_:)) ||
           commandSelector == #selector(NSResponder.deleteWordBackward(_:)) {
            dismiss(); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() {
            submit(); return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelOperation(nil); return true
        }
        return false
    }
    override func cancelOperation(_ sender: Any?) {
        if runner.running { stop() } else { dismiss() }
    }
}

/// Native editable glass, with a small tail connecting the voice to its pointer.
private final class CommandSpeechBubble: NSView {
    override var isFlipped: Bool { true }
    let content = CommandGlassCanvas()
    private let glass = NSGlassEffectView()
    private let tail = NSGlassEffectView()
    private let shade = CALayer()
    private let knockout = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let group = NSGlassEffectContainerView()
        group.autoresizingMask = [.width, .height]
        group.spacing = 12
        addSubview(group)
        let surface = CommandGlassCanvas()
        group.contentView = surface
        surface.addSubview(tail); surface.addSubview(glass)
        glass.style = .regular; glass.cornerRadius = 18; glass.effectIsInteractive = true
        tail.style = .regular; tail.cornerRadius = 9
        glass.contentView = content
        shade.shadowColor = NSColor.black.cgColor
        shade.shadowOpacity = 0.18; shade.shadowRadius = 12
        shade.shadowOffset = CGSize(width: 0, height: 5)
        knockout.fillRule = .evenOdd; shade.mask = knockout
        layer?.insertSublayer(shade, at: 0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
        glass.superview?.frame = bounds
        glass.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 44)
        tail.frame = NSRect(x: 4, y: 36, width: 18, height: 18)
        // Keep the field out of the tail and preserve a native field editor for IME/dictation.
        content.frame = glass.bounds
        let shape = CGMutablePath()
        let w = bounds.width
        shape.move(to: CGPoint(x: 18, y: 0))
        shape.addLine(to: CGPoint(x: w - 18, y: 0))
        shape.addQuadCurve(to: CGPoint(x: w, y: 18), control: CGPoint(x: w, y: 0))
        shape.addLine(to: CGPoint(x: w, y: 26))
        shape.addQuadCurve(to: CGPoint(x: w - 18, y: 44), control: CGPoint(x: w, y: 44))
        shape.addLine(to: CGPoint(x: 30, y: 44))
        shape.addQuadCurve(to: CGPoint(x: 8, y: 54), control: CGPoint(x: 20, y: 54))
        shape.addQuadCurve(to: CGPoint(x: 4, y: 40), control: CGPoint(x: 1, y: 54))
        shape.addQuadCurve(to: CGPoint(x: 0, y: 26), control: CGPoint(x: 0, y: 36))
        shape.addLine(to: CGPoint(x: 0, y: 18))
        shape.addQuadCurve(to: CGPoint(x: 18, y: 0), control: .zero)
        shape.closeSubpath()
        shade.frame = bounds; shade.shadowPath = shape
        let outside = CGMutablePath()
        outside.addRect(bounds.insetBy(dx: -40, dy: -40)); outside.addPath(shape)
        knockout.frame = bounds; knockout.path = outside
    }

    func animate(appearing: Bool) {
        wantsLayer = true
        guard let layer else { return }
        let currentOpacity = layer.presentation()?.opacity ?? layer.opacity
        let currentTransform = layer.presentation()?.transform ?? layer.transform
        layer.removeAllAnimations()
        let anchor = CGPoint(x: 4 - bounds.midX, y: 54 - bounds.midY)
        var small = CATransform3DMakeTranslation(anchor.x, anchor.y, 0)
        small = CATransform3DScale(small, 0.82, 0.82, 1)
        small = CATransform3DTranslate(small, -anchor.x, -anchor.y, 0)
        let target = appearing ? CATransform3DIdentity : small
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.opacity = appearing ? 1 : 0; layer.transform = target
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = appearing && currentOpacity == 1 ? 0 : currentOpacity
        fade.toValue = appearing ? 1 : 0
        fade.duration = appearing ? 0.22 : 0.16
        layer.add(fade, forKey: "speechFade")
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let scale = CASpringAnimation(keyPath: "transform")
            scale.fromValue = NSValue(caTransform3D: appearing && currentOpacity == 1 ? small : currentTransform)
            scale.toValue = NSValue(caTransform3D: target)
            scale.mass = 1; scale.stiffness = 320; scale.damping = 35
            scale.duration = appearing ? 0.32 : 0.16
            layer.add(scale, forKey: "speechScale")
        }
    }
}

private final class CommandPointerView: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        CommandPointerArtwork.draw(at: NSPoint(x: 2, y: 2), scale: 1.05)
    }
    func setWorking(_ working: Bool) {
        wantsLayer = true
        layer?.removeAnimation(forKey: "working")
        guard working, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1; pulse.toValue = 0.55
        pulse.duration = 0.7; pulse.autoreverses = true; pulse.repeatCount = .infinity
        layer?.add(pulse, forKey: "working")
    }
}
