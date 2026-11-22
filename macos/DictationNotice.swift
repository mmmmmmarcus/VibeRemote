import AppKit
import SwiftUI

/// Only app-authored text is shown here; provider bodies can contain private data.
struct DictationNotice: Equatable {
    let title: String
    let message: String
    let code: String
    var accessibilityPermission = false

    static func failure(_ detail: String) -> Self {
        let text = detail.lowercased()
        if text.contains("accessibility") {
            return .init(title: "Allow text insertion", message: "Enable vvhisper in System Settings → Privacy & Security → Accessibility, then try again.", code: "DICT-ACCESS", accessibilityPermission: true)
        }
        if text.contains("microphone access") || text.contains("allow vvhisper to use the microphone") {
            return .init(title: "Microphone permission needed", message: "Enable vvhisper in System Settings → Privacy & Security → Microphone.", code: "DICT-MIC-PERMISSION")
        }
        if text.contains("no audio") || text.contains("microphone") || text.contains("recording") {
            return .init(title: "No usable microphone audio", message: "Check the selected microphone. For Siri Remote, check the voice bridge and permissions in Settings → About.", code: "DICT-AUDIO")
        }
        if text.contains("key") || text.contains("401") || text.contains("403") || text.contains("unauthorized") || text.contains("authentication") {
            return .init(title: "Check your dictation API key", message: "Open Dictation settings on this Mac and check the selected provider’s key and service access.", code: "DICT-CREDENTIALS")
        }
        if text.contains("429") || text.contains("quota") || text.contains("balance") {
            return .init(title: "Dictation service limit reached", message: "Check the provider’s balance or usage limit, then try again.", code: "DICT-SERVICE-LIMIT")
        }
        if text.contains("focus") || text.contains("cursor") || text.contains("input field") || text.contains("keyboard events") {
            return .init(title: "Text insertion stopped", message: "Click an editable text field and try again. Keep that field focused until dictation finishes. Check Accessibility permission if typing still fails.", code: "DICT-INSERT")
        }
        return .init(title: "Dictation couldn’t finish", message: "The speech service or recording could not be processed. Check your connection and provider settings. More details are available in Dictation settings.", code: "DICT-RECOGNITION")
    }

    static let noSpeech = Self(title: "No speech recognized", message: "Check the selected microphone and try speaking again.", code: "DICT-NO-SPEECH")
    static let polishing = Self(title: "Polishing unavailable", message: "The recognized text was kept. Check the separate Volcengine Ark key and connection in Dictation settings.", code: "DICT-POLISH")
}

final class DictationNoticePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// App-owned feedback does not depend on notification permission and never takes editor focus.
@MainActor
final class DictationNoticePresenter {
    static let shared = DictationNoticePresenter()
    var openSettings: (() -> Void)?
    private var panel: NSPanel?

    func dismiss() { panel?.orderOut(nil); panel = nil }

    func show(_ notice: DictationNotice) {
        dismiss()
        let panel = DictationNoticePanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: DictationNoticeView(notice: notice, dismiss: { [weak self] in self?.dismiss() }, settings: { [weak self] in
            self?.dismiss()
            if notice.accessibilityPermission, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            } else { self?.openSettings?() }
        }))
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 440, y: frame.maxY - 210))
        }
        self.panel = panel
        panel.orderFrontRegardless()
    }
}

private struct DictationNoticeView: View {
    let notice: DictationNotice
    let dismiss: () -> Void
    let settings: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
                Text(notice.title).font(.headline)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss")
            }
            Text(notice.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(notice.code).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(notice.accessibilityPermission ? "Open Accessibility Settings" : "Open Settings", action: settings)
            }
        }
        .padding(18).frame(width: 420, height: 190, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
    }
}
