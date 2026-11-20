import AppKit
import Carbon.HIToolbox

/// One keyboard modifier for voice input. Mac input uses hold-to-talk; Soundcore supports
/// both a short tap to latch listening and a longer hold that ends on release.
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

/// Two short, isolated taps; holds and intervening chords never count.
struct ComputerUseDoubleTap {
    private var downAt: TimeInterval?
    private var firstRelease: TimeInterval?
    private(set) var shortRelease = false
    mutating func reset() { downAt = nil; firstRelease = nil; shortRelease = false }
    mutating func update(down: Bool, now: TimeInterval) -> Bool {
        shortRelease = false
        if down { if downAt == nil { downAt = now }; return false }
        guard let start = downAt else { return false }
        downAt = nil
        guard now >= start, now - start <= 0.22 else { firstRelease = nil; return false }
        shortRelease = true
        if let previous = firstRelease, start >= previous, now - previous <= 0.45 {
            firstRelease = nil
            return true
        }
        firstRelease = now
        return false
    }
}

/// Both gestures coexist without a mode switch. A second isolated press ends latched
/// listening on release; turning that press into a shortcut leaves listening intact.
struct SoundcoreHotkeyGesture {
    enum Effect: Equatable { case none, begin, latch, stop, cancel }
    static let tapDuration: TimeInterval = 0.22
    private(set) var handsFree = false
    private var downAt: TimeInterval?
    private var stopOnRelease = false

    mutating func reset() { self = Self() }

    mutating func press(at time: TimeInterval) -> Effect {
        guard downAt == nil else { return .none }
        downAt = time
        stopOnRelease = handsFree
        return handsFree ? .none : .begin
    }

    mutating func release(at time: TimeInterval) -> Effect {
        guard let start = downAt else { return .none }
        downAt = nil
        if stopOnRelease {
            reset()
            return .stop
        }
        if time >= start, time - start <= Self.tapDuration {
            handsFree = true
            return .latch
        }
        reset()
        return .stop
    }

    mutating func interrupt() -> Effect {
        let preserveListening = handsFree && stopOnRelease
        downAt = nil
        stopOnRelease = false
        if preserveListening { return .none }
        reset()
        return .cancel
    }
}

/// Watches the keyboard for the chosen hotkey and drives `DictationController`. Global monitors
/// cover other apps (they need the Accessibility grant vvhisper already has); local monitors
/// cover vvhisper's own windows. Events vvhisper posts itself (a Siri mapping that holds Right
/// Option, the typewriter's keystrokes) are ignored, so the remote can never trigger the hotkey.
@MainActor
final class DictationHotkeyMonitor {
    static let shared = DictationHotkeyMonitor()

    var onComputerUseRequested: (() -> Void)?
    private var taps = ComputerUseDoubleTap()
    private var soundcoreGesture = SoundcoreHotkeyGesture()
    private var lastHotkey: DictationHotkey = .none
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

    func resetSoundcoreGesture() { soundcoreGesture.reset() }

    private func handleSoundcore(_ effect: DictationHotkeyGate.Effect, at time: TimeInterval) {
        let microphone = SoundcoreManager.shared
        let action: SoundcoreHotkeyGesture.Effect
        switch effect {
        case .none: return
        case .begin: action = soundcoreGesture.press(at: time)
        case .end: action = soundcoreGesture.release(at: time)
        case .cancel: action = soundcoreGesture.interrupt()
        }
        switch action {
        case .none: break
        case .begin:
            if !microphone.resumeDictationKey() {
                // Ignore presses during the final packet drain or another input's session.
                guard DictationController.shared.recordingSource == nil else {
                    soundcoreGesture.reset(); return
                }
                DictationController.shared.begin(source: .soundcore)
            }
            guard DictationController.shared.recordingSource == .soundcore else {
                soundcoreGesture.reset(); return
            }
            microphone.updateDictationListening(handsFree: false)
        case .latch:
            guard DictationController.shared.recordingSource == .soundcore else {
                soundcoreGesture.reset(); return
            }
            microphone.updateDictationListening(handsFree: true)
        case .stop: microphone.releaseDictationKey()
        case .cancel: microphone.endDictation(cancel: true)
        }
    }

    private func handle(_ event: NSEvent) {
        if let source = event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID),
           source == Int64(ProcessInfo.processInfo.processIdentifier) { return }
        let hotkey = DictationHotkey.load()
        if hotkey != lastHotkey {
            if DictationController.shared.recordingSource == .soundcore {
                SoundcoreManager.shared.endDictation(cancel: true)
            }
            gate = DictationHotkeyGate()
            soundcoreGesture.reset()
            taps.reset()
            lastHotkey = hotkey
        }
        if event.type == .keyDown, Int(event.keyCode) == kVK_Escape,
           DictationController.shared.recordingSource == .soundcore,
           (event.cgEvent?.flags.rawValue ?? 0) & DictationHotkeyGate.otherModifiers == 0 {
            SoundcoreManager.shared.endDictation(cancel: true)
            return
        }
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
        if event.type == .keyDown || (event.type == .flagsChanged && Int(event.keyCode) != hotkey.keyCode) { taps.reset() }
        if SoundcoreManager.shared.useForHotkey || DictationController.shared.recordingSource == .soundcore {
            // Soundcore taps belong to voice input, never the Computer Use double-tap.
            taps.reset()
            handleSoundcore(effect, at: event.timestamp)
            return
        }
        switch effect {
        case .none: break
        case .begin:
            _ = taps.update(down: true, now: event.timestamp)
            rmDebug("🗣 Dictation hotkey \(hotkey.title) down")
            DictationController.shared.begin(source: .macMicrophone)
        case .end:
            let open = taps.update(down: false, now: event.timestamp)
            if DictationController.shared.recordingSource == .macMicrophone {
                if taps.shortRelease { DictationController.shared.cancel() }
                else { DictationController.shared.end() }
            }
            if open { onComputerUseRequested?() }
        case .cancel:
            taps.reset()
            if DictationController.shared.recordingSource == .macMicrophone { DictationController.shared.cancel() }
        }
    }
}
