import AppKit
import Carbon.HIToolbox

/// Settings › Dictation › Alternative Dictation Hotkey (2026-11-11, user's request): one keyboard
/// modifier that dictates the way a Siri hold does — hold to record, release to transcribe and type.
/// The remote's microphone only streams while Siri is physically held, so the hotkey records the
/// Mac's own microphone (`DictationController.Source.macMicrophone`) without changing the system
/// input. Everything after recording (streaming, dictionary, refinement, the orange cursor) is the
/// same path a Siri hold takes.
enum DictationHotkey: String, CaseIterable, Sendable {
    case none, leftOption, rightOption, leftCommand, rightCommand, leftControl, rightControl

    static let defaultsKey = "dictationHotkey"

    static func load(from defaults: UserDefaults = .standard) -> DictationHotkey {
        defaults.string(forKey: defaultsKey).flatMap(DictationHotkey.init(rawValue:)) ?? .none
    }

    var title: String {
        switch self {
        case .none: return "None"
        case .leftOption: return "Left Option"
        case .rightOption: return "Right Option"
        case .leftCommand: return "Left Command"
        case .rightCommand: return "Right Command"
        case .leftControl: return "Left Control"
        case .rightControl: return "Right Control"
        }
    }

    var keyCode: Int? {
        switch self {
        case .none: return nil
        case .leftOption: return kVK_Option
        case .rightOption: return kVK_RightOption
        case .leftCommand: return kVK_Command
        case .rightCommand: return kVK_RightCommand
        case .leftControl: return kVK_Control
        case .rightControl: return kVK_RightControl
        }
    }

    /// The device-dependent flag bit (IOLLEvent.h's NX_DEVICE…KEYMASK) that tells this side's key
    /// from the other side's: the generic Option/Command/Control flags cannot.
    var deviceMask: UInt64 {
        switch self {
        case .none: return 0
        case .leftControl: return 0x0000_0001
        case .leftCommand: return 0x0000_0008
        case .rightCommand: return 0x0000_0010
        case .leftOption: return 0x0000_0020
        case .rightOption: return 0x0000_0040
        case .rightControl: return 0x0000_2000
        }
    }

    /// The generic flag this key also sets, so other modifiers can be told apart from it.
    var genericMask: UInt64 {
        switch self {
        case .none: return 0
        case .leftOption, .rightOption: return CGEventFlags.maskAlternate.rawValue
        case .leftCommand, .rightCommand: return CGEventFlags.maskCommand.rawValue
        case .leftControl, .rightControl: return CGEventFlags.maskControl.rawValue
        }
    }
}

/// Pure hold logic, so it is testable without an event tap. A modifier is also half of every
/// shortcut, so the hold only dictates when the key is pressed alone: another modifier already
/// down at the press, or any key or modifier pressed while it is held, makes it a shortcut and
/// cancels the hold (nothing typed). A tap shorter than the controller's minimum is dropped there.
struct DictationHotkeyGate {
    enum Effect: Equatable { case none, begin, end, cancel }

    private(set) var held = false
    private var cancelled = false

    static let otherModifiers: UInt64 = CGEventFlags.maskShift.rawValue | CGEventFlags.maskControl.rawValue
        | CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue

    mutating func flagsChanged(keyCode: Int, flags: UInt64, hotkey: DictationHotkey) -> Effect {
        guard let code = hotkey.keyCode else { return reset() }
        if keyCode == code {
            let down = flags & hotkey.deviceMask != 0
            if down, !held {
                held = true
                // Already part of a chord (e.g. Command down first): stay out of the way.
                cancelled = flags & Self.otherModifiers & ~hotkey.genericMask != 0
                return cancelled ? .none : .begin
            }
            if !down, held {
                held = false
                return cancelled ? .none : .end
            }
            return .none
        }
        // Another modifier changed while the hotkey is held: a shortcut, not dictation.
        return interrupt()
    }

    mutating func keyDown() -> Effect { interrupt() }

    private mutating func interrupt() -> Effect {
        guard held, !cancelled else { return .none }
        cancelled = true
        return .cancel
    }

    private mutating func reset() -> Effect {
        let wasActive = held && !cancelled
        held = false
        cancelled = false
        return wasActive ? .cancel : .none
    }
}

/// Watches the keyboard for the chosen hotkey and drives `DictationController`. Global monitors
/// cover other apps (they need the Accessibility grant VibeRemote already has); local monitors
/// cover VibeRemote's own windows. Events VibeRemote posts itself (a Siri mapping that holds Right
/// Option, the typewriter's keystrokes) are ignored, so the remote can never trigger the hotkey.
@MainActor
final class DictationHotkeyMonitor {
    static let shared = DictationHotkeyMonitor()

    private var gate = DictationHotkeyGate()
    private var monitors: [Any] = []

    func start() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }) { monitors.append(local) }
    }

    private func handle(_ event: NSEvent) {
        if let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID),
           source == Int64(ProcessInfo.processInfo.processIdentifier) { return }
        let hotkey = DictationHotkey.load()
        let effect: DictationHotkeyGate.Effect
        switch event.type {
        case .flagsChanged:
            effect = gate.flagsChanged(keyCode: Int(event.keyCode),
                                       flags: event.cgEvent?.flags.rawValue ?? 0, hotkey: hotkey)
        case .keyDown:
            effect = gate.keyDown()
        default:
            return
        }
        switch effect {
        case .none: break
        case .begin:
            rmDebug("🗣 Dictation hotkey \(hotkey.title) down")
            DictationController.shared.begin(source: .macMicrophone)
        case .end:
            if DictationController.shared.recordingSource == .macMicrophone { DictationController.shared.end() }
        case .cancel:
            if DictationController.shared.recordingSource == .macMicrophone { DictationController.shared.cancel() }
        }
    }
}
