import AppKit
import SwiftUI

/// Completion is recorded only after Finish; closing the guide never changes a mapping.
enum OnboardingState {
    static let completionKey = "onboardingCompletedVersion"
    static func needsPresentation(defaults: UserDefaults = .standard) -> Bool {
        if defaults.integer(forKey: completionKey) >= 1 { return false }
        // Existing installations already have a chosen mapping or bridge configuration.
        // Migrate them quietly; the guide remains available from Settings.
        if defaults.object(forKey: "siriButtonAction") != nil || defaults.object(forKey: "microphoneBridgeEngine") != nil {
            defaults.set(1, forKey: completionKey)
            return false
        }
        return true
    }
    static func complete(action: ButtonAction, defaults: UserDefaults = .standard) -> Bool {
        guard action.isAssignableToSiriButton else { return false }
        defaults.set(action.rawValue, forKey: "siriButtonAction")
        defaults.set(1, forKey: completionKey)
        return true
    }
}

struct OnboardingAccess: Equatable {
    var bluetooth = false
    var input = false
    var accessibility = false
    /// The privileged helper removes later password prompts; `helperNeedsApproval` picks
    /// between registering it and sending the user to Login Items.
    var helper = false
    var helperNeedsApproval = false
    var audio = false
    var audioInstallable = false
}

/// Setup callbacks owned by the menu-bar manager, so the guide never creates its own
/// HID, Bluetooth, helper or audio managers.
struct OnboardingActions {
    var requestBluetooth: () -> Void = {}
    var requestInput: () -> Void = {}
    var requestAccessibility: () -> Void = {}
    var setUpHelper: () -> Void = {}
    var installAudio: () -> Void = {}
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step = 0
    @Published var action: ButtonAction
    @Published var snapshot: RemoteSettingsSnapshot
    @Published var access: OnboardingAccess
    init(snapshot: RemoteSettingsSnapshot, access: OnboardingAccess) {
        self.snapshot = snapshot; self.action = snapshot.siriAction; self.access = access
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let size = NSSize(width: 280, height: 350)
    let model: OnboardingModel
    init(snapshot: RemoteSettingsSnapshot, access: OnboardingAccess,
         actions: OnboardingActions, finish: @escaping (ButtonAction) -> Void) {
        model = OnboardingModel(snapshot: snapshot, access: access)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        // The title stays for the Window menu and accessibility but is never drawn.
        window.title = "VibeRemote"
        window.titleVisibility = .hidden
        window.identifier = .init("VibeRemote.Onboarding")
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: OnboardingView(
            model: model, actions: actions, finish: { [weak self] action in
                guard OnboardingState.complete(action: action) else { return }
                finish(action)
                self?.close()
            }))
        window.setContentSize(Self.size)
        window.center()
    }
    required init?(coder: NSCoder) { nil }
    func show() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil); window?.deminiaturize(nil)
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    func update(snapshot: RemoteSettingsSnapshot, access: OnboardingAccess) {
        model.snapshot = snapshot; model.access = access
    }
    /// Returns to the first page and drops the unsaved Siri choice; nothing is saved until Finish.
    func restart() {
        model.step = 0; model.action = model.snapshot.siriAction
    }
    func windowWillClose(_ notification: Notification) {
        restoreAccessoryPolicy(closing: window)
    }
}

@MainActor
func restoreAccessoryPolicy(closing window: NSWindow?) {
    let setupIDs = ["VibeRemote.Settings", "VibeRemote.Onboarding"]
    let otherWindow = NSApp.windows.contains {
        $0 !== window && ($0.isVisible || $0.isMiniaturized) && setupIDs.contains($0.identifier?.rawValue ?? "")
    }
    // Computer Use's callout points at the Dock icon and its tile shows the agent working.
    if !otherWindow && !DockPresence.computerUseHoldsDock { NSApp.setActivationPolicy(.accessory) }
}

/// One guide for both remote families; only the drawing and the button names differ.
enum OnboardingPage: CaseIterable, Equatable {
    case welcome
    case setup
    case siri
    case deleteWord
    case newLine
    case arrowKeys
    case advancedMenu
    case cursor

    static let all = allCases
}

@MainActor
struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let actions: OnboardingActions
    let finish: (ButtonAction) -> Void

    private var pages: [OnboardingPage] { OnboardingPage.all }
    private var index: Int { min(max(model.step, 0), pages.count - 1) }
    private var page: OnboardingPage { pages[index] }
    private var glass: Bool { model.snapshot.generation == .glassTouchSurface }

    private var title: String {
        switch page {
        case .welcome: return "VibeRemote"
        case .setup: return "Connect your remote."
        case .siri: return "Make Siri yours."
        case .deleteWord: return "Delete a word."
        case .newLine: return "Start a new line."
        case .arrowKeys: return "Use the arrow keys."
        case .advancedMenu: return "Open Advanced Menu."
        case .cursor: return "Place the cursor."
        }
    }

    private var detail: String? {
        switch page {
        case .welcome: return "Your Siri Remote, tuned for talking to AI agents."
        case .setup: return nil
        case .siri: return "Hold Siri to dictate. Choose the key your dictation app listens for."
        case .deleteWord:
            return "Press \(glass ? "Menu" : "Back") to delete one word. Keep holding to delete more."
        case .newLine:
            return "Press TV to add a new line without sending your message."
        case .arrowKeys:
            return glass ? "Click the edges of the touch surface to press the arrow keys."
                : "Press the edges of the clickpad to press the arrow keys."
        case .advancedMenu:
            return "Press \(glass ? "Play/Pause" : "Mute") for extra actions, like stopping a task or clearing your input."
        case .cursor:
            return glass ? "Slide across the touch surface to move the text cursor, then press to confirm."
                : "Slide around the clickpad to move the text cursor, then press the center to confirm."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            illustration
                .frame(height: page == .setup ? 96 : 146)
                .padding(.top, page == .setup ? 22 : 6)
                .accessibilityHidden(true)
            ScrollView {
                VStack(spacing: 8) {
                    Text(title).font(.system(size: 17, weight: .semibold))
                    if let detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    }
                    controls
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 22).padding(.top, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .frame(width: OnboardingWindowController.size.width, height: OnboardingWindowController.size.height)
        .ignoresSafeArea(edges: .top)
    }

    @ViewBuilder private var illustration: some View {
        let generation = model.snapshot.generation
        switch page {
        case .welcome: RemoteBlueprint(generation: generation, showsDimension: true)
        case .setup: ConnectionBlueprint(generation: generation, connected: model.snapshot.connected)
        case .siri: RemoteBlueprint(generation: generation, highlight: .siri, symbol: "mic")
        case .deleteWord: RemoteBlueprint(generation: generation, highlight: .deleteWord, symbol: "delete.left")
        case .newLine: RemoteBlueprint(generation: generation, highlight: .newLine, symbol: "return")
        case .arrowKeys: RemoteBlueprint(generation: generation, highlight: .arrows, symbol: "arrow.up.and.down.and.arrow.left.and.right")
        case .advancedMenu: RemoteBlueprint(generation: generation, highlight: .advancedMenu, symbol: "ellipsis")
        case .cursor: CursorDemo(generation: generation)
        }
    }

    @ViewBuilder private var controls: some View {
        switch page {
        case .welcome:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 3), spacing: 10) {
                feature("mic", "Dictate")
                feature("delete.left", "Delete word")
                feature("return", "New line")
                feature("arrow.up.and.down.and.arrow.left.and.right", "Arrow keys")
                feature("ellipsis.circle", "Advanced")
                feature("character.cursor.ibeam", "Cursor")
            }
            .padding(.top, 4)
        case .setup:
            VStack(spacing: 2) {
                setupRow("Siri Remote", ready: model.snapshot.connected, actionTitle: "Pair") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
                }
                setupRow("Bluetooth", ready: model.access.bluetooth, actionTitle: "Allow", action: actions.requestBluetooth)
                setupRow("Input Monitoring", ready: model.access.input, actionTitle: "Allow", action: actions.requestInput)
                setupRow("Accessibility", ready: model.access.accessibility, actionTitle: "Allow", action: actions.requestAccessibility)
                setupRow("Voice Helper", ready: model.access.helper,
                         actionTitle: model.access.helperNeedsApproval ? "Approve" : "Set Up", action: actions.setUpHelper)
                setupRow("Audio Device", ready: model.access.audio,
                         actionTitle: model.access.audioInstallable ? "Install" : nil, action: actions.installAudio)
            }
        case .siri:
            SiriActionPopUp(action: model.action, onSelect: { model.action = $0 })
                .frame(width: 190, height: 32)
                .padding(.top, 2)
            Text(model.action.requiresHold ? "Siri holds this key until you let go." : "Siri performs this action.")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        default:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            Button("Back") { model.step = max(0, index - 1) }
                .buttonStyle(.glass)
                .opacity(index == 0 ? 0 : 1)
                .disabled(index == 0)
                .accessibilityIdentifier("onboarding.back")
            Spacer(minLength: 6)
            HStack(spacing: 5) {
                ForEach(pages.indices, id: \.self) { item in
                    Circle()
                        .fill(item == index ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 5, height: 5)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Page \(index + 1) of \(pages.count)")
            Spacer(minLength: 6)
            Button(page == pages.last ? "Get Started" : "Continue") {
                if page == pages.last { finish(model.action) } else { model.step = index + 1 }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("onboarding.continue")
        }
        .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 14)
    }

    private func feature(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 14, weight: .regular)).foregroundStyle(Color.accentColor)
                .frame(height: 16)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func setupRow(_ title: String, ready: Bool, actionTitle: String?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12))
            Spacer(minLength: 8)
            if ready {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Ready")
            } else if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass).controlSize(.small)
                    .accessibilityLabel("\(actionTitle) \(title)")
            } else {
                Text("Missing").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 216, height: 24)
    }
}

// MARK: - Technical drawings

/// What a drawing calls out. Each maps to the physical control that performs the job on the
/// drawn remote family, matching `RemoteButtonMapping`.
enum BlueprintHighlight: Equatable {
    case none, siri, deleteWord, newLine, arrows, advancedMenu, touchSurface
    /// Aluminum Play/Pause's default; the glass remote has no default Computer Use button.
    case computerUse
}

/// Front-view geometry in millimetres. Proportions follow the published remote dimensions;
/// control positions are schematic.
private struct RemoteGeometry {
    let size: CGSize
    let corner: CGFloat
    let circles: [String: (center: CGPoint, radius: CGFloat)]
    let volume: CGRect
    let touch: CGRect?          // 1st-gen glass touch surface
    let ring: (center: CGPoint, outer: CGFloat, inner: CGFloat)?  // 2nd/3rd-gen clickpad
    let sideSiri: CGRect?

    static func of(_ generation: RemoteGeneration) -> RemoteGeometry {
        if generation == .glassTouchSurface {
            return RemoteGeometry(
                size: CGSize(width: 38, height: 124), corner: 5,
                circles: ["menu": (CGPoint(x: 10.5, y: 57), 5), "tv": (CGPoint(x: 27.5, y: 57), 5),
                          "siri": (CGPoint(x: 10.5, y: 72), 5), "playPause": (CGPoint(x: 10.5, y: 87), 5)],
                volume: CGRect(x: 22.5, y: 66, width: 10, height: 27),
                touch: CGRect(x: 0, y: 0, width: 38, height: 46), ring: nil, sideSiri: nil)
        }
        return RemoteGeometry(
            size: CGSize(width: 35.5, height: 136), corner: 7,
            circles: ["power": (CGPoint(x: 28.5, y: 7.5), 2.5),
                      "back": (CGPoint(x: 9.25, y: 59), 5), "tv": (CGPoint(x: 26.25, y: 59), 5),
                      "playPause": (CGPoint(x: 9.25, y: 73), 5), "mute": (CGPoint(x: 9.25, y: 87), 5)],
            volume: CGRect(x: 21.25, y: 66.5, width: 10, height: 27),
            touch: nil, ring: (CGPoint(x: 17.75, y: 33), 14, 6),
            sideSiri: CGRect(x: 35.5, y: 24, width: 1.4, height: 14))
    }

    /// Anchor of the called-out control, in millimetres.
    func anchor(for highlight: BlueprintHighlight) -> CGPoint? {
        let glass = touch != nil
        switch highlight {
        case .none: return nil
        case .siri: return glass ? circles["siri"]?.center : sideSiri.map { CGPoint(x: $0.maxX, y: $0.midY) }
        case .deleteWord: return circles[glass ? "menu" : "back"]?.center
        case .newLine: return circles["tv"]?.center
        case .advancedMenu: return circles[glass ? "playPause" : "mute"]?.center
        case .computerUse: return glass ? nil : circles["playPause"]?.center
        case .arrows: return glass ? CGPoint(x: 34, y: 23) : ring.map { CGPoint(x: $0.center.x + $0.outer - 3, y: $0.center.y) }
        case .touchSurface: return glass ? CGPoint(x: 30, y: 23) : ring.map { CGPoint(x: $0.center.x + 10, y: $0.center.y) }
        }
    }
}

/// Draws a remote front view in local millimetres onto a context already scaled to mm.
private struct RemoteDrawing {
    let geometry: RemoteGeometry
    let highlight: BlueprintHighlight
    let touchProgress: Double?

    func draw(in context: GraphicsContext, scale: CGFloat) {
        let ink = Color.primary.opacity(0.78), fine = Color.primary.opacity(0.42)
        let accent = Color.accentColor, wash = Color.accentColor.opacity(0.16)
        let line = 1 / scale, hair = 0.6 / scale
        let g = geometry
        let body = Path(roundedRect: CGRect(origin: .zero, size: g.size), cornerRadius: g.corner)

        func circle(_ key: String) -> Path? {
            g.circles[key].map { Path(ellipseIn: CGRect(x: $0.center.x - $0.radius, y: $0.center.y - $0.radius,
                                                       width: $0.radius * 2, height: $0.radius * 2)) }
        }
        func emphasise(_ path: Path) {
            context.fill(path, with: .color(wash))
            context.stroke(path, with: .color(accent), lineWidth: 1.4 / scale)
        }

        if let side = g.sideSiri {
            let path = Path(roundedRect: side, cornerRadius: 0.6)
            if highlight == .siri { emphasise(path) } else { context.stroke(path, with: .color(ink), lineWidth: line) }
        }
        context.fill(body, with: .color(Color(nsColor: .windowBackgroundColor)))
        context.stroke(body, with: .color(ink), lineWidth: line)

        if let touch = g.touch {
            var split = Path(); split.move(to: CGPoint(x: 0, y: touch.maxY)); split.addLine(to: CGPoint(x: g.size.width, y: touch.maxY))
            if highlight == .touchSurface || highlight == .arrows {
                let area = Path(roundedRect: touch.insetBy(dx: 1.6, dy: 1.6), cornerRadius: g.corner - 1.6)
                context.fill(area, with: .color(wash))
                context.stroke(area, with: .style(Color.accentColor.opacity(0.6)),
                               style: StrokeStyle(lineWidth: hair, dash: [2, 1.2]))
            }
            context.stroke(split, with: .color(ink), lineWidth: hair)
        }
        if let ring = g.ring {
            let outer = Path(ellipseIn: CGRect(x: ring.center.x - ring.outer, y: ring.center.y - ring.outer,
                                               width: ring.outer * 2, height: ring.outer * 2))
            let inner = Path(ellipseIn: CGRect(x: ring.center.x - ring.inner, y: ring.center.y - ring.inner,
                                               width: ring.inner * 2, height: ring.inner * 2))
            if highlight == .touchSurface || highlight == .arrows { emphasise(outer) }
            else { context.stroke(outer, with: .color(ink), lineWidth: line) }
            context.fill(inner, with: .color(Color(nsColor: .windowBackgroundColor)))
            context.stroke(inner, with: .color(ink), lineWidth: line)
        }

        let highlighted: String? = {
            let glass = g.touch != nil
            switch highlight {
            case .siri: return glass ? "siri" : nil
            case .deleteWord: return glass ? "menu" : "back"
            case .newLine: return "tv"
            case .advancedMenu: return glass ? "playPause" : "mute"
            case .computerUse: return glass ? nil : "playPause"
            default: return nil
            }
        }()
        for key in g.circles.keys.sorted() {
            guard let path = circle(key) else { continue }
            if key == highlighted { emphasise(path) } else { context.stroke(path, with: .color(ink), lineWidth: line) }
        }
        let volume = Path(roundedRect: g.volume, cornerRadius: g.volume.width / 2)
        context.stroke(volume, with: .color(ink), lineWidth: line)
        var signs = Path()
        let plus = CGPoint(x: g.volume.midX, y: g.volume.minY + 6), minus = CGPoint(x: g.volume.midX, y: g.volume.maxY - 6)
        signs.move(to: CGPoint(x: plus.x - 1.6, y: plus.y)); signs.addLine(to: CGPoint(x: plus.x + 1.6, y: plus.y))
        signs.move(to: CGPoint(x: plus.x, y: plus.y - 1.6)); signs.addLine(to: CGPoint(x: plus.x, y: plus.y + 1.6))
        signs.move(to: CGPoint(x: minus.x - 1.6, y: minus.y)); signs.addLine(to: CGPoint(x: minus.x + 1.6, y: minus.y))
        context.stroke(signs, with: .color(fine), lineWidth: hair)

        if highlight == .arrows { drawArrows(in: context, scale: scale) }
        if let touchProgress { drawTouch(progress: touchProgress, in: context, scale: scale) }
    }

    /// Chevrons at the four press zones of the touch surface or clickpad.
    private func drawArrows(in context: GraphicsContext, scale: CGFloat) {
        let g = geometry
        let center: CGPoint, reach: CGFloat
        if let touch = g.touch { center = CGPoint(x: touch.midX, y: touch.midY); reach = min(touch.width, touch.height) / 2 - 5 }
        else if let ring = g.ring { center = ring.center; reach = (ring.outer + ring.inner) / 2 }
        else { return }
        var chevrons = Path()
        for (dx, dy) in [(0.0, -1.0), (0, 1), (-1, 0), (1, 0)] {
            let tip = CGPoint(x: center.x + dx * (reach + 1.4), y: center.y + dy * (reach + 1.4))
            let base = CGPoint(x: center.x + dx * (reach - 0.6), y: center.y + dy * (reach - 0.6))
            chevrons.move(to: CGPoint(x: base.x + dy * 1.8, y: base.y + dx * 1.8))
            chevrons.addLine(to: tip)
            chevrons.addLine(to: CGPoint(x: base.x - dy * 1.8, y: base.y - dx * 1.8))
        }
        context.stroke(chevrons, with: .color(Color.accentColor),
                       style: StrokeStyle(lineWidth: 1.3 / scale, lineCap: .round, lineJoin: .round))
    }

    /// A fingertip and its trail: straight across the glass surface, around the clickpad ring.
    private func drawTouch(progress: Double, in context: GraphicsContext, scale: CGFloat) {
        let g = geometry
        var trail = Path(), tip: CGPoint
        if let touch = g.touch {
            let start = CGPoint(x: touch.minX + 7, y: touch.midY), end = CGPoint(x: touch.maxX - 7, y: touch.midY)
            tip = CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y)
            trail.move(to: start); trail.addLine(to: tip)
        } else if let ring = g.ring {
            let radius = (ring.outer + ring.inner) / 2
            let startAngle = Angle.degrees(-150), endAngle = Angle.degrees(-150 + 300 * progress)
            trail.addArc(center: ring.center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
            tip = CGPoint(x: ring.center.x + radius * cos(endAngle.radians), y: ring.center.y + radius * sin(endAngle.radians))
        } else { return }
        context.stroke(trail, with: .style(Color.accentColor.opacity(0.45)),
                       style: StrokeStyle(lineWidth: 1.2 / scale, lineCap: .round, dash: [1.5, 1.5]))
        let finger = Path(ellipseIn: CGRect(x: tip.x - 3.2, y: tip.y - 3.2, width: 6.4, height: 6.4))
        context.fill(finger, with: .color(Color.accentColor.opacity(0.3)))
        context.stroke(finger, with: .color(Color.accentColor), lineWidth: 1.2 / scale)
    }
}

/// Front-view technical drawing with optional overall-length dimension and a callout balloon.
struct RemoteBlueprint: View {
    let generation: RemoteGeneration
    var highlight: BlueprintHighlight = .none
    var symbol: String? = nil
    var showsDimension = false
    var touchProgress: Double? = nil
    var showsGrid = true

    var body: some View {
        Canvas { context, size in
            if showsGrid { BlueprintGrid.draw(in: context, size: size) }
            let geometry = RemoteGeometry.of(generation)
            let scale = (size.height - 22) / geometry.size.height
            let drawn = CGSize(width: geometry.size.width * scale, height: geometry.size.height * scale)
            let origin = CGPoint(x: ((size.width - drawn.width) / 2).rounded(), y: ((size.height - drawn.height) / 2).rounded())
            let fine = Color.primary.opacity(0.4)

            // Centre line, chain-dashed past both ends as on a drawing.
            var centre = Path()
            centre.move(to: CGPoint(x: size.width / 2, y: origin.y - 7))
            centre.addLine(to: CGPoint(x: size.width / 2, y: origin.y + drawn.height + 7))
            context.stroke(centre, with: .color(fine), style: StrokeStyle(lineWidth: 0.5, dash: [6, 2, 1.5, 2]))

            var remote = context
            remote.translateBy(x: origin.x, y: origin.y)
            remote.scaleBy(x: scale, y: scale)
            RemoteDrawing(geometry: geometry, highlight: highlight, touchProgress: touchProgress)
                .draw(in: remote, scale: scale)

            if showsDimension {
                let x = origin.x - 14
                var dimension = Path()
                for y in [origin.y, origin.y + drawn.height] {
                    dimension.move(to: CGPoint(x: origin.x - 3, y: y)); dimension.addLine(to: CGPoint(x: x - 3, y: y))
                }
                dimension.move(to: CGPoint(x: x, y: origin.y)); dimension.addLine(to: CGPoint(x: x, y: origin.y + drawn.height))
                for (y, dir) in [(origin.y, 1.0), (origin.y + drawn.height, -1.0)] {
                    dimension.move(to: CGPoint(x: x - 2, y: y + 4 * dir)); dimension.addLine(to: CGPoint(x: x, y: y))
                    dimension.addLine(to: CGPoint(x: x + 2, y: y + 4 * dir))
                }
                context.stroke(dimension, with: .color(fine), lineWidth: 0.6)
                var label = context
                label.translateBy(x: x - 6, y: origin.y + drawn.height / 2)
                label.rotate(by: .degrees(-90))
                label.draw(Text("\(Int(geometry.size.height)) mm").font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(.secondary), at: .zero)
                let width = origin.x + drawn.width + 14
                var widthMark = Path()
                widthMark.move(to: CGPoint(x: origin.x, y: origin.y + drawn.height + 4))
                widthMark.addLine(to: CGPoint(x: origin.x + drawn.width, y: origin.y + drawn.height + 4))
                context.stroke(widthMark, with: .color(fine), lineWidth: 0.6)
                context.draw(Text(String(format: "%.0f", geometry.size.width)).font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(.secondary), at: CGPoint(x: width, y: origin.y + drawn.height + 4), anchor: .leading)
            }

            if let symbol, let anchor = geometry.anchor(for: highlight) {
                let point = CGPoint(x: origin.x + anchor.x * scale, y: origin.y + anchor.y * scale)
                let balloon = CGPoint(x: origin.x + drawn.width + 30, y: min(max(point.y, 16), size.height - 16))
                var leader = Path()
                leader.move(to: point); leader.addLine(to: CGPoint(x: balloon.x - 11, y: balloon.y))
                context.stroke(leader, with: .color(Color.accentColor), lineWidth: 0.8)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 1.6, y: point.y - 1.6, width: 3.2, height: 3.2)),
                             with: .color(Color.accentColor))
                let circle = Path(ellipseIn: CGRect(x: balloon.x - 11, y: balloon.y - 11, width: 22, height: 22))
                context.fill(circle, with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(circle, with: .color(Color.accentColor), lineWidth: 1)
                var glyph = context.resolve(Image(systemName: symbol))
                glyph.shading = .color(Color.accentColor)
                let glyphSize = glyph.size
                let fit = min(11 / max(glyphSize.width, 1), 11 / max(glyphSize.height, 1))
                let target = CGSize(width: glyphSize.width * fit, height: glyphSize.height * fit)
                context.draw(glyph, in: CGRect(x: balloon.x - target.width / 2, y: balloon.y - target.height / 2,
                                               width: target.width, height: target.height))
            }
        }
    }
}

/// Setup page: the remote lying on its side, linked to the Mac it pairs with.
struct ConnectionBlueprint: View {
    let generation: RemoteGeneration
    let connected: Bool

    var body: some View {
        Canvas { context, size in
            BlueprintGrid.draw(in: context, size: size)
            let geometry = RemoteGeometry.of(generation)
            let scale = 0.86
            let length = geometry.size.height * scale, thickness = geometry.size.width * scale
            let macWidth: CGFloat = 50, gap: CGFloat = 46
            let left = ((size.width - length - gap - macWidth) / 2).rounded()
            let midY = size.height / 2

            var remote = context
            remote.translateBy(x: left, y: midY + thickness / 2)
            remote.rotate(by: .degrees(-90))
            remote.scaleBy(x: scale, y: scale)
            RemoteDrawing(geometry: geometry, highlight: .none, touchProgress: nil).draw(in: remote, scale: scale)

            let ink = Color.primary.opacity(0.78)
            let macLeft = left + length + gap
            let screen = CGRect(x: macLeft, y: midY - 22, width: macWidth, height: 32)
            context.stroke(Path(roundedRect: screen, cornerRadius: 3), with: .color(ink), lineWidth: 1)
            context.stroke(Path(roundedRect: screen.insetBy(dx: 3, dy: 3), cornerRadius: 1.5),
                           with: .color(Color.primary.opacity(0.35)), lineWidth: 0.6)
            var base = Path()
            base.move(to: CGPoint(x: macLeft - 6, y: screen.maxY + 4))
            base.addLine(to: CGPoint(x: screen.maxX + 6, y: screen.maxY + 4))
            base.move(to: CGPoint(x: macLeft, y: screen.maxY)); base.addLine(to: CGPoint(x: macLeft - 6, y: screen.maxY + 4))
            base.move(to: CGPoint(x: screen.maxX, y: screen.maxY)); base.addLine(to: CGPoint(x: screen.maxX + 6, y: screen.maxY + 4))
            context.stroke(base, with: .color(ink), lineWidth: 1)

            var link = Path()
            link.move(to: CGPoint(x: left + length + 6, y: midY))
            link.addLine(to: CGPoint(x: macLeft - 8, y: midY))
            context.stroke(link, with: .color(connected ? Color.accentColor : Color.secondary),
                           style: StrokeStyle(lineWidth: 1, dash: connected ? [] : [3, 2.5]))
            let badge = CGPoint(x: (left + length + macLeft) / 2, y: midY)
            let circle = Path(ellipseIn: CGRect(x: badge.x - 9, y: badge.y - 9, width: 18, height: 18))
            context.fill(circle, with: .color(Color(nsColor: .windowBackgroundColor)))
            context.stroke(circle, with: .color(connected ? Color.accentColor : Color.secondary), lineWidth: 1)
            var glyph = context.resolve(Image(systemName: connected ? "checkmark" : "antenna.radiowaves.left.and.right"))
            glyph.shading = .color(connected ? Color.accentColor : Color.secondary)
            context.draw(glyph, in: CGRect(x: badge.x - 5, y: badge.y - 5, width: 10, height: 10))
        }
    }
}

/// Looping demo: a fingertip moves on the drawn remote while the caret walks the sample text.
struct CursorDemo: View {
    let generation: RemoteGeneration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let sample = "Ship the fix today"

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let progress = reduceMotion ? 0.6 : Self.progress(at: timeline.date)
            HStack(spacing: 14) {
                RemoteBlueprint(generation: generation, highlight: .touchSurface, touchProgress: progress, showsGrid: false)
                    .frame(width: 64)
                caretField(progress: progress)
            }
            .frame(maxWidth: .infinity)
            .background { Canvas { context, size in BlueprintGrid.draw(in: context, size: size) } }
        }
    }

    /// Eased back-and-forth sweep with a short rest at each end.
    static func progress(at date: Date) -> Double {
        let period = 3.6
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        let sweep = min(max((phase < 0.5 ? phase : 1 - phase) * 2.4 - 0.1, 0), 1)
        return 0.5 - cos(sweep * .pi) / 2
    }

    private func caretField(progress: Double) -> some View {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        let position = Int((progress * Double(Self.sample.count)).rounded())
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.45), lineWidth: 0.8)
            Text(Self.sample).font(Font(font)).foregroundStyle(.primary).padding(.leading, 8)
            Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 14)
                .offset(x: 8 + CGFloat(position) * advance - 0.75)
        }
        .frame(width: CGFloat(Self.sample.count) * advance + 16, height: 26)
    }
}

/// Faint dot grid shared by every drawing.
enum BlueprintGrid {
    static func draw(in context: GraphicsContext, size: CGSize) {
        var dots = Path()
        let step: CGFloat = 12
        var y = step / 2
        while y < size.height {
            var x = step / 2
            while x < size.width { dots.addRect(CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)); x += step }
            y += step
        }
        context.fill(dots, with: .color(Color.primary.opacity(0.08)))
    }
}
