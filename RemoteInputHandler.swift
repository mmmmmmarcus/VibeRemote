//
//  RemoteInputHandler.swift
//  VibeRemote
//
//  Processes HID input events from Siri Remote
//

import IOKit
import IOKit.hid
import Foundation
import Carbon.HIToolbox
import AppKit

/// HID callbacks are delivered on the main run loop. Keeping device, button, and synthetic-key
/// state on the main actor prevents teardown from racing an in-flight press or release.
@MainActor
final class RemoteInputHandler {
    private final class InputReportRegistration {
        let buffer: UnsafeMutablePointer<UInt8>
        let capacity: Int

        init(capacity: Int) {
            self.capacity = capacity
            self.buffer = .allocate(capacity: capacity)
            self.buffer.initialize(repeating: 0, count: capacity)
        }

        deinit {
            buffer.deinitialize(count: capacity)
            buffer.deallocate()
        }
    }

    fileprivate final class FeatureEnableRequest {
        weak var handler: RemoteInputHandler?
        let usagePage: Int
        let usage: Int
        let variant: String
        let buffer: UnsafeMutablePointer<UInt8>
        let length: Int

        /// `payload` is the exact byte sequence handed to IOHID. Whether IOHID strips a
        /// leading report-ID byte before the GATT write is transport-dependent, so callers
        /// try both framings.
        init(handler: RemoteInputHandler, usagePage: Int, usage: Int, variant: String, payload: [UInt8]) {
            self.handler = handler
            self.usagePage = usagePage
            self.usage = usage
            self.variant = variant
            self.length = payload.count
            self.buffer = .allocate(capacity: payload.count)
            for (index, byte) in payload.enumerated() {
                self.buffer[index] = byte
            }
        }

        deinit {
            buffer.deallocate()
        }
    }

    private weak var menuBarManager: MenuBarManager?
    private weak var microphoneBridgeManager: MicrophoneBridgeManager?
    private var devices: [ObjectIdentifier: IOHIDDevice] = [:]
    /// IOKit registry entry IDs of the interfaces we hold open, captured at open time.
    /// Registry IDs are never reused, so "our ID no longer resolves" is definitive proof the
    /// service was re-enumerated behind our back (see `hasStaleInterfaces`).
    private var deviceRegistryIDs: [ObjectIdentifier: UInt64] = [:]
    private var inputReportRegistrations: [ObjectIdentifier: InputReportRegistration] = [:]
    private var audioReportCounts: [ObjectIdentifier: UInt64] = [:]
    private var lastAudioReports: [ObjectIdentifier: (data: Data, time: TimeInterval)] = [:]
    private var isAcceptingInput = true

    /// Descriptors for every interface we hold open, used to tell the 1st-gen remote from the
    /// 2nd/3rd-gen one. Both families report the same product name and have shipped under the
    /// same product ID, so the decision needs the whole interface set (see `RemoteGeneration`).
    private var interfaceDescriptors: [ObjectIdentifier: RemoteInterfaceDescriptor] = [:]
    /// Interfaces that only carry raw reports to the audio parser. Their button elements are
    /// still handled normally — on the 1st-gen remote the same interface may do both.
    private var audioOnlyInterfaces: Set<ObjectIdentifier> = []
    private var lastReportedGeneration: RemoteGeneration = .unknown
    /// Generation per physical remote, keyed by `RemoteInterfaceDescriptor.deviceKey`.
    private var deviceGenerations: [String: RemoteGeneration] = [:]

    /// Which remote family is currently attached. Drives the button profile and the
    /// microphone path; `.unknown` until at least one interface is open.
    private(set) var generation: RemoteGeneration = .unknown

    var onGenerationChanged: ((RemoteGeneration) -> Void)?

    // Prevent double-processing with MediaKeyInterceptor. Both producers run on the main loop.
    static var lastProcessedButton: String?
    static var lastProcessedTime: UInt64 = 0

    /// Virtual keys currently held down, keyed by the HID button that initiated the hold.
    /// The key specification is captured at press time so release remains correct even if the
    /// user changes that button's mapping before letting go.
    private var heldKeys: [String: (keyCode: Int, flags: CGEventFlags)] = [:]
    private var pendingTapKeyUps: [UUID: (keyCode: Int, flags: CGEventFlags)] = [:]

    /// Last observed pressed/released state per logical button. A Siri Remote may mirror a
    /// button over multiple HID interfaces, so this collapses duplicates into one transition.
    private var buttonState: [String: Bool] = [:]

    var isConnected: Bool {
        !devices.isEmpty
    }

    init(menuBarManager: MenuBarManager, microphoneBridgeManager: MicrophoneBridgeManager) {
        self.menuBarManager = menuBarManager
        self.microphoneBridgeManager = microphoneBridgeManager
    }

    /// Opens one exact HID interface and reports whether at least one interface is usable.
    @discardableResult
    func addRemoteDevice(_ device: IOHIDDevice) -> Bool {
        guard isAcceptingInput else { return isConnected }

        let interfaceID = ObjectIdentifier(device)
        guard devices[interfaceID] == nil else { return isConnected }

        let preferredOptions: IOOptionBits = shouldSeize(device)
            ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            : IOOptionBits(kIOHIDOptionsTypeNone)

        var openResult = IOHIDDeviceOpen(device, preferredOptions)
        var openedOptions = preferredOptions
        if openResult != kIOReturnSuccess,
           preferredOptions == IOOptionBits(kIOHIDOptionsTypeSeizeDevice) {
            rmDebug(String(
                format: "⚠️ FAILED to seize HID device (IOReturn=0x%X) — opening unseized",
                openResult
            ))
            openedOptions = IOOptionBits(kIOHIDOptionsTypeNone)
            openResult = IOHIDDeviceOpen(device, openedOptions)
        }

        guard openResult == kIOReturnSuccess else {
            rmDebug(String(format: "⚠️ FAILED to open Siri HID interface (IOReturn=0x%X)", openResult))
            return isConnected
        }

        let mode = openedOptions == IOOptionBits(kIOHIDOptionsTypeSeizeDevice)
            ? "SEIZED"
            : "LISTENING"
        rmDebug(String(
            format: "🔒 %@ HID device (vendor=0x%X product=0x%X usagePage=0x%X usage=0x%X)",
            mode,
            property(kIOHIDVendorIDKey, of: device),
            property(kIOHIDProductIDKey, of: device),
            property(kIOHIDPrimaryUsagePageKey, of: device),
            property(kIOHIDPrimaryUsageKey, of: device)
        ))

        // Buffered-byte HID elements are delivered as IOHIDValue on some macOS builds even when
        // the raw report queue remains empty, so every interface keeps its value callback —
        // including the audio ones, which deduplicate against the raw reports below.
        IOHIDDeviceRegisterInputValueCallback(
            device,
            inputValueCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(
            device,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        devices[interfaceID] = device
        interfaceDescriptors[interfaceID] = descriptor(for: device)
        let service = IOHIDDeviceGetService(device)
        if service != IO_OBJECT_NULL {
            var registryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(service, &registryID) == KERN_SUCCESS {
                deviceRegistryIDs[interfaceID] = registryID
            }
        }
        // Interfaces arrive one at a time, so the generation is only knowable after each open.
        // Re-running the audio registrations here lets a late-arriving interface flip the
        // decision and retro-fit the interfaces that were already open.
        refreshGeneration()
        applyAudioRegistrations()
        enableRemoteInputStreaming(on: device)
        return true
    }

    private func descriptor(for device: IOHIDDevice) -> RemoteInterfaceDescriptor {
        let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String
        let productID = property(kIOHIDProductIDKey, of: device)
        return RemoteInterfaceDescriptor(
            deviceKey: serial ?? "product-\(productID)",
            productName: IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String,
            productID: productID,
            transport: IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String,
            usagePage: property(kIOHIDPrimaryUsagePageKey, of: device),
            usage: property(kIOHIDPrimaryUsageKey, of: device),
            maxInputReportSize: property(kIOHIDMaxInputReportSizeKey, of: device),
            maxFeatureReportSize: property(kIOHIDMaxFeatureReportSizeKey, of: device),
            hardwareRevision: IOHIDDeviceGetProperty(device, "kBTHardwareRevisionKey" as CFString) as? String
        )
    }

    private func refreshGeneration() {
        let descriptors = Array(interfaceDescriptors.values)
        // Both remotes can be paired at once — a 1st-gen next to a 2nd/3rd-gen is the normal
        // state while testing — so every decision that belongs to a specific button press or
        // audio report uses that interface's own remote. `generation` is only the one the menu
        // reports.
        deviceGenerations = RemoteGeneration.classifyAll(interfaces: descriptors)
        generation = RemoteGeneration.primary(interfaces: descriptors)
        guard generation != lastReportedGeneration else { return }
        lastReportedGeneration = generation
        if descriptors.isEmpty {
            rmDebug("🎛 Remote generation: no remote attached")
        } else {
            rmDebug("🎛 Remote generation: \(generation.displayName) — microphone path: \(generation.microphoneTransport.rawValue)")
        }
        onGenerationChanged?(generation)
    }

    /// The remote family behind one HID interface, which is what button mappings and audio
    /// registrations must key off when more than one remote is attached.
    private func generation(ofInterface interfaceID: ObjectIdentifier) -> RemoteGeneration {
        guard let descriptor = interfaceDescriptors[interfaceID] else { return generation }
        return deviceGenerations[descriptor.deviceKey] ?? generation
    }

    /// Bring every open interface's raw-report registration in line with the current
    /// generation and actual collections. Some black-glass remotes also expose a dedicated
    /// audio collection; prefer that before considering legacy report sniffing.
    private func applyAudioRegistrations() {
        let dedicatedDeviceKeys = Set(interfaceDescriptors.values.filter {
            Self.isAudioInterface(usagePage: $0.usagePage, usage: $0.usage)
        }.map(\.deviceKey))
        for (interfaceID, device) in devices {
            guard let descriptor = interfaceDescriptors[interfaceID] else { continue }
            let dedicated = Self.isAudioInterface(
                usagePage: descriptor.usagePage,
                usage: descriptor.usage
            )
            let wanted = dedicated || Self.shouldSniffAudio(
                descriptor: descriptor,
                generation: deviceGenerations[descriptor.deviceKey] ?? generation,
                hasDedicatedAudioCollection: dedicatedDeviceKeys.contains(descriptor.deviceKey)
            )
            let registered = inputReportRegistrations[interfaceID] != nil
            if dedicated {
                audioOnlyInterfaces.insert(interfaceID)
            }
            guard wanted != registered else { continue }

            if wanted {
                let capacity = max(1, descriptor.maxInputReportSize)
                let registration = InputReportRegistration(capacity: capacity)
                inputReportRegistrations[interfaceID] = registration
                audioReportCounts[interfaceID] = 0
                IOHIDDeviceRegisterInputReportCallback(
                    device,
                    registration.buffer,
                    registration.capacity,
                    inputReportCallback,
                    Unmanaged.passUnretained(self).toOpaque()
                )
                rmDebug(String(
                    format: "🎙 Audio listener registered (usagePage=0x%X usage=0x%X capacity=%d dedicated=%@)",
                    descriptor.usagePage,
                    descriptor.usage,
                    capacity,
                    dedicated ? "yes" : "no"
                ))
            } else if let registration = inputReportRegistrations.removeValue(forKey: interfaceID) {
                IOHIDDeviceRegisterInputReportCallback(
                    device,
                    registration.buffer,
                    registration.capacity,
                    nil,
                    nil
                )
                audioReportCounts.removeValue(forKey: interfaceID)
                lastAudioReports.removeValue(forKey: interfaceID)
            }
        }
    }

    /// Pure so the sniffing rule can be pinned by tests: only the older remote widens the net,
    /// and only to interfaces whose reports could actually hold a voice frame.
    nonisolated static func shouldSniffAudio(
        descriptor: RemoteInterfaceDescriptor,
        generation: RemoteGeneration,
        hasDedicatedAudioCollection: Bool = false
    ) -> Bool {
        guard !hasDedicatedAudioCollection else { return false }
        guard generation.microphoneTransport == .hidReportSniffing else { return false }
        return descriptor.maxInputReportSize >= RemoteGeneration.minimumSniffedReportSize
    }

    // MARK: - Stale-interface watchdog

    /// True when at least one interface we hold open no longer exists in the IOKit registry.
    ///
    /// macOS can silently re-enumerate the remote's HID services — observed when starting
    /// screen mirroring reconfigures the Bluetooth stack. The old device objects never fire
    /// another callback and never report removal, so buttons die and the firmware's voice
    /// enable resets with no error anywhere. Registry-ID resolution is the reliable probe:
    /// a terminated service's ID stops resolving and IDs are never reused.
    func hasStaleInterfaces() -> Bool {
        guard !deviceRegistryIDs.isEmpty else { return false }
        for registryID in deviceRegistryIDs.values {
            // Port 0 is the documented default lookup port (kIOMasterPortDefault /
            // kIOMainPortDefault across SDK renames).
            let service = IOServiceGetMatchingService(0, IORegistryEntryIDMatching(registryID))
            guard service != IO_OBJECT_NULL else { return true }
            IOObjectRelease(service)
        }
        return false
    }

    /// Closes every held interface but keeps accepting input, so a fresh detection pass can
    /// re-open the re-enumerated services (unlike `stop()`, which is terminal).
    func resetForRediscovery() {
        disconnectAll()
    }

    /// Third-generation Siri Remotes keep all HID input reports, including microphone audio,
    /// silent until the host writes 0xAF to their writable HID Feature reports (the
    /// siri-remote reverse-engineering project confirms Gen-3 exposes the enable control as
    /// Feature reports; Gen-1/2 used Output reports, which macOS does not surface at all).
    /// macOS presents each HID-over-GATT Report characteristic as a separate IOHIDDevice and
    /// remaps its report ID to 0xFF, so try the write on every interface; the remote ignores
    /// the reports that are not the input-enable control characteristic.
    ///
    /// The over-the-air characteristic value must be exactly one byte, 0xAF. Whether IOHID
    /// strips a leading report-ID byte from the caller's buffer before the GATT write is not
    /// documented for the Bluetooth transport, so send both framings; the wrong one is
    /// ignored by the remote.
    private func enableRemoteInputStreaming(on device: IOHIDDevice) {
        // The 1st-gen remote can advertise no writable Feature report at all yet still accept
        // the Output-report enable below, so only the newer remote's Feature path is gated on
        // a non-zero Feature report size.
        guard property(kIOHIDVendorIDKey, of: device) == 0x004C,
              property(kIOHIDMaxFeatureReportSizeKey, of: device) >= 1
                  || generation(ofInterface: ObjectIdentifier(device)).microphoneTransport
                      == .hidReportSniffing else {
            return
        }

        let usagePage = property(kIOHIDPrimaryUsagePageKey, of: device)
        let usage = property(kIOHIDPrimaryUsageKey, of: device)
        var variants: [(String, IOHIDReportType, [UInt8])] = [
            ("feature id+value", kIOHIDReportTypeFeature, [0xFF, 0xAF]),
            ("feature value-only", kIOHIDReportTypeFeature, [0xAF]),
        ]
        // The 1st-gen remote predates the writable Feature control the newer remote uses; its
        // input-enable is an Output report. macOS surfaces Output reports on HID-over-GATT
        // devices, so the write is worth making — the remote ignores the reports that are not
        // its control characteristic, exactly as it does for the Feature variants above.
        if generation(ofInterface: ObjectIdentifier(device)).microphoneTransport == .hidReportSniffing {
            variants.append(("output id+value", kIOHIDReportTypeOutput, [0xFF, 0xAF]))
            variants.append(("output value-only", kIOHIDReportTypeOutput, [0xAF]))
        }
        for (variant, reportType, payload) in variants {
            let request = FeatureEnableRequest(
                handler: self,
                usagePage: usagePage,
                usage: usage,
                variant: variant,
                payload: payload
            )
            let context = Unmanaged.passRetained(request).toOpaque()
            let result = IOHIDDeviceSetReportWithCallback(
                device,
                reportType,
                0xFF,
                request.buffer,
                request.length,
                1_000,
                featureEnableCallback,
                context
            )
            if result != kIOReturnSuccess {
                Unmanaged<FeatureEnableRequest>.fromOpaque(context).release()
                handleFeatureEnableResult(result, usagePage: usagePage, usage: usage, variant: variant)
            }
        }
        readBackEnableFeature(on: device, usagePage: usagePage, usage: usage)
    }

    /// Diagnostic read-back: if the transport round-trips GetReport to the remote, the value
    /// shows whether an enable write actually landed on this characteristic.
    private func readBackEnableFeature(on device: IOHIDDevice, usagePage: Int, usage: Int) {
        var buffer = [UInt8](repeating: 0, count: 209)
        var length = CFIndex(buffer.count)
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0xFF, &buffer, &length)
        if result == kIOReturnSuccess {
            let preview = buffer.prefix(min(8, max(1, length)))
                .map { String(format: "%02X", $0) }
                .joined(separator: " ")
            rmDebug(String(
                format: "🔎 Feature read-back length=%ld bytes=[%@] (usagePage=0x%X usage=0x%X)",
                length,
                preview,
                usagePage,
                usage
            ))
        } else {
            rmDebug(String(
                format: "🔎 Feature read-back failed (IOReturn=0x%X usagePage=0x%X usage=0x%X)",
                result,
                usagePage,
                usage
            ))
        }
    }

    fileprivate func handleFeatureEnableResult(
        _ result: IOReturn,
        usagePage: Int,
        usage: Int,
        variant: String
    ) {
        if result == kIOReturnSuccess {
            rmDebug(String(
                format: "📡 Siri Remote input enabled (%@ <- 0xAF, usagePage=0x%X usage=0x%X)",
                variant,
                usagePage,
                usage
            ))
        } else {
            rmDebug(String(
                format: "ℹ️ Siri Remote input-enable %@ ignored (IOReturn=0x%X usagePage=0x%X usage=0x%X)",
                variant,
                result,
                usagePage,
                usage
            ))
        }
    }

    /// Closes only the interface that disappeared. Remaining interfaces continue handling input.
    @discardableResult
    func removeRemoteDevice(_ device: IOHIDDevice) -> Bool {
        let interfaceID = ObjectIdentifier(device)
        guard let openedDevice = devices.removeValue(forKey: interfaceID) else {
            return isConnected
        }

        closeDevice(openedDevice)

        // A disappearing interface can take the matching key-up event with it. Releasing active
        // synthetic keys is safer than leaving Space/Command/Option stuck while other interfaces run.
        releaseAllHeldKeys()
        releaseAllPendingTapKeys()
        return isConnected
    }

    /// Compatibility entry point for callers that provide an optional device.
    @discardableResult
    func setRemoteDevice(_ device: IOHIDDevice?) -> Bool {
        guard let device else {
            disconnectAll()
            return false
        }
        return addRemoteDevice(device)
    }

    /// Synchronous, terminal, and idempotent teardown used during application shutdown.
    /// Callbacks are unregistered before devices close, then every actually-held key is released.
    func stop() {
        guard isAcceptingInput || !devices.isEmpty || !heldKeys.isEmpty || !pendingTapKeyUps.isEmpty else {
            return
        }

        isAcceptingInput = false
        disconnectAll()
        Self.lastProcessedButton = nil
        Self.lastProcessedTime = 0
    }

    private func disconnectAll() {
        let openedDevices = Array(devices.values)
        devices.removeAll()
        for device in openedDevices {
            closeDevice(device)
        }
        releaseAllHeldKeys()
        releaseAllPendingTapKeys()
        refreshGeneration()
    }

    private func closeDevice(_ device: IOHIDDevice) {
        let interfaceID = ObjectIdentifier(device)
        IOHIDDeviceRegisterInputValueCallback(device, nil, nil)
        if let registration = inputReportRegistrations[interfaceID] {
            IOHIDDeviceRegisterInputReportCallback(
                device,
                registration.buffer,
                registration.capacity,
                nil,
                nil
            )
            inputReportRegistrations.removeValue(forKey: interfaceID)
            audioReportCounts.removeValue(forKey: interfaceID)
            lastAudioReports.removeValue(forKey: interfaceID)
        }
        interfaceDescriptors.removeValue(forKey: interfaceID)
        audioOnlyInterfaces.remove(interfaceID)
        deviceRegistryIDs.removeValue(forKey: interfaceID)
        IOHIDDeviceUnscheduleFromRunLoop(
            device,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func shouldSeize(_ device: IOHIDDevice) -> Bool {
        let usagePage = property(kIOHIDPrimaryUsagePageKey, of: device)
        let usage = property(kIOHIDPrimaryUsageKey, of: device)

        // Apple's button driver must observe the Siri transition before its audio driver can
        // negotiate a microphone session with the remote. The side button is an element inside
        // Consumer/0x01, not the top-level Consumer/0x04 audio collection. Keep both collections
        // shared while continuing to seize unrelated touch/sensor interfaces.
        return !Self.requiresSharedSystemAccess(usagePage: usagePage, usage: usage)
    }

    nonisolated static func isAudioInterface(usagePage: Int, usage: Int) -> Bool {
        usagePage == 0x0C && usage == 0x04
    }

    /// Widest HID value that can still be a button. Siri Remote button elements report a
    /// 1-byte pressed/released state and the widest observed button mask is 3 bytes.
    static let maximumButtonValueLength = 8

    nonisolated static func requiresSharedSystemAccess(usagePage: Int, usage: Int) -> Bool {
        isAudioInterface(usagePage: usagePage, usage: usage)
            || (usagePage == 0x0C && usage == 0x01)
    }

    fileprivate func handleInputReport(
        result: IOReturn,
        reportID: UInt32,
        bytes: UnsafePointer<UInt8>?,
        length: Int,
        from interfaceID: ObjectIdentifier?,
        source: String
    ) {
        guard isAcceptingInput,
              result == kIOReturnSuccess,
              let interfaceID,
              devices[interfaceID] != nil,
              inputReportRegistrations[interfaceID] != nil,
              let bytes,
              length > 0 else {
            if result != kIOReturnSuccess {
                rmDebug(String(format: "⚠️ Direct HID audio callback failed (IOReturn=0x%X)", result))
            }
            return
        }

        let data = Data(bytes: bytes, count: length)
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = lastAudioReports[interfaceID],
           previous.data == data,
           now - previous.time < 0.002 {
            return
        }
        lastAudioReports[interfaceID] = (data, now)
        let count = (audioReportCounts[interfaceID] ?? 0) + 1
        audioReportCounts[interfaceID] = count
        if count == 1 || count % 50 == 0 {
            let preview = data.prefix(24).map { String(format: "%02X", $0) }.joined(separator: " ")
            rmDebug("🎙 HID audio report: count=\(count) source=\(source) id=0x\(String(reportID, radix: 16, uppercase: true)) length=\(length) preview=\(preview)")
        }
        microphoneBridgeManager?.handleDirectHIDAudioReport(
            reportID: reportID,
            data: data
        )
    }

    fileprivate func handleInputValue(_ value: IOHIDValue, from interfaceID: ObjectIdentifier?) {
        guard isAcceptingInput else { return }
        if let interfaceID, devices[interfaceID] == nil {
            // The callback was queued just before this exact interface was removed or closed.
            return
        }

        let element = IOHIDValueGetElement(value)
        if let interfaceID, inputReportRegistrations[interfaceID] != nil {
            // A dedicated audio collection carries nothing but audio, so every value on it is
            // a buffered voice frame. A sniffed interface on the 1st-gen remote carries both,
            // and its button elements are 1–4 bytes wide while a voice frame never is — so
            // only oversized values are diverted, and buttons keep working.
            let length = IOHIDValueGetLength(value)
            if audioOnlyInterfaces.contains(interfaceID) || length > Self.maximumButtonValueLength {
                handleInputReport(
                    result: kIOReturnSuccess,
                    reportID: UInt32(IOHIDElementGetReportID(element)),
                    bytes: IOHIDValueGetBytePtr(value),
                    length: length,
                    from: interfaceID,
                    source: "value"
                )
                return
            }
        }
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let intValue = IOHIDValueGetIntegerValue(value)

        let identified = Self.identifyButton(page: usagePage, usage: usage)
        rmDebug(String(
            format: "🎮 HID event: page=0x%X usage=0x%X value=%d → %@",
            usagePage, usage, intValue, identified ?? "<unmapped>"
        ))
        guard let buttonName = identified else { return }

        // Collapse mirrored-interface duplicates: only proceed on a real state transition.
        let isPressed = intValue != 0
        if buttonState[buttonName] == isPressed {
            return
        }
        buttonState[buttonName] = isPressed
        if buttonName == "siri" {
            rmDebug("Latency Siri \(isPressed ? "down" : "up") epoch=\(String(format: "%.6f", Date().timeIntervalSince1970))")
        }

        // Volume keys on the Siri Remote also travel over BT AVRCP absolute-volume, which
        // coreaudiod honors below cghidEventTap. Track both press and release so the
        // CoreAudio listener snaps the level back to the pre-press value.
        if buttonName == "volumeUp" || buttonName == "volumeDown" {
            VolumeRevertGuard.shared.handleRemoteButton(buttonName, pressed: isPressed)
        }

        if isPressed {
            Self.lastProcessedButton = buttonName
            Self.lastProcessedTime = mach_absolute_time()
        }

        microphoneBridgeManager?.handleButton(button: buttonName, pressed: isPressed)

        let sourceGeneration = interfaceID.map(generation(ofInterface:)) ?? generation
        let action = menuBarManager?.getMapping(for: buttonName, generation: sourceGeneration)
            ?? ButtonAction.none
        if isPressed {
            print("🔘 Button pressed: \(buttonName) → \(action.rawValue)")
        }
        rmDebug("🎛 Button \(buttonName) \(isPressed ? "down" : "up") source=\(sourceGeneration.shortName) action=\(action.rawValue)")
        executeAction(action, button: buttonName, pressed: isPressed)
    }

    // MARK: - Button Identification

    /// Pure internal mapping so tests can verify that unknown vendor-defined usages are ignored.
    nonisolated static func identifyButton(page: UInt32, usage: UInt32) -> String? {
        switch (page, usage) {
        // Generic Desktop Page (0x01)
        case (0x01, 0x86): return "menu"          // System Menu Main
        case (0x01, 0x40): return "menu"          // Menu (alternative)

        // Consumer Page (0x0C)
        case (0x0C, 0x04): return "siri"          // Siri button (actual)
        case (0x0C, 0x60): return "tv"            // TV button (actual)
        case (0x0C, 0x80): return "select"        // Selection
        case (0x0C, 0x41): return "select"        // Menu Pick (clickpad center press)
        case (0x0C, 0x42): return "navUp"         // Menu Up (clickpad)
        case (0x0C, 0x43): return "navDown"       // Menu Down (clickpad)
        case (0x0C, 0x44): return "navLeft"       // Menu Left (clickpad)
        case (0x0C, 0x45): return "navRight"      // Menu Right (clickpad)
        case (0x0C, 0xCD): return "playPause"     // Play/Pause
        case (0x0C, 0xE9): return "volumeUp"      // Volume Increment
        case (0x0C, 0xEA): return "volumeDown"    // Volume Decrement
        case (0x0C, 0xB5): return "nextTrack"     // Scan Next Track
        case (0x0C, 0xB6): return "prevTrack"     // Scan Previous Track
        case (0x0C, 0x223): return "tv"           // AC Home (TV button alternative)
        case (0x0C, 0x224): return "back"         // AC Back
        case (0x0C, 0x40): return "menu"          // Menu

        // Standard Consumer usages the 1st-gen remote can emit instead of the ones above. It
        // predates the 2nd-gen HID descriptor, so its six buttons are reported with the
        // generic media usages rather than the Apple-specific ones. Anything still unmapped is
        // logged as "<unmapped>" with its page/usage, which is how new usages get identified.
        case (0x0C, 0x46): return "menu"          // Menu Escape
        case (0x0C, 0x88): return "tv"            // Media Select Home
        case (0x0C, 0x89): return "tv"            // Media Select TV
        case (0x0C, 0xB0): return "playPause"     // Play
        case (0x0C, 0xB1): return "playPause"     // Pause
        case (0x0C, 0xCF): return "siri"          // Voice Command (1st-gen microphone button)
        case (0x0C, 0x221): return "siri"         // AC Search
        case (0x0C, 0x30): return "power"         // Power
        case (0x0C, 0xE2): return "mute"          // Mute (standard Consumer usage; verified on 2nd-gen Siri Remote)
        case (0x0C, 0x20): return "mute"          // Mute (some remotes report this instead)

        // Button Page (0x09)
        case (0x09, 0x01): return "select"        // Button 1

        // Apple Vendor Page (0xFF00). Only usages observed for Siri are accepted; never map
        // the whole vendor page because it can contain unrelated sensors and controls.
        case (0xFF00, 0x01): return "siri"
        case (0xFF00, 0x02): return "siri"
        case (0xFF00, 0x03): return "siri"

        // Telephony Page (0x0B) - sometimes used for Siri
        case (0x0B, 0x21): return "siri"          // Flash
        case (0x0B, 0x2F): return "siri"          // Phone Mute

        default: return nil
        }
    }

    // MARK: - Action Execution

    private func executeAction(_ action: ButtonAction, button: String, pressed: Bool) {
        guard pressed else {
            // Release: stop any auto-repeat, resolve a pending tap/long-press or modifier,
            // and release any physically held key captured for this button.
            stopRepeat(for: button)
            resolveRelease(for: button)
            resolveModifierRelease(for: button)
            releaseHeldKey(for: button)
            return
        }

        // A held modifier (mute) reroutes chorded buttons to their advanced action and
        // suppresses their normal one entirely — including hold behaviors like auto-repeat.
        if !heldModifierButtons.isEmpty, let chord = Self.modifierChord(for: button) {
            modifierChordFired.formUnion(heldModifierButtons)
            performChord(chord)
            return
        }

        if action.requiresHold {
            beginHoldAction(action, button: button)
            return
        }

        switch action {
        case .none:
            break
        case .enterKey:
            sendKey(kVK_Return)
        case .shiftEnter:
            sendKey(kVK_Return, flags: .maskShift)
        case .backspace:
            // Option+Delete = the system's deleteWordBackward:. Apple's text system segments
            // Chinese with its dictionary tokenizer (我爱北京天安门 deletes 天安门, then 北京…),
            // so word-wise deletion works for English, Chinese, and mixed text alike. Repeat
            // is slowed to word cadence — 50ms per word would erase half a sentence per second.
            beginRepeating(button: button, interval: wordRepeatInterval) { [weak self] in
                self?.sendKey(kVK_Delete, flags: .maskAlternate)
            }
        case .upKey:
            beginRepeating(button: button) { [weak self] in self?.sendKey(kVK_UpArrow) }
        case .downKey:
            beginRepeating(button: button) { [weak self] in self?.sendKey(kVK_DownArrow) }
        case .leftKey:
            beginRepeating(button: button) { [weak self] in self?.sendKey(kVK_LeftArrow) }
        case .rightKey:
            beginRepeating(button: button) { [weak self] in self?.sendKey(kVK_RightArrow) }
        case .escKey:
            sendKey(kVK_Escape)
        case .ctrlC:
            sendKey(kVK_ANSI_C, flags: .maskControl)
        case .launchAgentClient:
            toggleAgentClient()
        case .bulletIndent:
            // Tap = indent (Tab); long-press = turn the current line into a bullet ("- ").
            beginTapOrLongPress(
                button: button,
                tap: { [weak self] in self?.sendKey(kVK_Tab) },
                longPress: { [weak self] in self?.sendBulletMarker() }
            )
        case .bulletOutdent:
            sendKey(kVK_Tab, flags: .maskShift)
        case .slashOrModifier:
            // Quick tap types "/" (the skill/command-picker trigger in agent apps); holding
            // arms the button as a modifier for the chords in `modifierChord(for:)`.
            beginModifierHold(button: button) { [weak self] in self?.sendKey(kVK_ANSI_Slash) }
        case .shiftEnterOrModifier:
            // 1st-gen remote: TV takes over the missing mute button's modifier role while
            // keeping its own tap action.
            beginModifierHold(button: button) { [weak self] in
                self?.sendKey(kVK_Return, flags: .maskShift)
            }
        case .agentClientOrSlash:
            // 1st-gen remote: Play/Pause takes over the missing mute button's "/" tap.
            beginTapOrLongPress(
                button: button,
                tap: { [weak self] in self?.toggleAgentClient() },
                longPress: { [weak self] in self?.sendKey(kVK_ANSI_Slash) }
            )
        case .spaceKey, .rightCmd, .rightOpt:
            break // handled above
        }
    }

    // MARK: - Hold behavior (auto-repeat & tap/long-press)

    // The remote reports one press and one release with no repeats in between, so we
    // synthesize key repeat ourselves and time the press to tell a tap from a long-press.
    private var repeatTimers: [String: Timer] = [:]
    private var longPressTimers: [String: Timer] = [:]
    private var pendingTapActions: [String: () -> Void] = [:]

    private let repeatInitialDelay: TimeInterval = 0.4
    private let repeatInterval: TimeInterval = 0.05
    /// Word-wise deletion erases far more per tick than a character, so it repeats slower.
    private let wordRepeatInterval: TimeInterval = 0.18
    private let repeatMaxTicks = 400   // ~20s safety cap in case a release is ever dropped
    private let longPressThreshold: TimeInterval = 0.4

    /// These timers are created and fired on the main run loop. Common modes keep a held
    /// button responsive while an AppKit menu is tracking; callbacks remain synchronous so
    /// a queued action cannot run after release.
    private func scheduleInputTimer(
        interval: TimeInterval,
        repeats: Bool,
        action: @escaping @MainActor @Sendable (Timer) -> Void
    ) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: repeats) { timer in
            let callbackTimer = MainRunLoopTimer(timer: timer)
            MainActor.assumeIsolated { action(callbackTimer.timer) }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Fire immediately, then auto-repeat while the button stays held (Backspace, arrows).
    private func beginRepeating(button: String, interval: TimeInterval? = nil, fire: @escaping @MainActor @Sendable () -> Void) {
        stopRepeat(for: button)
        fire()
        let starter = scheduleInputTimer(interval: repeatInitialDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            var ticks = 0
            let repeater = self.scheduleInputTimer(interval: interval ?? self.repeatInterval, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                ticks += 1
                if ticks > self.repeatMaxTicks {
                    timer.invalidate()
                    self.repeatTimers[button] = nil
                    return
                }
                fire()
            }
            self.repeatTimers[button] = repeater
        }
        repeatTimers[button] = starter
    }

    private func stopRepeat(for button: String) {
        repeatTimers[button]?.invalidate()
        repeatTimers[button] = nil
    }

    /// Distinguish a short tap from a hold: the long-press action fires once the threshold
    /// elapses; a release before then runs the tap action instead.
    private func beginTapOrLongPress(button: String, tap: @escaping @MainActor @Sendable () -> Void, longPress: @escaping @MainActor @Sendable () -> Void) {
        cancelLongPress(for: button)
        pendingTapActions[button] = tap
        let timer = scheduleInputTimer(interval: longPressThreshold, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.longPressTimers[button] = nil
            self.pendingTapActions[button] = nil
            longPress()
        }
        longPressTimers[button] = timer
    }

    /// On release, if a long-press timer is still pending it was a tap — run the tap action.
    private func resolveRelease(for button: String) {
        guard let timer = longPressTimers[button] else { return }
        timer.invalidate()
        longPressTimers[button] = nil
        let tap = pendingTapActions[button]
        pendingTapActions[button] = nil
        tap?()
    }

    private func cancelLongPress(for button: String) {
        longPressTimers[button]?.invalidate()
        longPressTimers[button] = nil
        pendingTapActions[button] = nil
    }

    // MARK: Tap-or-modifier (mute button)

    /// Chord actions available while the mute modifier is held. The firmware reports
    /// concurrent presses as independent HID events (verified: mute held + playPause both
    /// delivered), so a chord is just "a mapped button arriving while the modifier is down".
    enum ModifierChord: Equatable {
        /// Select everything and delete it (Cmd+A, Backspace).
        case clearInput
        /// Esc — the "stop the current task" convention in agent apps.
        case escape
    }

    /// Pure mapping so tests can pin the chord table. Both "back" and "menu" are listed
    /// because the physical Back button reports as either depending on the remote.
    nonisolated static func modifierChord(for button: String) -> ModifierChord? {
        switch button {
        case "back", "menu": return .clearInput
        case "playPause": return .escape
        default: return nil
        }
    }

    private var heldModifierButtons: Set<String> = []
    private var modifierChordFired: Set<String> = []
    private var modifierPressStart: [String: Date] = [:]
    /// The tap half of each armed modifier button, captured at press time. It differs per
    /// remote: the 2nd/3rd-gen mute button types "/", while the 1st-gen TV button — which
    /// inherits the modifier role from the mute button it does not have — sends Shift+Enter.
    private var modifierTapActions: [String: () -> Void] = [:]

    /// A release quicker than this is a tap; anything longer was a modifier hold — used or
    /// abandoned — and produces nothing on its own.
    private let modifierTapMaxDuration: TimeInterval = 0.4

    private func beginModifierHold(button: String, tap: @escaping () -> Void) {
        heldModifierButtons.insert(button)
        modifierChordFired.remove(button)
        modifierPressStart[button] = Date()
        modifierTapActions[button] = tap
    }

    private func resolveModifierRelease(for button: String) {
        guard heldModifierButtons.remove(button) != nil else { return }
        let pressedAt = modifierPressStart.removeValue(forKey: button)
        let tap = modifierTapActions.removeValue(forKey: button)
        let chorded = modifierChordFired.remove(button) != nil
        guard !chorded,
              let pressedAt,
              Date().timeIntervalSince(pressedAt) < modifierTapMaxDuration else {
            return
        }
        tap?()
    }

    private func performChord(_ chord: ModifierChord) {
        switch chord {
        case .clearInput:
            sendKey(kVK_ANSI_A, flags: .maskCommand)
            sendKey(kVK_Delete)
        case .escape:
            sendKey(kVK_Escape)
        }
    }

    private func stopAllHoldTimers() {
        VolumeRevertGuard.shared.releaseRemoteButtons()
        repeatTimers.values.forEach { $0.invalidate() }
        repeatTimers.removeAll()
        longPressTimers.values.forEach { $0.invalidate() }
        longPressTimers.removeAll()
        pendingTapActions.removeAll()
        heldModifierButtons.removeAll()
        modifierChordFired.removeAll()
        modifierPressStart.removeAll()
        modifierTapActions.removeAll()
    }

    /// "- " + space is the markdown input rule that turns the current line into a bullet.
    private func sendBulletMarker() {
        sendKey(kVK_ANSI_Minus)
        sendKey(kVK_Space)
    }

    /// Bundle identifiers of the agent desktop clients this remote can summon.
    private static let codexBundleID = "com.openai.codex"        // ChatGPT / Codex desktop
    private static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// Brings a coding-agent client to the front. If neither is frontmost, Codex comes up;
    /// otherwise it toggles to the other one. Falls back to whichever is installed.
    private func toggleAgentClient() {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let preferred: String
        let fallback: String
        switch front {
        case Self.codexBundleID:
            preferred = Self.claudeBundleID
            fallback = Self.codexBundleID
        case Self.claudeBundleID:
            preferred = Self.codexBundleID
            fallback = Self.claudeBundleID
        default:
            preferred = Self.codexBundleID
            fallback = Self.claudeBundleID
        }
        if !activateApp(bundleID: preferred) {
            _ = activateApp(bundleID: fallback)
        }
    }

    @discardableResult
    private func activateApp(bundleID: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        rmDebug("🚀 Activating agent client \(bundleID)")
        return true
    }

    /// Press a virtual key and retain its exact specification until this HID button is released.
    private func beginHoldAction(_ action: ButtonAction, button: String) {
        let spec: (keyCode: Int, flags: CGEventFlags)
        switch action {
        case .spaceKey: spec = (kVK_Space, [])
        case .rightCmd: spec = (kVK_RightCommand, .maskCommand)
        case .rightOpt: spec = (kVK_RightOption, .maskAlternate)
        default: return
        }

        // Defensive: close a stale hold before opening another for the same physical button.
        releaseHeldKey(for: button)
        postKey(keyCode: spec.keyCode, flags: spec.flags, keyDown: true)
        heldKeys[button] = spec
    }

    private func releaseHeldKey(for button: String) {
        guard let held = heldKeys.removeValue(forKey: button) else { return }
        postKey(keyCode: held.keyCode, flags: [], keyDown: false)
    }

    private func releaseAllHeldKeys() {
        stopAllHoldTimers()
        for held in heldKeys.values {
            postKey(keyCode: held.keyCode, flags: [], keyDown: false)
        }
        heldKeys.removeAll()
        buttonState.removeAll()
    }

    private func releaseAllPendingTapKeys() {
        for pending in pendingTapKeyUps.values {
            postKey(keyCode: pending.keyCode, flags: pending.flags, keyDown: false)
        }
        pendingTapKeyUps.removeAll()
    }

    private func property(_ key: String, of device: IOHIDDevice) -> Int {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int ?? 0
    }

    private func postKey(keyCode: Int, flags: CGEventFlags, keyDown: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: CGKeyCode(keyCode),
            keyDown: keyDown
        )
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
    }

    private func sendKey(_ keyCode: Int, flags: CGEventFlags = []) {
        postKey(keyCode: keyCode, flags: flags, keyDown: true)
        let eventID = UUID()
        pendingTapKeyUps[eventID] = (keyCode, flags)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self,
                  let pending = self.pendingTapKeyUps.removeValue(forKey: eventID) else {
                return
            }
            self.postKey(keyCode: pending.keyCode, flags: pending.flags, keyDown: false)
        }
    }
}

// MARK: - C callback

// Timer is only accessed synchronously on the main run loop, including invalidation.
private struct MainRunLoopTimer: @unchecked Sendable {
    let timer: Timer
}

private struct CallbackValue: @unchecked Sendable {
    let value: IOHIDValue
}

private func inputValueCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let context else { return }
    let handler = Unmanaged<RemoteInputHandler>.fromOpaque(context).takeUnretainedValue()
    let interfaceID: ObjectIdentifier?
    if let sender {
        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        interfaceID = ObjectIdentifier(device)
    } else {
        interfaceID = nil
    }
    let callbackValue = CallbackValue(value: value)
    // HID devices are scheduled on the main run loop in addRemoteDevice().
    MainActor.assumeIsolated {
        handler.handleInputValue(callbackValue.value, from: interfaceID)
    }
}

private func inputReportCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard type == kIOHIDReportTypeInput, let context else { return }
    let handler = Unmanaged<RemoteInputHandler>.fromOpaque(context).takeUnretainedValue()
    let interfaceID: ObjectIdentifier?
    if let sender {
        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        interfaceID = ObjectIdentifier(device)
    } else {
        interfaceID = nil
    }
    MainActor.assumeIsolated {
        handler.handleInputReport(
            result: result,
            reportID: reportID,
            bytes: UnsafePointer(report),
            length: reportLength,
            from: interfaceID,
            source: "report"
        )
    }
}

private func featureEnableCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context else { return }
    let request = Unmanaged<RemoteInputHandler.FeatureEnableRequest>
        .fromOpaque(context)
        .takeRetainedValue()
    MainActor.assumeIsolated {
        request.handler?.handleFeatureEnableResult(
            result,
            usagePage: request.usagePage,
            usage: request.usage,
            variant: request.variant
        )
    }
}
