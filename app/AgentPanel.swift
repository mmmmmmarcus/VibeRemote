import AppKit
import Combine
import SwiftUI

/// State of Computer Use, shown in the Dock callout. One command runs at a time.
@MainActor
final class ComputerUseAgent: ObservableObject {
    enum Phase: Equatable { case composing, running, finished(String), failed(String) }

    static let stepLimit = 40

    @Published var command = ""
    @Published private(set) var phase: Phase = .composing {
        didSet { if phase != oldValue { onPhaseChange?(phase) } }
    }
    @Published private(set) var steps: [String] = []
    @Published private(set) var latestMessage: String?
    /// The one line the callout shows while a command runs: whichever came last of the
    /// agent's message or its most recent step.
    @Published private(set) var status: String?
    @Published var settings: AgentSettings { didSet { if settings != oldValue { settings.save() } } }
    @Published private(set) var hasOpenRouterKey: Bool
    /// Codex's own model list, re-read each time the panel opens.
    @Published private(set) var codexModels = AgentModelCatalog.codex()
    /// Bumped whenever the command field should take keyboard focus again.
    @Published private(set) var focusRequest = 0
    private(set) var context = AgentContext()
    private var run: AgentRun?
    var onRunStarted: (() -> Void)?
    /// Drives the Dock tile: blue while composing, green while a command runs.
    var onPhaseChange: ((Phase) -> Void)?

    init(settings: AgentSettings = .load(), hasOpenRouterKey: Bool = AgentKeychain.openRouterKey() != nil) {
        self.settings = settings
        self.hasOpenRouterKey = hasOpenRouterKey
    }

    var isRunning: Bool { phase == .running }
    var canSubmit: Bool { !isRunning && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A finished command stays readable until the panel opens again for a new one.
    func prepare(context: AgentContext) {
        guard !isRunning else { return }
        self.context = context
        // Settings' Agent pane writes the same defaults and Keychain item.
        let saved = AgentSettings.load()
        if saved != settings { settings = saved }
        hasOpenRouterKey = AgentKeychain.openRouterKey() != nil
        codexModels = AgentModelCatalog.codex()
        if phase != .composing { startOver() }
        focusRequest += 1
    }

    func submit() {
        guard canSubmit else { return }
        var settings = self.settings
        if settings.openRouterModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.openRouterModel = AgentSettings.defaultOpenRouterModel
        }
        steps = []
        latestMessage = nil
        status = nil
        phase = .running
        let run = AgentRun { [weak self] event in self?.handle(event) }
        self.run = run
        run.start(command: command.trimmingCharacters(in: .whitespacesAndNewlines), context: context, settings: settings)
        onRunStarted?()
    }

    func stop() { run?.stop() }

    /// Puts the cursor back in the command field, e.g. each time the callout pops up.
    func requestFocus() { focusRequest += 1 }

    func startOver() {
        guard !isRunning else { return }
        command = ""
        steps = []
        latestMessage = nil
        status = nil
        phase = .composing
        focusRequest += 1
    }

    func saveOpenRouterKey(_ key: String) {
        AgentKeychain.setOpenRouterKey(key)
        hasOpenRouterKey = AgentKeychain.openRouterKey() != nil
    }

    func handle(_ event: AgentEvent) {
        switch event {
        case .action(let label):
            steps.append(label)
            if steps.count > Self.stepLimit { steps.removeFirst(steps.count - Self.stepLimit) }
            status = label
        case .message(let text):
            latestMessage = text
            status = text
        case .finished(let text):
            phase = .finished(text ?? "Done.")
            run = nil
        case .failed(let text):
            phase = .failed(text)
            run = nil
        }
    }
}

/// Computer Use pops up from VibeRemote's Dock icon. It takes focus while composing so the
/// user's dictation or input method types the command into it, then hands focus back to the
/// target app while the agent works and the tile stays green. See AgentDock.swift.
@MainActor
final class AgentPanelController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 360
    /// How long a finished command's outcome stays up unless the user clicks into the callout.
    static let resultLifetime: TimeInterval = 8

    let agent = ComputerUseAgent()
    private let callout = AgentCalloutModel()
    private let tile = AgentDockTile()
    private var panel: AgentCalloutPanel?
    private var hosting: NSHostingController<AgentCalloutView>?
    private var previousApp: NSRunningApplication?
    private var iconFrame: CGRect?
    private var presentation: Task<Void, Never>?
    private var resultDismissal: DispatchWorkItem?
    /// True while VibeRemote shows its Dock icon on Computer Use's behalf.
    private(set) var holdsDock = false

    var isVisible: Bool { panel?.isVisible == true }

    override init() {
        super.init()
        agent.onRunStarted = { [weak self] in self?.commandSent() }
        agent.onPhaseChange = { [weak self] phase in self?.phaseChanged(phase) }
    }

    /// The menu-bar item: open a fresh command, or put the callout away.
    func toggle() { isVisible ? dismiss() : show(fresh: true) }

    /// Long-press TV: stop a running command, close an open callout, or open a fresh one.
    func remoteLongPress() {
        if agent.isRunning { agent.stop() }
        else if isVisible { dismiss() }
        else { show(fresh: true) }
    }

    /// A click on the Dock icon while Computer Use owns it shows the input bar: the running
    /// command with its Stop button, or a fresh field once a command has finished. Returns
    /// false otherwise so the app delegate keeps its ordinary reopen behavior (Settings).
    func dockClicked() -> Bool {
        guard holdsDock else { return false }
        if panel?.isKeyWindow == true { dismiss() } else { show(fresh: !agent.isRunning) }
        return true
    }

    func show(fresh: Bool) {
        resultDismissal?.cancel()
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
        }
        if fresh {
            agent.prepare(context: previousApp.map {
                AgentContext(appName: $0.localizedName, bundleID: $0.bundleIdentifier)
            } ?? agent.context)
        }
        holdDock()
        if agent.phase == .composing { tile.apply(.composing) }
        present(key: true)
    }

    func dismiss() {
        presentation?.cancel()
        resultDismissal?.cancel()
        let wasKey = panel?.isKeyWindow == true
        panel?.orderOut(nil)
        // A running command keeps the green tile; anything else gives the Dock icon back.
        if !agent.isRunning { releaseDock() }
        if wasKey { returnFocus() }
    }

    /// Remote Select while the callout has focus sends the command, or starts a new one after
    /// a result. Both edges are consumed so caret positioning never sees half a click.
    func handleRemoteButton(_ button: String, pressed: Bool) -> Bool {
        guard button == "select", let panel, panel.isVisible, panel.isKeyWindow, NSApp.isActive else { return false }
        guard pressed else { return true }
        switch agent.phase {
        case .composing: agent.submit()
        case .running: break
        case .finished, .failed: agent.startOver()
        }
        return true
    }

    // MARK: Phases

    /// The callout stays up, now showing the agent's latest status, but gives focus back so
    /// the agent works in the app the user was in. It floats above other windows unfocused.
    private func commandSent() {
        tile.apply(.working)
        returnFocus()
    }

    private func phaseChanged(_ phase: ComputerUseAgent.Phase) {
        switch phase {
        case .composing:
            if holdsDock { tile.apply(.composing) }
        case .running:
            tile.apply(.working)
        case .finished, .failed:
            guard holdsDock else { return }
            let failed: Bool
            if case .failed = phase { failed = true } else { failed = false }
            // The bar's status line becomes the outcome and the tile gets a badge; both stay
            // briefly so the user can see them, then the callout and Dock icon go away.
            tile.apply(.normal, badge: failed ? "!" : "✓")
            scheduleResultDismissal()
        }
    }

    private func scheduleResultDismissal() {
        resultDismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.agent.isRunning, self.agent.phase != .composing,
                  self.panel?.isKeyWindow != true else { return }
            self.dismiss()
        }
        resultDismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.resultLifetime, execute: work)
    }

    // MARK: Dock

    /// The app is menu-bar only; a regular activation policy is what puts its icon in the Dock.
    private func holdDock() {
        guard !holdsDock else { return }
        holdsDock = true
        DockPresence.computerUseHoldsDock = true
        NSApp.setActivationPolicy(.regular)
    }

    private func releaseDock() {
        guard holdsDock else { return }
        holdsDock = false
        DockPresence.computerUseHoldsDock = false
        tile.apply(.normal, badge: nil)
        restoreAccessoryPolicy(closing: nil)
    }

    private func returnFocus() {
        guard let previousApp, !previousApp.isTerminated else { return }
        previousApp.activate()
    }

    // MARK: Presentation

    /// Waits for the Dock icon to settle (a newly shown icon slides in), then pops the callout
    /// up from it. Without a located icon the callout floats above the bottom of the screen.
    private func present(key: Bool) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        presentation?.cancel()
        presentation = Task { @MainActor [weak self] in
            let icon = await Self.settledIconFrame()
            guard let self, !Task.isCancelled else { return }
            self.iconFrame = icon
            self.place(panel, fitting: true)
            if key {
                // A remote press is no user event in this app, so cooperative activate() can be
                // refused; the field then has no focus and input methods type into the old app.
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                self.agent.requestFocus()
            } else {
                panel.orderFrontRegardless()
            }
            rmDebug("🤖 Computer Use callout shown key=\(key) icon=\(icon.map { "\($0)" } ?? "none") active=\(NSApp.isActive)")
        }
    }

    /// Two equal reads 50 ms apart, within 0.8 s; the last read otherwise.
    private static func settledIconFrame() async -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        var last: CGRect?
        for _ in 0..<16 {
            let frame = DockIconLocator.iconFrame()
            if let frame, frame == last { return frame }
            last = frame
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled { return last }
        }
        return last
    }

    private func place(_ panel: NSPanel, fitting: Bool) {
        let screen = iconFrame.flatMap { icon in
            NSScreen.screens.first { $0.frame.intersects(icon) }
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        callout.edge = iconFrame.map { DockCalloutPlacement.edge(of: $0, in: screen.frame) }
        var size = panel.frame.size
        if fitting, let view = hosting?.view {
            view.layoutSubtreeIfNeeded()
            size = view.fittingSize
        }
        let placement = DockCalloutPlacement.place(size: size, icon: iconFrame,
                                                   screen: screen.frame, visible: screen.visibleFrame)
        callout.arrowOffset = placement.arrowOffset
        panel.setFrame(NSRect(origin: placement.origin, size: size), display: true)
    }

    /// The callout grows with its text and phase; keep its arrow on the icon afterwards.
    func windowDidResize(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        place(panel, fitting: false)
    }

    private func makePanel() -> AgentCalloutPanel {
        let panel = AgentCalloutPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("VibeRemote.AgentPanel")
        panel.title = "Computer Use"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The glass draws its own edge; a WindowServer shadow would outline the arrow's alpha.
        panel.hasShadow = false
        // Above the Dock, which it points at.
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let hosting = NSHostingController(rootView: AgentCalloutView(
            agent: agent, callout: callout, dismiss: { [weak self] in self?.dismiss() }))
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear
        panel.contentViewController = hosting
        self.hosting = hosting
        return panel
    }
}

/// Lets `restoreAccessoryPolicy` keep the Dock icon while Computer Use is using it.
@MainActor
enum DockPresence {
    static var computerUseHoldsDock = false
}

/// Borderless, so it must opt in to key status for the command field to take input.
final class AgentCalloutPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AgentCalloutModel: ObservableObject {
    @Published var edge: DockEdge? = .bottom
    @Published var arrowOffset: CGFloat = AgentPanelController.width / 2
}

/// Only the input bar. Composing, it is the field and its Send button. While a command runs
/// (the callout stays up), the field gives way to one status line, the agent's latest step
/// or message, and Send becomes Stop; after it finishes, the same line shows the outcome.
struct AgentCalloutView: View {
    @ObservedObject var agent: ComputerUseAgent
    @ObservedObject var callout: AgentCalloutModel
    let dismiss: () -> Void
    @FocusState private var commandFocused: Bool

    var body: some View {
        HStack(alignment: agent.phase == .composing ? .bottom : .center, spacing: 8) {
            switch agent.phase {
            case .composing:
                TextField("What do you want to do?", text: $agent.command, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(1...5)
                    .focused($commandFocused)
                    .onSubmit { agent.submit() }
                    .padding(.vertical, 4)
                    .accessibilityLabel("Computer Use")
                    .accessibilityIdentifier("VibeRemote.Agent.Command")
                barButton("arrow.up", label: "Send", id: "VibeRemote.Agent.Send") { agent.submit() }
                    .disabled(!agent.canSubmit)
            case .running:
                ProgressView().controlSize(.small)
                statusLine(agent.status ?? "Working…")
                barButton("stop.fill", label: "Stop", id: "VibeRemote.Agent.Stop") { agent.stop() }
            case .finished(let text):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                statusLine(text)
            case .failed(let text):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                statusLine(text)
            }
        }
        .padding(12)
        .frame(width: AgentPanelController.width, alignment: .leading)
        .padding(.bottom, callout.edge == .bottom ? DockCalloutPlacement.arrowLength : 0)
        .padding(.leading, callout.edge == .left ? DockCalloutPlacement.arrowLength : 0)
        .padding(.trailing, callout.edge == .right ? DockCalloutPlacement.arrowLength : 0)
        .glassEffect(.regular, in: DockCalloutShape(edge: callout.edge, arrowOffset: callout.arrowOffset))
        .onExitCommand(perform: dismiss)
        .onAppear { commandFocused = true }
        .onChange(of: agent.focusRequest) { commandFocused = true }
    }

    private func statusLine(_ text: String) -> some View {
        Text(text)
            .font(.title3)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .help(text)
            .accessibilityIdentifier("VibeRemote.Agent.Status")
    }

    private func barButton(_ symbol: String, label: String, id: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}
