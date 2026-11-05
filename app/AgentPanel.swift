import AppKit
import Combine
import SwiftUI

/// State of the computer-use agent shown in the panel. One command runs at a time.
@MainActor
final class ComputerUseAgent: ObservableObject {
    enum Phase: Equatable { case composing, running, finished(String), failed(String) }

    static let stepLimit = 40

    @Published var command = ""
    @Published private(set) var phase: Phase = .composing
    @Published private(set) var steps: [String] = []
    @Published private(set) var latestMessage: String?
    @Published var settings: AgentSettings { didSet { if settings != oldValue { settings.save() } } }
    @Published private(set) var hasOpenRouterKey: Bool
    /// Codex's own model list, re-read each time the panel opens.
    @Published private(set) var codexModels = AgentModelCatalog.codex()
    /// Bumped whenever the command field should take keyboard focus again.
    @Published private(set) var focusRequest = 0
    private(set) var context = AgentContext()
    private var run: AgentRun?
    var onRunStarted: (() -> Void)?

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
        phase = .running
        let run = AgentRun { [weak self] event in self?.handle(event) }
        self.run = run
        run.start(command: command.trimmingCharacters(in: .whitespacesAndNewlines), context: context, settings: settings)
        onRunStarted?()
    }

    func stop() { run?.stop() }

    func startOver() {
        guard !isRunning else { return }
        command = ""
        steps = []
        latestMessage = nil
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
        case .message(let text):
            latestMessage = text
        case .finished(let text):
            phase = .finished(text ?? "Done.")
            run = nil
        case .failed(let text):
            phase = .failed(text)
            run = nil
        }
    }
}

/// Floating panel for the computer-use agent. It takes focus while composing so the user's
/// dictation app types the command into it, then hands focus back while the agent works.
@MainActor
final class AgentPanelController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 400

    let agent = ComputerUseAgent()
    private var panel: NSPanel?
    private var previousApp: NSRunningApplication?

    var isVisible: Bool { panel?.isVisible == true }

    override init() {
        super.init()
        agent.onRunStarted = { [weak self] in self?.returnFocus() }
    }

    func toggle() { isVisible ? close() : show() }

    /// Long-press TV: open the panel, stop a running command, or close a finished one.
    func remoteLongPress() {
        if !isVisible { show() }
        else if agent.isRunning { agent.stop() }
        else { close() }
    }

    func show() {
        let front = NSWorkspace.shared.frontmostApplication
        if let front, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = front
            agent.prepare(context: AgentContext(appName: front.localizedName, bundleID: front.bundleIdentifier))
        } else {
            agent.prepare(context: agent.context)
        }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible { position(panel) }
        // The remote is not a user event in this app, so cooperative activate() can be refused:
        // the panel then floats without focus and dictation apps paste into the previous app.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            rmDebug("🤖 Agent panel shown for \(self?.previousApp?.bundleIdentifier ?? "unknown") active=\(NSApp.isActive) key=\(panel.isKeyWindow)")
        }
    }

    func close() {
        agent.stop()
        guard let panel, panel.isVisible else { return }
        let wasKey = panel.isKeyWindow
        panel.orderOut(nil)
        if wasKey { returnFocus() }
    }

    /// Remote Select while the panel has focus runs the command, or starts a new one after a
    /// result. Both edges are consumed so caret positioning never sees half a click.
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

    func windowWillClose(_ notification: Notification) {
        agent.stop()
        returnFocus()
    }

    private func returnFocus() {
        guard let previousApp, !previousApp.isTerminated else { return }
        previousApp.activate()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("VibeRemote.AgentPanel")
        panel.title = "Agent"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        // Stays visible while the target app has focus and the agent works.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let hosting = NSHostingController(rootView: AgentPanelView(agent: agent))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 48))
    }
}

struct AgentPanelView: View {
    @ObservedObject var agent: ComputerUseAgent
    @FocusState private var commandFocused: Bool
    @State private var keyDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.motionlines")
                    .foregroundStyle(.tint)
                Text("Agent")
                    .font(.headline)
                if let app = agent.context.appName {
                    Text("· \(app)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Picker("Backend", selection: $agent.settings.backend) {
                    ForEach(AgentBackend.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(agent.isRunning)
                .accessibilityIdentifier("VibeRemote.Agent.Backend")
            }
            // The title bar is transparent; keep the header clear of the close button.
            .padding(.leading, 56)

            if !agent.isRunning {
                modelFields
            }

            if agent.phase == .composing {
                TextField("Hold Siri and say what to do", text: $agent.command, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .padding(12)
                    .glassEffect(in: RoundedRectangle(cornerRadius: 14))
                    .focused($commandFocused)
                    .onSubmit { agent.submit() }
                    .accessibilityIdentifier("VibeRemote.Agent.Command")
            } else {
                Text(agent.command)
                    .font(.title3)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            if !agent.steps.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(agent.steps.suffix(5).enumerated()), id: \.offset) { _, step in
                        Label(step, systemImage: "chevron.right")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            status

            HStack {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                actionButton
            }
        }
        .padding(16)
        .frame(width: AgentPanelController.width)
        .onAppear { commandFocused = true }
        .onChange(of: agent.focusRequest) { commandFocused = true }
    }

    @ViewBuilder private var status: some View {
        switch agent.phase {
        case .composing:
            EmptyView()
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(agent.latestMessage ?? "Working with \(agent.settings.backend.title)…")
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
        case .finished(let text):
            Label(text, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private var actionButton: some View {
        switch agent.phase {
        case .composing:
            Button("Run") { agent.submit() }
                .buttonStyle(.glassProminent)
                .disabled(!agent.canSubmit)
                .accessibilityIdentifier("VibeRemote.Agent.Run")
        case .running:
            Button("Stop") { agent.stop() }
                .buttonStyle(.glass)
                .accessibilityIdentifier("VibeRemote.Agent.Stop")
        case .finished, .failed:
            Button("New Command") { agent.startOver() }
                .buttonStyle(.glass)
                .accessibilityIdentifier("VibeRemote.Agent.NewCommand")
        }
    }

    private var hint: String {
        switch agent.phase {
        case .composing: return "Hold Siri to dictate · Select to run"
        case .running: return "Hold TV to stop"
        case .finished, .failed: return "Select for a new command · Hold TV to close"
        }
    }

    @ViewBuilder private var modelFields: some View {
        switch agent.settings.backend {
        case .claudeCode:
            modelPicker(AgentModelCatalog.choices(AgentModelCatalog.claudeCode, keeping: agent.settings.claudeModel),
                        selection: $agent.settings.claudeModel)
        case .codex:
            modelPicker(AgentModelCatalog.choices(agent.codexModels, keeping: agent.settings.codexModel),
                        selection: $agent.settings.codexModel)
        case .openRouter:
            openRouterFields
        }
    }

    private func modelPicker(_ choices: [AgentModelChoice], selection: Binding<String>) -> some View {
        HStack {
            Text("Model").frame(width: 56, alignment: .leading)
            Picker("Model", selection: selection) {
                ForEach(choices, id: \.id) { Text($0.title).tag($0.id) }
            }
            .labelsHidden()
            .accessibilityIdentifier("VibeRemote.Agent.Model")
        }
        .font(.callout)
    }

    private var openRouterFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Model").frame(width: 56, alignment: .leading)
                TextField(AgentSettings.defaultOpenRouterModel, text: $agent.settings.openRouterModel)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("VibeRemote.Agent.Model")
                Menu {
                    ForEach(AgentModelCatalog.openRouterSuggestions, id: \.self) { model in
                        Button(model) { agent.settings.openRouterModel = model }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Suggested models")
            }
            HStack {
                Text("API key").frame(width: 56, alignment: .leading)
                SecureField(agent.hasOpenRouterKey ? "Saved in Keychain" : "sk-or-…", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(saveKey)
                    .accessibilityIdentifier("VibeRemote.Agent.APIKey")
                Button("Save", action: saveKey)
                    .disabled(keyDraft.isEmpty)
            }
        }
        .font(.callout)
    }

    private func saveKey() {
        guard !keyDraft.isEmpty else { return }
        agent.saveOpenRouterKey(keyDraft)
        keyDraft = ""
    }
}
