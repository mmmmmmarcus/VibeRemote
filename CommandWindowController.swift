import AppKit

private final class RemoteCommandPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CommandWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let input = NSTextField(string: "")
    private let result = NSTextView()
    private let status = NSTextField(labelWithString: "用一句话告诉电脑你想做什么")
    private let runButton = NSButton(title: "执行 ↵", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private let continueButton = NSButton(title: "继续执行", target: nil, action: nil)
    private let runner = RemoteCommandRunner()
    private var target: NSRunningApplication?

    init() {
        let panel = RemoteCommandPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 290),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "VibeRemote Command"
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.cancelOperation(nil) }
        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow; backdrop.blendingMode = .behindWindow; backdrop.state = .active
        panel.contentView = backdrop
        let title = NSTextField(labelWithString: "你想做什么？")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        input.placeholderString = "例如：打开计算器，计算 128 × 36"
        input.font = .systemFont(ofSize: 17)
        input.focusRingType = .none
        input.delegate = self
        input.target = self; input.action = #selector(submit)
        input.setAccessibilityIdentifier("VibeRemote.Command.Input")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        result.isEditable = false; result.isSelectable = true
        result.drawsBackground = false; result.font = .systemFont(ofSize: 14)
        result.textColor = .labelColor
        let scroll = NSScrollView()
        scroll.documentView = result; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        result.isVerticallyResizable = true; result.isHorizontallyResizable = false
        result.autoresizingMask = [.width]
        result.textContainer?.widthTracksTextView = true
        runButton.bezelStyle = .rounded; runButton.target = self; runButton.action = #selector(submit)
        stopButton.bezelStyle = .rounded; stopButton.target = self; stopButton.action = #selector(stop)
        stopButton.isEnabled = false
        continueButton.bezelStyle = .rounded
        continueButton.target = self; continueButton.action = #selector(continueForeground)
        continueButton.isHidden = true
        continueButton.setAccessibilityIdentifier("VibeRemote.Command.Continue")
        let hint = NSTextField(labelWithString: "Codex · Cua Driver   |   Esc 关闭 / 停止")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .tertiaryLabelColor
        let footer = NSStackView(views: [hint, NSView(), stopButton, continueButton, runButton])
        footer.orientation = .horizontal; footer.spacing = 10
        let stack = NSStackView(views: [title, input, status, scroll, footer])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 40),
            stack.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -20),
            input.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 65),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        runner.onProgress = { [weak self] text in self?.result.string = text }
        runner.onForegroundRequest = { [weak self] request in
            guard let self else { return }
            self.continueButton.isHidden = request == nil
            self.continueButton.isEnabled = request != nil
            if let request {
                let name = request.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "目标应用"
                self.status.stringValue = "已暂停 · 等待你允许使用前台窗口"
                self.result.string = "接下来需要在「\(name)」中\(request.actionName)。\n\n点击「继续执行」后将执行这一步，可能切换桌面或暂时占用鼠标键盘。后续操作仍默认在后台执行。"
                // Update in place. Never order front, activate, or switch Space to ask for consent.
            } else if self.runner.running {
                self.status.stringValue = "正在后台执行 · 需要前台时会暂停"
            }
        }
        runner.onFinish = { [weak self] text in
            guard let self else { return }
            self.result.string = text; self.status.stringValue = "任务结束 · 可输入下一条命令"
            self.setRunning(false)
            // Never steal focus back from the target app when work finishes.
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        guard let window else { return }
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier {
            target = NSWorkspace.shared.frontmostApplication
        }
        if !window.isVisible {
            let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                window.setFrameOrigin(NSPoint(x: frame.midX - window.frame.width / 2,
                                              y: frame.midY - window.frame.height / 2 + 100))
            }
        }
        window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil); window.makeKeyAndOrderFront(nil)
        focusInput()
        // Activation can finish after orderFront when invoked from a HID callback.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isKeyWindow == true else { return }
            self.focusInput()
        }
    }

    func focusInput() {
        window?.makeFirstResponder(input)
    }

    func prepareForDictation() {
        guard window?.isKeyWindow == true else { return }
        focusInput()
    }

    @objc private func submit() {
        guard !runner.running else { return }
        let command = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        guard command.utf8.count <= 16_000 else {
            status.stringValue = "命令太长，请缩短后重试。"; return
        }
        do {
            try runner.start(command: command, target: "\(target?.localizedName ?? "Unknown") (\(target?.bundleIdentifier ?? "unknown"))")
            setRunning(true); result.string = "正在连接 Codex 和 Cua Driver…"
            status.stringValue = "正在后台执行 · 需要前台时会暂停"
            window?.level = .normal
        } catch { status.stringValue = error.localizedDescription }
    }

    private func setRunning(_ value: Bool) {
        // A running command must not block dictation/editing of the next request.
        input.isEnabled = true; runButton.isEnabled = !value; stopButton.isEnabled = value
    }
    @objc private func continueForeground() {
        continueButton.isEnabled = false
        status.stringValue = "已允许本次前台操作…"
        runner.continueForeground()
    }
    @objc private func stop() {
        runner.cancel(); status.stringValue = "正在停止…"
    }
    func shutdown() { runner.cancel() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if runner.running { stop() }
        return true
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if runner.running { stop() } else { window?.close() }
            return true
        }
        return false
    }
    override func cancelOperation(_ sender: Any?) {
        if runner.running { stop() } else { window?.close() }
    }
}
