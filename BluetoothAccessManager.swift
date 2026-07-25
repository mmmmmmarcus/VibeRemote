//
//  BluetoothAccessManager.swift
//  VibeRemote
//
//  Keeps Bluetooth authorization optional and explicitly user initiated.
//

import AppKit
@preconcurrency import CoreBluetooth

enum BluetoothAccessState: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case allowed

    var allowsBatteryLookup: Bool {
        self == .allowed
    }
}

@MainActor
final class BluetoothAccessManager: NSObject, @preconcurrency CBCentralManagerDelegate {
    private var centralManager: CBCentralManager?
    var onStateChanged: ((BluetoothAccessState) -> Void)?

    var state: BluetoothAccessState {
        Self.currentState
    }

    static var currentState: BluetoothAccessState {
        switch CBManager.authorization {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .allowedAlways: return .allowed
        @unknown default: return .restricted
        }
    }

    /// Requests Bluetooth only after the user explicitly chooses the corresponding menu item.
    func requestAccess() {
        switch state {
        case .allowed:
            onStateChanged?(.allowed)
        case .notDetermined:
            if centralManager == nil {
                centralManager = CBCentralManager(
                    delegate: self,
                    queue: nil,
                    options: [CBCentralManagerOptionShowPowerAlertKey: false]
                )
            }
        case .denied, .restricted:
            openBluetoothPrivacySettings()
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let updatedState = Self.currentState
        onStateChanged?(updatedState)
        if updatedState != .notDetermined {
            centralManager = nil
        }
    }

    private func openBluetoothPrivacySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        ) else { return }
        let opened = NSWorkspace.shared.open(url)
        rmDebug("🔐 Open Bluetooth settings: \(opened ? "success" : "failed")")
    }
}
