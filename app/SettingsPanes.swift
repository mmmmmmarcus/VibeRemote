import AppKit
import SwiftUI

/// Settings metrics and colors, matching Spotter's Settings window so both apps read as one
/// family: a 190-point sidebar of icon-tile rows and native grouped-Form panes.
enum SettingsMetrics {
    static let sidebarWidth: CGFloat = 190
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
                               restoreDefaults: restoreDefaults, setIdleTimeout: setIdleTimeout,
                               actions: actions)
                case .cursor: TextCursorPane(generation: model.snapshot.generation)
                case .dictation: DictationPane(siriAction: model.snapshot.siriAction, setSiriAction: setSiriAction)
                case .agent: AgentPane(generation: model.snapshot.generation,
                                       openPanel: actions.openAgentPanel)
                case .diagnostics: DiagnosticsPane(diagnostics: model.diagnostics, actions: actions)
                case .about: AboutPane(updater: updater, showOnboarding: actions.showOnboarding)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Panes already draw their title inside the transparent title-bar band; the content
            // column joins them so the pill below can line up with that title.
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .topTrailing) {
                SetupIssuePill(diagnostics: model.diagnostics, actions: actions)
                    .padding(.top, SettingsMetrics.xxl - 2)
                    .padding(.trailing, SettingsMetrics.xxl)
            }
            .background(SettingsVisualEffect(material: .contentBackground).ignoresSafeArea())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SettingsMetrics.xs / 2) {
                header("Remote")
                rows(SettingsTab.remoteTabs)
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

// MARK: - Setup guide

/// A Liquid Glass pill in the window's top-right corner, shown on every pane while the helper
/// or the audio driver needs the user. It names the fix and opens the step-by-step guide.
private struct SetupIssuePill: View {
    let diagnostics: SettingsDiagnostics
    let actions: SettingsActions
    @State private var showsGuide = false

    var body: some View {
        if let title = diagnostics.setupPillTitle {
            Button { showsGuide.toggle() } label: {
                HStack(spacing: SettingsMetrics.sm) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(title)
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .accessibilityIdentifier("settings.setupPill")
            .popover(isPresented: $showsGuide, arrowEdge: .bottom) {
                SetupGuideView(issues: diagnostics.setupIssues, actions: actions)
            }
        }
    }
}

/// One block per issue, helper first: approving it removes the password prompt that
/// installing the driver would otherwise raise.
private struct SetupGuideView: View {
    let issues: [SettingsDiagnostics.SetupIssue]
    let actions: SettingsActions

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.xl) {
            ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: SettingsMetrics.md) {
                    Label(SetupGuide.title(issue), systemImage: SetupGuide.symbol(issue))
                        .font(.headline)
                    Text(SetupGuide.explanation(issue))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: SettingsMetrics.xs) {
                        ForEach(Array(SetupGuide.steps(issue).enumerated()), id: \.offset) { number, step in
                            HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.sm) {
                                Text("\(number + 1).").monospacedDigit().foregroundStyle(.secondary)
                                Text(step).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if let action = SetupGuide.guideActionTitle(issue) {
                        Button(action) { SetupGuide.perform(issue, actions: actions) }
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
        }
        .padding(SettingsMetrics.xxl - 4)
        .frame(width: 320)
    }
}

/// Copy and actions for each setup issue, shared by the Status rows and the guide.
enum SetupGuide {
    typealias Issue = SettingsDiagnostics.SetupIssue

    static func statusText(_ issue: Issue) -> String {
        switch issue {
        case .helperNotSetUp: return "Not set up"
        case .helperAwaitingApproval: return "Waiting for approval"
        case .audioDriverMissing: return "Not installed"
        }
    }

    /// The short button on the Status row.
    static func actionTitle(_ issue: Issue) -> String? {
        switch issue {
        case .helperNotSetUp: return "Set Up…"
        case .helperAwaitingApproval: return "Open Settings…"
        case .audioDriverMissing(let installable): return installable ? "Install…" : nil
        }
    }

    static func guideActionTitle(_ issue: Issue) -> String? {
        switch issue {
        case .helperNotSetUp: return "Set Up Helper"
        case .helperAwaitingApproval: return "Open Login Items"
        case .audioDriverMissing(let installable): return installable ? "Install Audio Driver" : nil
        }
    }

    static func title(_ issue: Issue) -> String {
        switch issue {
        case .helperNotSetUp: return "Set Up the Helper"
        case .helperAwaitingApproval: return "Approve the Helper"
        case .audioDriverMissing: return "Install the Audio Driver"
        }
    }

    static func symbol(_ issue: Issue) -> String {
        issue.isHelper ? "lock.shield" : "speaker.badge.exclamationmark"
    }

    static func explanation(_ issue: Issue) -> String {
        switch issue {
        case .helperNotSetUp:
            return "The helper captures the remote's microphone over Bluetooth. Approve it once and the voice bridge starts without asking for your password."
        case .helperAwaitingApproval:
            return "The helper is registered, but macOS is still waiting for you to allow it."
        case .audioDriverMissing(let installable):
            return installable
                ? "Your voice plays into the VibeRemote audio device, which Mac apps then use as a microphone. That device isn't installed yet."
                : "Your voice plays into the VibeRemote audio device, which Mac apps then use as a microphone. This build doesn't include the driver."
        }
    }

    static func steps(_ issue: Issue) -> [String] {
        switch issue {
        case .helperNotSetUp:
            return ["Make sure VibeRemote is running from the Applications folder.",
                    "Click Set Up Helper.",
                    "In Login Items & Extensions, turn on VibeRemote under Allow in the Background.",
                    "Come back to Settings. This alert clears by itself."]
        case .helperAwaitingApproval:
            return ["Click Open Login Items.",
                    "Under Allow in the Background, turn on VibeRemote.",
                    "Enter your password if macOS asks, then come back to Settings."]
        case .audioDriverMissing(true):
            return ["Click Install Audio Driver.",
                    "Enter your password if asked. An approved helper installs it without one.",
                    "Sound pauses for a moment while macOS restarts its audio service."]
        case .audioDriverMissing(false):
            return ["In the app folder, run ./build_audio_driver.sh.",
                    "Reinstall VibeRemote with ./install.sh.",
                    "Open Settings again and click Install Audio Driver."]
        }
    }

    @MainActor
    static func perform(_ issue: Issue, actions: SettingsActions) {
        switch issue {
        case .helperNotSetUp, .helperAwaitingApproval: actions.setUpHelper()
        case .audioDriverMissing(let installable): if installable { actions.installAudioDriver() }
        }
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

/// Everything about the paired remote on one pane: the CAD hero with a glass pill beside
/// every button (click one to choose what that button does), Auto Disconnect, and one Status
/// section for the link, battery and microphone bridge. The Siri pop-up row and the read-only
/// Buttons list were replaced by the pills (2026-11-08).
private struct RemotePane: View {
    @ObservedObject var model: RemoteSettingsModel
    let setSiriAction: (ButtonAction) -> Void
    let restoreDefaults: () -> Void
    let setIdleTimeout: (RemoteIdleTimeout) -> Void
    let actions: SettingsActions

    var body: some View {
        SettingsPane(title: "Remote") {
            Section {
                RemoteHero(snapshot: model.snapshot, setSiriAction: setSiriAction,
                           setButtonAction: actions.setButtonAction)
            } footer: {
                Text("Click a label to choose what its button does. Siri takes the held keys dictation apps listen for.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            Section {
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
            Section("Status") { status }
        }
        // The bridge and setup rows read the same async snapshot the Diagnostics pane does.
        .onAppear(perform: actions.refreshDiagnostics)
    }

    /// Connection, battery and the voice bridge always show. Helper and Audio Driver appear
    /// only while they need the user; when both are fine there is nothing to act on, and the
    /// Fix pill at the top of the window offers the step-by-step guide for either.
    @ViewBuilder private var status: some View {
        let snapshot = model.snapshot
        let diagnostics = model.diagnostics
        SettingsRow(title: "Bluetooth",
                    subtitle: snapshot.connected ? snapshot.remoteName : "Pair the remote in Bluetooth settings",
                    statusDot: snapshot.connected ? .green : .gray) {
            Text(snapshot.connected ? "Connected" : "Disconnected")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.connection")
        }
        if snapshot.connected {
            SettingsRow(title: "Battery") {
                HStack(spacing: SettingsMetrics.md) {
                    Text(batteryText(snapshot)).foregroundStyle(.secondary)
                    SettingsBatteryGauge(connected: snapshot.connected, percent: snapshot.batteryPercent)
                }
            }
        }
        SettingsRow(title: "Voice Bridge", subtitle: diagnostics.attention,
                    statusDot: diagnostics.bridgeRunning ? .green : .orange) {
            HStack(spacing: SettingsMetrics.md) {
                Text(diagnostics.bridgeRunning ? "Running" : "Stopped").foregroundStyle(.secondary)
                Button(diagnostics.bridgeRunning ? "Restart" : "Start", action: actions.restartBridge)
                    .controlSize(.small)
            }
        }
        ForEach(diagnostics.setupIssues) { issue in
            SettingsRow(title: issue.isHelper ? "Helper" : "Audio Driver",
                        statusDot: .red) {
                HStack(spacing: SettingsMetrics.md) {
                    Text(SetupGuide.statusText(issue)).foregroundStyle(.secondary)
                    if let title = SetupGuide.actionTitle(issue) {
                        Button(title) { SetupGuide.perform(issue, actions: actions) }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func batteryText(_ snapshot: RemoteSettingsSnapshot) -> String {
        guard let percent = snapshot.batteryPercent, (0...100).contains(percent) else { return "Unknown" }
        return "\(percent)%"
    }
}

/// The CAD remote with a glass pill beside each control: left-column controls get a pill on
/// the left, right-column ones on the right, each with an arrow toward its button. Hovering
/// a pill lights its CAD button and the reverse; clicking an editable pill opens a menu of
/// that button's choices. Pills fade while the remote is dragged, since they point at the
/// resting pose.
private struct RemoteHero: View {
    let snapshot: RemoteSettingsSnapshot
    let setSiriAction: (ButtonAction) -> Void
    let setButtonAction: (String, ButtonAction) -> Void
    @State private var modelHover: String?
    @State private var pillHover: String?
    @State private var dragging = false
    private var layout: RemoteSettingsLayout { RemoteSettingsLayout(generation: snapshot.generation) }

    static let pillHeight: CGFloat = 26
    static let pillPitch: CGFloat = 30

    var body: some View {
        ZStack(alignment: .topLeading) {
            RemoteModelView(generation: snapshot.generation, highlighted: pillHover,
                            onHover: { modelHover = $0 }, onDragging: { dragging = $0 })
                .frame(width: RemoteModelScene.previewWidth, height: RemoteModelScene.previewHeight)
                .accessibilityLabel(snapshot.generation.displayName)
            column(layout.left, side: .left)
            column(layout.right, side: .right)
                .offset(x: RemoteModelScene.calloutColumnWidth + RemoteModelScene.previewBodyGutter)
        }
        .frame(width: RemoteModelScene.previewWidth, height: RemoteModelScene.previewHeight)
        .frame(maxWidth: .infinity)
        .padding(.vertical, SettingsMetrics.md)
    }

    private func column(_ items: [RemoteSettingsLayout.Callout], side: PillSide) -> some View {
        let targets = items.map { RemoteModelScene.guideY($0.centerY) }
        let centers = RemotePillLayout.centers(targets, pitch: Self.pillPitch, height: RemoteModelScene.previewHeight)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                pill(item.key, side: side, tipY: targets[index] - centers[index] + Self.pillHeight / 2)
                    .frame(width: RemoteModelScene.calloutColumnWidth,
                           alignment: side == .left ? .trailing : .leading)
                    .offset(y: centers[index] - Self.pillHeight / 2)
            }
        }
        .frame(width: RemoteModelScene.calloutColumnWidth, height: RemoteModelScene.previewHeight,
               alignment: .topLeading)
        .opacity(dragging ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: dragging)
        .allowsHitTesting(!dragging)
    }

    private func pill(_ key: String, side: PillSide, tipY: CGFloat) -> some View {
        let guide = RemoteSettingsGuide.title(for: key, snapshot: snapshot)
        // One line per pill; a second guide line (the glass surface's swipe) stays in the label.
        let title = String(guide.split(separator: "\n").first ?? Substring(guide))
        let options = RemoteSettingsGuide.pillOptions(for: key, snapshot: snapshot)
        return ButtonPill(title: title, side: side, tipY: tipY, editable: options != nil,
                          highlighted: pillHover == key || modelHover == key,
                          onHover: { inside in
                              if inside { pillHover = key } else if pillHover == key { pillHover = nil }
                          },
                          onTap: { presentMenu(for: key) })
            .accessibilityLabel("\(RemoteSettingsGuide.buttonName(for: key, generation: snapshot.generation)): \(guide.replacingOccurrences(of: "\n", with: ", "))")
            .accessibilityIdentifier("settings.pill.\(key)")
    }

    private func presentMenu(for key: String) {
        guard let options = RemoteSettingsGuide.pillOptions(for: key, snapshot: snapshot) else { return }
        let defaultChoice = key == "siri"
            ? remoteButtonDescriptors.first { $0.key == "siri" }?.defaultAction
            : options.choices.first
        ButtonActionMenu.present(choices: options.choices, current: options.current, defaultChoice: defaultChoice) { action in
            if key == "siri" { setSiriAction(action) } else { setButtonAction(key, action) }
        }
    }
}

enum PillSide { case left, right }

/// A one-line glass capsule with an arrow on the side facing the remote. `tipY` is where the
/// arrow points, in the pill's own coordinates; it differs from the middle when the pill had
/// to move off its button's row to clear a neighbour.
private struct ButtonPill: View {
    let title: String
    let side: PillSide
    let tipY: CGFloat
    let editable: Bool
    let highlighted: Bool
    let onHover: (Bool) -> Void
    let onTap: () -> Void

    static let arrowLength: CGFloat = 9

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(editable ? Color.primary : Color.secondary)
                if editable {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 11)
            .frame(height: RemoteHero.pillHeight)
            .padding(side == .left ? .trailing : .leading, Self.arrowLength)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(PillShape(side: side, tipY: tipY))
            .glassEffect(highlighted ? .regular.tint(Color.accentColor.opacity(0.35)).interactive(editable)
                                     : .regular.interactive(editable),
                         in: PillShape(side: side, tipY: tipY))
        }
        .buttonStyle(.plain)
        // Fixed-role pills stay enabled so hover still lights their button; tapping does nothing.
        .onHover(perform: onHover)
        .help(editable ? "Choose what this button does" : "This button's role is fixed")
    }
}

/// A capsule plus a triangular arrow on its inner side whose tip sits at `tipY`, clamped to
/// the pill's height; the arrow's base stays on the straight part of the capsule.
private struct PillShape: Shape {
    let side: PillSide
    let tipY: CGFloat

    func path(in rect: CGRect) -> Path {
        let length = ButtonPill.arrowLength
        let body = side == .left
            ? CGRect(x: rect.minX, y: rect.minY, width: rect.width - length, height: rect.height)
            : CGRect(x: rect.minX + length, y: rect.minY, width: rect.width - length, height: rect.height)
        let tip = min(max(tipY, rect.minY + 2), rect.maxY - 2)
        let base = min(max(tip, rect.midY - 4), rect.midY + 4)
        var arrow = Path()
        if side == .left {
            arrow.move(to: CGPoint(x: body.maxX - body.height / 2, y: base - 6))
            arrow.addLine(to: CGPoint(x: rect.maxX, y: tip))
            arrow.addLine(to: CGPoint(x: body.maxX - body.height / 2, y: base + 6))
        } else {
            arrow.move(to: CGPoint(x: body.minX + body.height / 2, y: base - 6))
            arrow.addLine(to: CGPoint(x: rect.minX, y: tip))
            arrow.addLine(to: CGPoint(x: body.minX + body.height / 2, y: base + 6))
        }
        arrow.closeSubpath()
        return Path(roundedRect: body, cornerRadius: body.height / 2, style: .continuous).union(arrow)
    }
}

/// A native drop-down of a button's choices, popped up at the pointer with the current one
/// checked and under the pointer, like an NSPopUpButton. Each item explains itself in a tooltip.
@MainActor
enum ButtonActionMenu {
    private final class Target: NSObject {
        let onSelect: (ButtonAction) -> Void
        init(onSelect: @escaping (ButtonAction) -> Void) { self.onSelect = onSelect }
        @objc func choose(_ item: NSMenuItem) {
            guard let raw = item.representedObject as? String, let action = ButtonAction(rawValue: raw) else { return }
            onSelect(action)
        }
    }

    static func makeMenu(choices: [ButtonAction], current: ButtonAction, defaultChoice: ButtonAction?,
                         target: AnyObject?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for action in choices {
            let title = action == defaultChoice ? "\(action.settingsTitle) (Default)" : action.settingsTitle
            let item = NSMenuItem(title: title, action: #selector(Target.choose(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = action.rawValue
            item.state = action == current ? .on : .off
            item.toolTip = action.actionDescription
            menu.addItem(item)
        }
        return menu
    }

    static func present(choices: [ButtonAction], current: ButtonAction, defaultChoice: ButtonAction?,
                        onSelect: @escaping (ButtonAction) -> Void) {
        let target = Target(onSelect: onSelect)
        let menu = makeMenu(choices: choices, current: current, defaultChoice: defaultChoice, target: target)
        // popUp tracks synchronously, so `target` outlives the selection.
        menu.popUp(positioning: menu.items.first { $0.state == .on }, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(target) {}
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
            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 3)
            if let reading {
                Circle().trim(from: 0, to: CGFloat(reading) / 100)
                    .stroke(reading <= 20 ? Color.red : Color.green,
                            style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: "appletvremote.gen4.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(connected ? Color.primary : Color.secondary)
        }
        .frame(width: 22, height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier("settings.battery")
        .help(label)
    }
}

// MARK: - Computer Use

/// Computer Use's choices, read from and written to the same defaults and Keychain
/// item as the Computer Use callout, which reloads them each time it opens.
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

/// System Settings shows a gesture as the abstract input on the left and what it produces
/// on the right; Computer Use is harder to picture than a button, so it gets the same
/// treatment. The remote is the technical drawing the first-run guide uses, which keeps this
/// pane and Text Cursor in one visual family.
struct AgentDemo: View {
    let generation: RemoteGeneration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let instruction = "Open the deploy log"

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            // Reduce Motion freezes the loop where the story is already told: typed out,
            // acted on, result showing.
            let progress = reduceMotion ? 0.75 : Self.progress(at: timeline.date)
            HStack(spacing: SettingsMetrics.md) {
                RemoteBlueprint(generation: generation, highlight: .newLine,
                                symbol: "cursorarrow.motionlines", showsGrid: false)
                    .frame(width: 116)
                Canvas { context, size in Self.drawScreen(in: context, size: size, progress: progress) }
                    .frame(width: 196)
            }
            .frame(maxWidth: .infinity)
            .background { Canvas { context, size in BlueprintGrid.draw(in: context, size: size) } }
        }
    }

    /// One pass of the loop: hold, dictate, the agent acts, the result rests long enough
    /// to read, then it starts over.
    static func progress(at date: Date) -> Double {
        let period = 5.6
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
    }

    /// Phase ramps, each 0...1 across its own slice of the loop.
    static func phase(_ progress: Double, from: Double, to: Double) -> Double {
        min(max((progress - from) / (to - from), 0), 1)
    }

    private static func drawScreen(in context: GraphicsContext, size: CGSize, progress: Double) {
        let ink = Color.primary.opacity(0.45)
        let faint = Color.primary.opacity(0.18)
        let accent = Color.accentColor
        let typed = phase(progress, from: 0.12, to: 0.40)
        let travel = phase(progress, from: 0.44, to: 0.62)
        let acted = phase(progress, from: 0.62, to: 0.68)

        // The Mac, drawn as a plain screen outline so nothing competes with the action.
        let screen = CGRect(x: 0.5, y: 6.5, width: size.width - 1, height: size.height - 13)
        context.stroke(Path(roundedRect: screen, cornerRadius: 6), with: .color(ink), lineWidth: 0.9)
        var menuBar = Path()
        menuBar.move(to: CGPoint(x: screen.minX, y: screen.minY + 9))
        menuBar.addLine(to: CGPoint(x: screen.maxX, y: screen.minY + 9))
        context.stroke(menuBar, with: .color(faint), lineWidth: 0.7)
        for index in 0..<3 {
            let dot = CGRect(x: screen.minX + 6 + CGFloat(index) * 5, y: screen.minY + 3, width: 2.4, height: 2.4)
            context.fill(Path(ellipseIn: dot), with: .color(faint))
        }

        // The front window the agent works in.
        let window = CGRect(x: screen.minX + 12, y: screen.minY + 17, width: screen.width - 24, height: 40)
        context.stroke(Path(roundedRect: window, cornerRadius: 4), with: .color(ink), lineWidth: 0.8)
        var divider = Path()
        divider.move(to: CGPoint(x: window.minX, y: window.minY + 9))
        divider.addLine(to: CGPoint(x: window.maxX, y: window.minY + 9))
        context.stroke(divider, with: .color(faint), lineWidth: 0.7)
        for (index, width) in [0.62, 0.44].enumerated() {
            var line = Path()
            let y = window.minY + 17 + CGFloat(index) * 6
            line.move(to: CGPoint(x: window.minX + 7, y: y))
            line.addLine(to: CGPoint(x: window.minX + 7 + window.width * width, y: y))
            context.stroke(line, with: .color(faint), lineWidth: 1.4)
        }

        // What the instruction asks for: a control that the agent presses.
        let target = CGRect(x: window.maxX - 44, y: window.maxY - 13, width: 34, height: 9)
        let targetShape = Path(roundedRect: target, cornerRadius: 2.5)
        if acted > 0 {
            context.fill(targetShape, with: .color(accent.opacity(0.18 + 0.82 * acted)))
        }
        context.stroke(targetShape, with: .color(acted > 0 ? accent : ink), lineWidth: 0.8)

        // The agent panel, with the instruction typing into it.
        let panel = CGRect(x: screen.minX + 12, y: screen.maxY - 20, width: screen.width - 24, height: 15)
        let panelShape = Path(roundedRect: panel, cornerRadius: 4)
        context.fill(panelShape, with: .color(accent.opacity(0.10)))
        context.stroke(panelShape, with: .color(accent.opacity(0.75)), lineWidth: 0.9)
        let font = NSFont.monospacedSystemFont(ofSize: 7, weight: .regular)
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        let shown = Int((typed * Double(instruction.count)).rounded())
        let text = String(instruction.prefix(shown))
        let textOrigin = CGPoint(x: panel.minX + 6, y: panel.midY)
        if !text.isEmpty {
            context.draw(Text(text).font(Font(font)).foregroundStyle(.primary),
                         at: textOrigin, anchor: .leading)
        }
        if typed < 1 {
            let caret = CGRect(x: textOrigin.x + CGFloat(shown) * advance, y: panel.midY - 4, width: 1.2, height: 8)
            context.fill(Path(caret), with: .color(accent))
        }

        // The pointer only exists while it is doing something: it leaves the panel, lands
        // on the control, and disappears with the result. It starts from the panel's trailing
        // end so it never crosses the instruction it is carrying out.
        guard travel > 0, progress < 0.86 else { return }
        let start = CGPoint(x: panel.maxX - 12, y: panel.minY - 2)
        let end = CGPoint(x: target.midX - 3, y: target.midY)
        let eased = 0.5 - cos(travel * .pi) / 2
        let tip = CGPoint(x: start.x + (end.x - start.x) * eased, y: start.y + (end.y - start.y) * eased)
        var arrow = Path()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: tip.x + 1.2, y: tip.y + 8.4))
        arrow.addLine(to: CGPoint(x: tip.x + 3.4, y: tip.y + 5.6))
        arrow.addLine(to: CGPoint(x: tip.x + 6.4, y: tip.y + 5.4))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(Color(nsColor: .windowBackgroundColor)))
        context.stroke(arrow, with: .color(.primary), lineWidth: 0.9)
    }
}

private struct AgentPane: View {
    let generation: RemoteGeneration
    let openPanel: () -> Void
    @StateObject private var store = AgentSettingsStore()
    @State private var keyDraft = ""

    var body: some View {
        SettingsPane(title: "Computer Use") {
            Section {
                AgentDemo(generation: generation)
                    .frame(height: 104)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SettingsMetrics.md)
                    .accessibilityHidden(true)
            } footer: {
                Text("Hold TV for half a second — or pick Computer Use in the menu bar. A field pops up from VibeRemote's Dock icon; type or dictate what you want done and send it. The icon turns green while the agent works in the app that was in front.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

// MARK: - Text cursor

/// Settings doubles as the manual, so the one gesture that is not a button gets a pane of
/// its own. The looping demo is the same one the first-run guide draws; it is the whole
/// point of the pane, and it pauses itself under Reduce Motion.
private struct TextCursorPane: View {
    let generation: RemoteGeneration

    /// The 1st-gen remote has no Power key, and its flat glass is a touch surface rather
    /// than a clickpad, so every instruction below names the part the user is holding.
    private var glass: Bool { generation == .glassTouchSurface }
    private var surface: String { glass ? "touch surface" : "clickpad" }

    var body: some View {
        SettingsPane(title: "Text Cursor") {
            Section {
                CursorDemo(generation: generation)
                    .frame(height: 96)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SettingsMetrics.md)
                    .accessibilityHidden(true)
            }
            Section {
                step("hand.point.up.left", "Start",
                     "Rest a finger on the \(surface) and slide. A marker appears at the text cursor straight away, and takes over once you have moved far enough for it to be deliberate.")
                step("arrow.left.and.right", "Move",
                     "Slide sideways to move along the line, up or down to change line. Lift and start again as often as you like — the marker stays where you left it.")
                step("checkmark.circle", "Confirm",
                     glass ? "Click the touch surface, or stop moving for three seconds."
                           : "Click the center of the clickpad, or stop moving for three seconds.")
                step("xmark.circle", "Cancel",
                     glass ? "Press Siri, or Return on the keyboard. Nothing is changed."
                           : "Press Siri or Power, or Return on the keyboard. Nothing is changed.")
            } header: {
                Text("How to Use")
            } footer: {
                Text("The marker only appears where the text cursor's position can be read through accessibility, which rules out some apps. Nothing is ever typed, deleted or copied: only the insertion point moves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: SettingsMetrics.lg) {
            RoundedRectangle(cornerRadius: SettingsMetrics.tileRadius, style: .continuous)
                .fill(SettingsMetrics.controlSurface)
                .overlay {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(width: SettingsMetrics.rowIcon, height: SettingsMetrics.rowIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SettingsMetrics.xs / 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
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
