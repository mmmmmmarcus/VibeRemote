import AppKit
import SwiftUI

/// Settings metrics and colors, matching Spotter's Settings window so both apps read as one
/// family: a 208-point sidebar of icon-tile rows and native grouped-Form panes.
enum SettingsMetrics {
    static let sidebarWidth: CGFloat = 208
    static let rowIcon: CGFloat = 20
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 10
    static let xl: CGFloat = 12
    static let xxl: CGFloat = 20
    static let rowRadius: CGFloat = 10
    static let tileRadius: CGFloat = 6

    static let selection = adaptive(dark: .white.opacity(0.10), light: .black.opacity(0.08))
    static let rowHover = adaptive(dark: .white.opacity(0.05), light: .black.opacity(0.04))
    static let controlSurface = adaptive(dark: .white.opacity(0.10), light: .black.opacity(0.08))

    private static func adaptive(dark: Color, light: Color) -> Color {
        let dark = NSColor(dark), light = NSColor(light)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

struct SettingsVisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

// MARK: - Root

struct SettingsRootView: View {
    @ObservedObject var model: RemoteSettingsModel
    @ObservedObject private var updater = AppUpdater.shared
    let setSiriAction: (ButtonAction) -> Void
    let restoreDefaults: () -> Void
    let setIdleTimeout: (RemoteIdleTimeout) -> Void
    let actions: SettingsActions

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Group {
                switch model.tab {
                case .remote:
                    RemotePane(model: model, setSiriAction: setSiriAction,
                               restoreDefaults: restoreDefaults, setIdleTimeout: setIdleTimeout)
                case .buttons: ButtonsPane(snapshot: model.snapshot)
                case .agent: AgentPane(openPanel: actions.openAgentPanel)
                case .microphone: MicrophonePane(model: model, actions: actions)
                case .diagnostics: DiagnosticsPane(diagnostics: model.diagnostics, actions: actions)
                case .about: AboutPane(updater: updater, showOnboarding: actions.showOnboarding)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(SettingsVisualEffect(material: .contentBackground).ignoresSafeArea())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.xs / 2) {
                header("Remote")
                rows(SettingsTab.remoteTabs)
                header("Features").padding(.top, SettingsMetrics.md)
                rows(SettingsTab.featureTabs)
                header("VibeRemote").padding(.top, SettingsMetrics.md)
                rows(SettingsTab.appTabs)
            }
        }
        .scrollIndicators(.never)
        .padding(.top, SettingsMetrics.md)
        .padding(.horizontal, SettingsMetrics.md)
        .frame(width: SettingsMetrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(
            ZStack(alignment: .trailing) {
                SettingsVisualEffect(material: .sidebar)
                Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            }
            .ignoresSafeArea()
        )
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, SettingsMetrics.md)
            .padding(.vertical, SettingsMetrics.xs)
    }

    private func rows(_ tabs: [SettingsTab]) -> some View {
        ForEach(tabs) { tab in
            SettingsSidebarRow(tab: tab, isSelected: model.tab == tab,
                               badge: tab == .about && updater.updateAvailable) { model.tab = tab }
        }
    }
}

private struct SettingsSidebarRow: View {
    let tab: SettingsTab
    let isSelected: Bool
    let badge: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SettingsMetrics.lg) {
                RoundedRectangle(cornerRadius: SettingsMetrics.tileRadius, style: .continuous)
                    .fill(SettingsMetrics.controlSurface)
                    .overlay {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 12))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: SettingsMetrics.rowIcon, height: SettingsMetrics.rowIcon)
                Text(tab.title).font(.body).lineLimit(1)
                Spacer(minLength: 0)
                if badge {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                        .accessibilityLabel("Update available")
                }
            }
            .padding(.horizontal, SettingsMetrics.md)
            .padding(.vertical, SettingsMetrics.sm)
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius, style: .continuous)
                    .fill(isSelected ? SettingsMetrics.selection : hovering ? SettingsMetrics.rowHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
        .accessibilityIdentifier("settings.sidebar.\(tab.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Pane scaffold

/// A pane: its title, then the grouped `Form` holding its sections. macOS owns row metrics,
/// separators, group backgrounds and the label/control accessibility pairing.
struct SettingsPane<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.title2.weight(.bold))
                // Lines the title up with the leading edge of the Form's section boxes.
                .padding(.horizontal, SettingsMetrics.xxl)
                .padding(.top, SettingsMetrics.xxl)
            Form { leadingHeaderStripped }
                .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // The transparent title-bar band is taller than the pane rhythm; nothing sits in it here.
        .ignoresSafeArea(edges: .top)
    }

    /// The first group carries no header: the pane title already names it. Panes still write
    /// `Section("Header") { … }`; only the first one's header is left unbuilt.
    private var leadingHeaderStripped: some View {
        Group(sections: content) { sections in
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                if index == 0 {
                    Section { section.content } footer: { section.footer }
                } else {
                    Section { section.content } header: { section.header } footer: { section.footer }
                }
            }
        }
    }
}

/// One settings line: the title paired with its control, and a caption only where the copy
/// reports something (a state, a count, an error) rather than describing the row.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var statusDot: Color? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        if let subtitle {
            VStack(alignment: .leading, spacing: SettingsMetrics.xs / 2) {
                labeled
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            labeled
        }
    }

    private var labeled: some View {
        LabeledContent {
            trailing
        } label: {
            HStack(spacing: SettingsMetrics.md) {
                Text(title)
                if let statusDot {
                    Circle().fill(statusDot).frame(width: 6, height: 6)
                }
            }
        }
    }
}

extension SettingsRow where Trailing == Text {
    /// A read-only row whose value is plain secondary text.
    init(title: String, value: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { Text(value).foregroundStyle(.secondary) }
    }
}

/// Trailing buttons in a section footer, e.g. Restore Defaults.
struct SettingsListActions<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: SettingsMetrics.lg) {
            Spacer(minLength: 0)
            content
        }
        .font(.body)
        .foregroundStyle(.primary)
        .buttonStyle(.bordered)
    }
}

// MARK: - Remote

private struct RemotePane: View {
    @ObservedObject var model: RemoteSettingsModel
    let setSiriAction: (ButtonAction) -> Void
    let restoreDefaults: () -> Void
    let setIdleTimeout: (RemoteIdleTimeout) -> Void

    var body: some View {
        SettingsPane(title: "Remote") {
            Section { RemoteHero(snapshot: model.snapshot) }
            Section {
                SettingsRow(title: "Siri Button") {
                    SiriActionPopUp(action: model.snapshot.siriAction, onSelect: setSiriAction)
                        .fixedSize()
                }
                SettingsRow(title: "Auto Disconnect") {
                    Picker("", selection: Binding(get: { model.snapshot.idleTimeout }, set: setIdleTimeout)) {
                        ForEach(RemoteIdleTimeout.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("settings.idleTimeout")
                }
            } header: {
                Text("Controls")
            } footer: {
                SettingsListActions {
                    Button("Restore Defaults", action: restoreDefaults)
                        .disabled(model.snapshot.isAtDefaults)
                        .accessibilityIdentifier("settings.restoreDefaults")
                }
            }
        }
    }
}

/// The CAD remote with hover-only function callouts, then connection and battery.
private struct RemoteHero: View {
    let snapshot: RemoteSettingsSnapshot
    @State private var hoveredControl: String?
    private var layout: RemoteSettingsLayout { RemoteSettingsLayout(generation: snapshot.generation) }

    var body: some View {
        VStack(spacing: 14) {
            ZStack(alignment: .top) {
                RemoteModelView(generation: snapshot.generation, onHover: { hoveredControl = $0 })
                    .frame(width: 336, height: RemoteModelScene.previewHeight)
                    .accessibilityLabel(snapshot.generation.displayName)
                HStack(alignment: .top, spacing: 0) {
                    callouts(layout.left, side: .left)
                    Spacer().frame(width: 112)
                    callouts(layout.right, side: .right)
                }
                .allowsHitTesting(false)
            }
            HStack(spacing: 12) {
                SettingsBatteryGauge(connected: snapshot.connected, percent: snapshot.batteryPercent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.connected ? "Connected" : "Disconnected")
                        .font(.headline)
                        .accessibilityIdentifier("settings.connection")
                    Text(batteryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, SettingsMetrics.md)
    }

    private var batteryText: String {
        guard snapshot.connected else { return "Pair the remote in Bluetooth settings" }
        guard let percent = snapshot.batteryPercent, (0...100).contains(percent) else { return "Battery unknown" }
        return "Battery \(percent)%"
    }

    private enum Side { case left, right }

    private func callouts(_ items: [RemoteSettingsLayout.Callout], side: Side) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                callout(item.key, side: side)
                    .opacity(hoveredControl == item.key ? 1 : 0)
                    .accessibilityHidden(hoveredControl != item.key)
                    .offset(y: RemoteModelScene.guideY(item.centerY) - 17)
            }
        }
        .frame(width: 112, height: RemoteModelScene.previewHeight, alignment: .topLeading)
    }

    private func callout(_ key: String, side: Side) -> some View {
        let title = RemoteSettingsGuide.title(for: key, snapshot: snapshot)
        return HStack(spacing: 6) {
            if side == .right { connector }
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                .frame(width: 90, alignment: side == .left ? .trailing : .leading)
            if side == .left { connector }
        }
        .frame(height: 34)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityIdentifier("settings.guide.\(key)")
    }

    private var connector: some View {
        Rectangle().fill(Color.primary.opacity(0.18)).frame(width: 16, height: 1)
    }
}

/// Battery-widget style ring; charging is not shown because the snapshot does not
/// provide a verified charging state. Unknown and disconnected readings stay neutral.
private struct SettingsBatteryGauge: View {
    let connected: Bool
    let percent: Int?
    private var reading: Int? {
        guard connected, let percent, (0...100).contains(percent) else { return nil }
        return percent
    }
    private var label: String {
        if let reading { return "Remote battery: \(reading)%" }
        return connected ? "Remote battery unavailable" : "Remote disconnected"
    }

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 4)
            if let reading {
                Circle().trim(from: 0, to: CGFloat(reading) / 100)
                    .stroke(reading <= 20 ? Color.red : Color.green,
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: "appletvremote.gen4.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(connected ? Color.primary : Color.secondary)
        }
        .frame(width: 36, height: 36)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier("settings.battery")
        .help(label)
    }
}

// MARK: - Buttons

private struct ButtonsPane: View {
    let snapshot: RemoteSettingsSnapshot

    var body: some View {
        SettingsPane(title: "Buttons") {
            Section {
                ForEach(RemoteSettingsGuide.buttons(for: snapshot.generation), id: \.self) { key in
                    SettingsRow(
                        title: RemoteSettingsGuide.buttonName(for: key, generation: snapshot.generation),
                        value: RemoteSettingsGuide.title(for: key, snapshot: snapshot)
                            .replacingOccurrences(of: "\n", with: " · "),
                        subtitle: key == "tv" ? "Hold: Computer Use Agent" : nil
                    )
                }
            }
        }
    }
}

// MARK: - Agent

/// The agent's choices, read from and written to the same defaults and Keychain item as the
/// agent panel, which reloads them each time it opens.
@MainActor
private final class AgentSettingsStore: ObservableObject {
    @Published var settings = AgentSettings.load() { didSet { if settings != oldValue { settings.save() } } }
    @Published private(set) var hasOpenRouterKey = AgentKeychain.openRouterKey() != nil
    let codexModels = AgentModelCatalog.codex()

    func saveOpenRouterKey(_ key: String) {
        AgentKeychain.setOpenRouterKey(key)
        hasOpenRouterKey = AgentKeychain.openRouterKey() != nil
    }
}

private struct AgentPane: View {
    let openPanel: () -> Void
    @StateObject private var store = AgentSettingsStore()
    @State private var keyDraft = ""

    var body: some View {
        SettingsPane(title: "Agent") {
            Section {
                SettingsRow(title: "Backend") {
                    Picker("", selection: $store.settings.backend) {
                        ForEach(AgentBackend.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("settings.agent.backend")
                }
                SettingsRow(title: "Model") { modelControl }
            } footer: {
                SettingsListActions {
                    Button("Open Agent Panel", action: openPanel)
                }
            }
            if store.settings.backend == .openRouter {
                Section("OpenRouter") {
                    SettingsRow(title: "API Key", subtitle: store.hasOpenRouterKey ? "Saved in Keychain" : nil) {
                        HStack(spacing: SettingsMetrics.md) {
                            SecureField("", text: $keyDraft, prompt: Text(store.hasOpenRouterKey ? "Replace key" : "sk-or-…"))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 200)
                                .onSubmit(saveKey)
                            Button("Save", action: saveKey).disabled(keyDraft.isEmpty)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var modelControl: some View {
        switch store.settings.backend {
        case .claudeCode:
            modelPicker(AgentModelCatalog.choices(AgentModelCatalog.claudeCode, keeping: store.settings.claudeModel),
                        selection: $store.settings.claudeModel)
        case .codex:
            modelPicker(AgentModelCatalog.choices(store.codexModels, keeping: store.settings.codexModel),
                        selection: $store.settings.codexModel)
        case .openRouter:
            HStack(spacing: SettingsMetrics.xs) {
                TextField("", text: $store.settings.openRouterModel, prompt: Text(AgentSettings.defaultOpenRouterModel))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Menu {
                    ForEach(AgentModelCatalog.openRouterSuggestions, id: \.self) { model in
                        Button(model) { store.settings.openRouterModel = model }
                    }
                } label: {
                    Image(systemName: "chevron.down")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Suggested models")
            }
        }
    }

    private func modelPicker(_ choices: [AgentModelChoice], selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            ForEach(choices, id: \.id) { Text($0.title).tag($0.id) }
        }
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("settings.agent.model")
    }

    private func saveKey() {
        guard !keyDraft.isEmpty else { return }
        store.saveOpenRouterKey(keyDraft)
        keyDraft = ""
    }
}

// MARK: - Microphone

private struct MicrophonePane: View {
    @ObservedObject var model: RemoteSettingsModel
    let actions: SettingsActions

    var body: some View {
        let diagnostics = model.diagnostics
        SettingsPane(title: "Microphone") {
            Section {
                SettingsRow(title: "Voice Bridge", subtitle: diagnostics.attention,
                            statusDot: diagnostics.bridgeRunning ? .green : .orange) {
                    HStack(spacing: SettingsMetrics.md) {
                        Text(diagnostics.bridgeRunning ? "Running" : "Stopped").foregroundStyle(.secondary)
                        Button(diagnostics.bridgeRunning ? "Restart" : "Start", action: actions.restartBridge)
                            .controlSize(.small)
                    }
                }
                SettingsRow(title: "Helper", value: diagnostics.helper)
                SettingsRow(title: "Output Device", value: diagnostics.report.map { $0.outputDevice ?? "Missing" } ?? "Checking…")
            }
            Section("Audio Output") {
                SettingsRow(title: "Output") {
                    Picker("", selection: Binding(get: { model.audioOutput }, set: { value in
                        model.audioOutput = value
                        actions.setAudioOutput(value)
                    })) {
                        Text("Direct HAL (Experimental)").tag("shared")
                        Text("Compatibility").tag("compatibility")
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("settings.audioOutput")
                }
                SettingsRow(title: "Audio Driver") {
                    Button(diagnostics.canInstallDriver ? "Install…" : "Reinstall…", action: actions.installAudioDriver)
                        .controlSize(.small)
                }
            }
        }
        .onAppear(perform: actions.refreshDiagnostics)
    }
}

// MARK: - Diagnostics

private struct DiagnosticsPane: View {
    let diagnostics: SettingsDiagnostics
    let actions: SettingsActions

    var body: some View {
        SettingsPane(title: "Diagnostics") {
            Section {
                if let report = diagnostics.report {
                    SettingsRow(title: "Remote", value: report.remoteAddress ?? "Not detected")
                    SettingsRow(title: "Output Device", value: report.outputDevice ?? "Missing")
                    SettingsRow(title: "Default Input", value: report.defaultInput ?? "Unknown")
                    SettingsRow(title: "Voice Sessions", value: report.voiceSessions)
                } else {
                    SettingsRow(title: "Loading diagnostics…", value: "")
                }
                SettingsRow(title: "Helper", value: diagnostics.helper)
            } footer: {
                SettingsListActions {
                    Button("Refresh", action: actions.refreshDiagnostics)
                    Button("Copy Diagnostics", action: actions.copyDiagnostics)
                }
            }
            if let attention = diagnostics.attention {
                Section("Needs Attention") {
                    Text(attention).foregroundStyle(.orange).textSelection(.enabled)
                }
            }
            if let issues = diagnostics.report?.blockingIssues, !issues.isEmpty {
                Section("Blocking Issues") {
                    ForEach(issues, id: \.self) { Text($0).textSelection(.enabled) }
                }
            }
            Section("Log File") {
                SettingsRow(title: "viberemote.log") {
                    Button("Open", action: actions.openAppLog)
                        .controlSize(.small)
                        .disabled(diagnostics.report?.appLogAvailable == false)
                }
            }
        }
        .onAppear(perform: actions.refreshDiagnostics)
    }
}

// MARK: - About

private struct AboutPane: View {
    @ObservedObject var updater: AppUpdater
    let showOnboarding: () -> Void

    private static let repository = URL(string: "https://github.com/mmmmmmarcus/VibeRemote")!

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "Development"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    var body: some View {
        SettingsPane(title: "About") {
            Section {
                VStack(spacing: SettingsMetrics.xl) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 88, height: 88)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                    VStack(spacing: SettingsMetrics.sm) {
                        Text("Vibe Remote").font(.title.weight(.bold))
                        Text(version)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.version")
                    }
                    Text("Drive AI agents from an Apple TV Siri Remote.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, SettingsMetrics.md)
            }
            Section("Software") {
                SettingsRow(title: "Software Update", subtitle: updater.updateAvailable ? "An update is available." : nil,
                            statusDot: updater.updateAvailable ? .accentColor : nil) {
                    Button(updater.updateAvailable ? "Update…" : "Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!(updater.canCheck || updater.updateAvailable))
                        .accessibilityIdentifier("settings.updates.install")
                }
                SettingsRow(title: "Getting Started") {
                    Button("Open Guide…", action: showOnboarding)
                }
            }
            Section("Links") {
                SettingsRow(title: "GitHub") {
                    Link("github.com/mmmmmmarcus/VibeRemote", destination: Self.repository)
                }
                SettingsRow(title: "Release Notes") {
                    Link("Releases", destination: Self.repository.appendingPathComponent("releases"))
                }
            }
        }
    }
}
