//
//  RemoteDetector.swift
//  VibeRemote
//
//  Detects Siri Remote via IOKit HID
//

import Foundation
import IOKit
import IOKit.hid

let vibeRemoteLogPath: String = {
    let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
    return libraryURL
        .appendingPathComponent("Logs/VibeRemote", isDirectory: true)
        .appendingPathComponent("viberemote.log")
        .path
}()

private let rmLogQueue = DispatchQueue(label: "com.viberemote.log", qos: .utility)
private let rmLogMaximumBytes: UInt64 = 1_048_576

/// Append diagnostics asynchronously to a private, size-bounded user log.
func rmDebug(_ message: String) {
    let line = "\(Date()) \(message)\n"
    rmLogQueue.async {
        guard let data = line.data(using: .utf8) else { return }
        let fileManager = FileManager.default
        let logURL = URL(fileURLWithPath: vibeRemoteLogPath)
        let directoryURL = logURL.deletingLastPathComponent()
        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let attributes = try? fileManager.attributesOfItem(atPath: logURL.path)
        let size = attributes?[.size] as? UInt64 ?? 0
        if size >= rmLogMaximumBytes {
            let rotatedURL = logURL.appendingPathExtension("1")
            try? fileManager.removeItem(at: rotatedURL)
            try? fileManager.moveItem(at: logURL, to: rotatedURL)
        }

        if !fileManager.fileExists(atPath: logURL.path) {
            _ = fileManager.createFile(
                atPath: logURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

/// IOHIDManager callbacks are scheduled on the main run loop, so all detector state lives on
/// the main actor. This also makes shutdown deterministic: after `stopDetection()` returns,
/// queued callbacks can observe `isDetecting == false` but cannot mutate cleared state.
@MainActor
final class RemoteDetector {
    enum DeviceEvent {
        case added(IOHIDDevice)
        case removed(IOHIDDevice)
    }

    enum DetectionState {
        case ready
        case failed(IOReturn)
    }

    private var manager: IOHIDManager?
    private var deviceCallback: ((DeviceEvent) -> Void)?
    private var stateCallback: ((DetectionState) -> Void)?
    private var trackedInterfaces: [ObjectIdentifier: IOHIDDevice] = [:]
    private var isDetecting = false
    private var generation: UInt64 = 0

    private let appleVendorID: Int = 0x004C

    // Known Siri Remote / Apple TV Remote product IDs. Product names take precedence because
    // Apple has reused IDs in nearby accessory families (0x0269 is a Magic Mouse on this Mac).
    private nonisolated static let knownProductIDs: Set<Int> = [
        0x0221, 0x0255, 0x0266, 0x0267, 0x026D,
        0x0C4E, 0x0C4F, 0x030D, 0x030E, 0x0314, 0x0315,
    ]

    init(
        deviceCallback: @escaping (DeviceEvent) -> Void,
        stateCallback: ((DetectionState) -> Void)? = nil
    ) {
        self.deviceCallback = deviceCallback
        self.stateCallback = stateCallback
    }

    func startDetection() {
        guard !isDetecting else { return }

        generation &+= 1
        let startGeneration = generation
        rmDebug(String(format: "🛰 starting HID detection (vendor=0x%X)", appleVendorID))

        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        self.manager = manager

        let matchingDicts: [[String: Any]] = [
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x0C],   // Consumer Page
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x0B],   // Telephony Page
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x0D],   // Digitizer / auxiliary buttons
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x20],   // Sensor reports on Gen-3 Siri Remote
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0xFF00], // Apple vendor-defined
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0xFF01], // Apple vendor-defined
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0xFF02], // Apple vendor-defined
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x01],   // Generic Desktop
            [kIOHIDVendorIDKey: appleVendorID, kIOHIDPrimaryUsagePageKey: 0x09],   // Button Page
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchingDicts as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceAddedCallback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCallback, context)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            rmDebug(String(format: "⚠️ IOHIDManagerOpen failed (IOReturn=0x%X)", openResult))
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            self.manager = nil
            stateCallback?(.failed(openResult))
            return
        }

        isDetecting = true
        rmDebug("🛰 IOHIDManagerOpen success")
        stateCallback?(.ready)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self,
                  self.isDetecting,
                  self.generation == startGeneration else { return }
            self.enumerateAllDevices()
        }
    }

    func stopDetection() {
        guard isDetecting || manager != nil || !trackedInterfaces.isEmpty else { return }

        isDetecting = false
        generation &+= 1

        if let manager {
            // Clear callbacks before unscheduling and closing so no new callback can capture self.
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(
                manager,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = nil
        }

        trackedInterfaces.removeAll()
    }

    private func enumerateAllDevices() {
        guard isDetecting,
              let manager,
              let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
            rmDebug("🛰 IOHIDManagerCopyDevices returned nil/empty (TCC block or matching mismatch)")
            return
        }

        rmDebug("🛰 enumeration found \(deviceSet.count) HID device(s) matching filter")
        for device in deviceSet {
            let vendorID = property(kIOHIDVendorIDKey, of: device, default: -1)
            let productID = property(kIOHIDProductIDKey, of: device, default: -1)
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "?"
            let usagePage = property(kIOHIDPrimaryUsagePageKey, of: device, default: -1)
            let usage = property(kIOHIDPrimaryUsageKey, of: device, default: -1)
            rmDebug(String(
                format: "🛰 candidate vendor=0x%X product=0x%X usagePage=0x%X usage=0x%X name=%@",
                vendorID, productID, usagePage, usage, name
            ))
            handleDeviceAdded(device)
        }
    }

    private func isSiriRemote(_ device: IOHIDDevice) -> Bool {
        Self.matchesSiriRemote(
            vendorID: property(kIOHIDVendorIDKey, of: device, default: -1),
            productID: property(kIOHIDProductIDKey, of: device, default: -1),
            productName: IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
        )
    }

    nonisolated static func matchesSiriRemote(
        vendorID: Int,
        productID: Int,
        productName: String?
    ) -> Bool {
        guard vendorID == 0x004C else { return false }

        if let productName, !productName.isEmpty {
            let name = productName.lowercased()
            // A concrete product name is stronger evidence than a numeric ID. In particular,
            // never seize a mouse, keyboard, or trackpad because an ID overlaps an old list.
            return name.contains("remote") || name.contains("siri") || name.contains("apple tv")
        }

        return knownProductIDs.contains(productID)
    }

    fileprivate func handleDeviceAdded(_ device: IOHIDDevice) {
        guard isDetecting, isSiriRemote(device) else { return }

        let interfaceID = ObjectIdentifier(device)
        guard trackedInterfaces[interfaceID] == nil else { return }

        let wasDisconnected = trackedInterfaces.isEmpty
        trackedInterfaces[interfaceID] = device

        if wasDisconnected {
            let vendorID = property(kIOHIDVendorIDKey, of: device, default: 0)
            let productID = property(kIOHIDProductIDKey, of: device, default: 0)
            let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
            print("✅ Siri Remote connected: \(productName) (Vendor: 0x\(String(vendorID, radix: 16, uppercase: true)), Product: 0x\(String(productID, radix: 16, uppercase: true)))")
        }

        deviceCallback?(.added(device))
    }

    fileprivate func handleDeviceRemoved(_ device: IOHIDDevice) {
        guard isDetecting, isSiriRemote(device) else { return }

        let interfaceID = ObjectIdentifier(device)
        guard trackedInterfaces.removeValue(forKey: interfaceID) != nil else { return }

        // Notify the input handler about the exact interface that disappeared. It decides
        // connection status from interfaces it actually opened, rather than from enumeration.
        deviceCallback?(.removed(device))

        if trackedInterfaces.isEmpty {
            let productName = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "Unknown"
            print("❌ Siri Remote disconnected: \(productName)")
        }
    }

    private func property(_ key: String, of device: IOHIDDevice, default defaultValue: Int) -> Int {
        IOHIDDeviceGetProperty(device, key as CFString) as? Int ?? defaultValue
    }
}

// MARK: - C callbacks

private struct CallbackDevice: @unchecked Sendable {
    let value: IOHIDDevice
}

private func deviceAddedCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let detector = Unmanaged<RemoteDetector>.fromOpaque(context).takeUnretainedValue()
    let callbackDevice = CallbackDevice(value: device)
    // The IOHID manager is scheduled on the main run loop in startDetection().
    MainActor.assumeIsolated {
        detector.handleDeviceAdded(callbackDevice.value)
    }
}

private func deviceRemovedCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let detector = Unmanaged<RemoteDetector>.fromOpaque(context).takeUnretainedValue()
    let callbackDevice = CallbackDevice(value: device)
    MainActor.assumeIsolated {
        detector.handleDeviceRemoved(callbackDevice.value)
    }
}
