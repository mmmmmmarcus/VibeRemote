//
//  MediaKeyInterceptor.swift
//  VibeRemote
//
//  Intercepts system media key events at HID level to reliably prevent default handling.
//  Re-enables tap when disabled by timeout/sleep and on wake.
//

import Cocoa
import IOKit
import NativeTouch
@preconcurrency import CoreGraphics

@MainActor
final class MediaKeyInterceptor {
    private let packetButtons = PacketLoggerButtonMonitor()
    var capturePath: String?
    var onSourceReset: (() -> Void)?
    func resetRemoteCorrelation() { remoteEvents = RemoteMediaEventCorrelation() }
    private static let forwardedMarker: Int64 = 0x56524D45444941
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    
    var onMediaKey: ((MediaKeyType, Bool, UInt64?) -> Bool)?
    private var remoteSources: Set<UInt64> = []
    private var remoteEvents = RemoteMediaEventCorrelation()
    var shouldAwaitRemoteSource: ((MediaKeyType) -> Bool)?
    
    enum MediaKeyType {
        case playPause, next, previous, volumeUp, volumeDown, mute
    }
    
    /// Starts intercepting system-defined media key events.
    ///
    /// - Returns: `true` when the tap is installed (or was already installed),
    ///   and `false` when macOS denied creation of the HID-level event tap.
    @discardableResult
    func start() -> Bool {
        if eventTap != nil {
            return true
        }

        let eventMask: CGEventMask = 1 << 14 // NX_SYSDEFINED
        
        // HID-level tap intercepts media keys before the system handles them (more reliable than session tap).
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()
                // This tap is scheduled exclusively on the main run loop below.
                return MainActor.assumeIsolated {
                    interceptor.handleEvent(proxy: proxy, type: type, event: event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        packetButtons.onReset = { [weak self] in
            self?.resetRemoteCorrelation(); self?.onSourceReset?()
        }
        packetButtons.onEdge = { [weak self] edge in
            guard let self else { return }
            let key: MediaKeyType = edge.button == "playPause" ? .playPause : .mute
            guard self.shouldAwaitRemoteSource?(key) == true else { return }
            let age = Date().timeIntervalSince(edge.capturedAt)
            self.remoteEvents.record(button: edge.button, pressed: edge.pressed, sender: edge.sender,
                                     now: ProcessInfo.processInfo.systemUptime - age)
            rmDebug("PacketLogger button: \(edge.button) \(edge.pressed ? "down" : "up") source=\(edge.sender) ageMs=\(Int(age * 1000))")
        }
        if let capturePath { packetButtons.start(path: capturePath) }

        // Re-enable tap after sleep/wake (system often disables taps during sleep).
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reenableTap()
            }
        }

        return true
    }
    
    func stop() {
        packetButtons.stop()
        remoteEvents = RemoteMediaEventCorrelation()
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            wakeObserver = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        remoteSources.removeAll()
    }
    
    /// Re-enable the event tap after it was disabled by timeout or sleep.
    func reenableTap() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap when system disables it (timeout or user input); then consume the event.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reenableTap()
            return nil
        }
        
        // NX_SYSDEFINED = 14
        guard type.rawValue == 14 else {
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.forwardedMarker {
            return Unmanaged.passUnretained(event)
        }
        
        // Get NSEvent to parse the media key
        guard let nsEvent = NSEvent(cgEvent: event) else {
            return Unmanaged.passUnretained(event)
        }
        
        // Check subtype 8 = media key event
        guard nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        
        // Parse the key code from data1
        let keyCode = Int32((nsEvent.data1 & 0xFFFF0000) >> 16)
        let keyFlags = nsEvent.data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        let isKeyDown = keyState == 0x0A
        let isKeyUp = keyState == 0x0B

        guard isKeyDown || isKeyUp else {
            return Unmanaged.passUnretained(event)
        }
        
        // Identify the media key
        var mediaKey: MediaKeyType?
        switch keyCode {
        case NX_KEYTYPE_PLAY:
            mediaKey = .playPause
        case NX_KEYTYPE_NEXT, NX_KEYTYPE_FAST:
            mediaKey = .next
        case NX_KEYTYPE_PREVIOUS, NX_KEYTYPE_REWIND:
            mediaKey = .previous
        case NX_KEYTYPE_SOUND_UP:
            mediaKey = .volumeUp
        case NX_KEYTYPE_SOUND_DOWN:
            mediaKey = .volumeDown
        case NX_KEYTYPE_MUTE:
            mediaKey = .mute
        default:
            break
        }
        
        if let key = mediaKey, let handler = onMediaKey {
            let sender = vr_media_event_sender(event)
            let remote = isRemoteSource(sender) ? sender : nil
            let consumed = handler(key, isKeyDown, remote)
            if !consumed, remote == nil, shouldAwaitRemoteSource?(key) == true, let copy = event.copy() {
                // The passive capture and NX tap use independent delivery paths;
                // either may arrive first. Hold only configured switch keys briefly, then
                // consume confirmed remote events or forward unrelated keyboard events once.
                let repeating = keyFlags & 1 != 0
                // The main loop can be delayed while HID interfaces reopen. Compare original
                // event times, preserving a narrow match window even after that stall.
                let receivedAt = event.timestamp > 0 ? Double(event.timestamp) / 1_000_000_000 : ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                    self?.packetButtons.pollNow()
                    let button = key == .playPause ? "playPause" : "mute"
                    let observed = self?.remoteEvents.resolve(button: button, pressed: isKeyDown,
                        repeating: repeating, now: receivedAt)
                    let consumed = observed.map { self?.onMediaKey?(key, isKeyDown, $0) == true } ?? false
                    rmDebug("Media key \(key) \(isKeyDown ? "down" : "up") deferred consumed=\(consumed) remote=\(observed != nil)")
                    if !consumed {
                        copy.setIntegerValueField(.eventSourceUserData, value: Self.forwardedMarker)
                        copy.post(tap: .cghidEventTap)
                    }
                }
                return nil
            }
            rmDebug("Media key \(key) \(isKeyDown ? "down" : "up") consumed=\(consumed) remote=\(remote != nil) sender=\(sender) sourcePID=\(event.getIntegerValueField(.eventSourceUnixProcessID)) data2=\(nsEvent.data2) epoch=\(String(format: "%.6f", Date().timeIntervalSince1970))")
            if consumed { return nil }
        }
        
        return Unmanaged.passUnretained(event)
    }

    private func isRemoteSource(_ sender: UInt64) -> Bool {
        guard sender != 0 else { return false }
        if remoteSources.contains(sender) { return true }
        let service = IOServiceGetMatchingService(0, IORegistryEntryIDMatching(sender))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        func property(_ name: String) -> Any? {
            IORegistryEntrySearchCFProperty(service, kIOServicePlane, name as CFString,
                kCFAllocatorDefault, IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        }
        let matches = RemoteDetector.matchesSiriRemote(
            vendorID: property("VendorID") as? Int ?? 0,
            productID: property("ProductID") as? Int ?? 0,
            productName: property("Product") as? String
        )
        if matches {
            if remoteSources.count >= 32 { remoteSources.removeAll() }
            remoteSources.insert(sender)
        }
        return matches
    }
}
