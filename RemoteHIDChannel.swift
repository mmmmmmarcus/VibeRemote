//
//  RemoteHIDChannel.swift
//  VibeRemote
//
//  Opens the Siri Remote HID-over-GATT service directly. macOS exposes the same
//  service through IOHID, but its proxy does not reliably complete the Gen-3
//  input-enable Feature write required before microphone report 0xFA will flow.
//

@preconcurrency import CoreBluetooth
import Foundation
import IOKit.hid

@MainActor
final class RemoteHIDChannel: NSObject,
    @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate {

    private struct ReportReference {
        let id: UInt8
        let type: UInt8
    }

    private let hidServiceUUID = CBUUID(string: "1812")
    private let reportCharacteristicUUID = CBUUID(string: "2A4D")
    private let reportReferenceUUID = CBUUID(string: "2908")
    private let microphoneReportID: UInt8 = 0xFA
    private let inputReportType: UInt8 = 1
    private let savedIdentifiersKey = "remoteHIDPeripheralIdentifiers"

    private weak var microphoneBridgeManager: MicrophoneBridgeManager?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var reportCharacteristics: [CBCharacteristic] = []
    private var reportReferences: [ObjectIdentifier: ReportReference] = [:]
    private var pendingReferences: Set<ObjectIdentifier> = []
    private var pendingNotifications: Set<ObjectIdentifier> = []
    private var retryTimer: Timer?
    private var knownPeripheralIdentifiers: [UUID] = []
    private var isStarted = false
    private var hasConfiguredReports = false
    private var audioReportCount: UInt64 = 0
    private var serviceDiscoveryFailures = 0
    private let serviceDiscoveryFailureLimit = 5

    init(microphoneBridgeManager: MicrophoneBridgeManager) {
        self.microphoneBridgeManager = microphoneBridgeManager
        super.init()
        knownPeripheralIdentifiers = UserDefaults.standard
            .stringArray(forKey: savedIdentifiersKey)?
            .compactMap(UUID.init(uuidString:)) ?? []
    }

    /// macOS's HID-over-GATT driver already knows the CoreBluetooth UUID even when the
    /// connected HID peripheral is omitted from CoreBluetooth's service cache and no longer
    /// advertises. Feed that UUID back into CoreBluetooth's identifier-based retrieval path.
    func considerHIDDevice(_ device: IOHIDDevice) {
        guard let identifier = Self.peripheralIdentifier(
            from: IOHIDDeviceGetProperty(device, kIOHIDPhysicalDeviceUniqueIDKey as CFString)
        ) else { return }
        remember(identifier)
        guard isStarted, central?.state == .poweredOn else { return }
        findConnectedRemote()
    }

    /// Does not instantiate CoreBluetooth unless the user has already granted Bluetooth access.
    /// This preserves the menu bar's explicit, user-initiated permission flow.
    func startIfAuthorized() {
        guard BluetoothAccessManager.currentState == .allowed else {
            rmDebug("📡 Direct GATT HID channel waiting for Bluetooth permission")
            return
        }
        guard !isStarted else { return }
        isStarted = true
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    func stop() {
        isStarted = false
        retryTimer?.invalidate()
        retryTimer = nil
        central?.stopScan()
        peripheral?.delegate = nil
        peripheral = nil
        central = nil
        resetReportState()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard isStarted else { return }
        guard central.state == .poweredOn else {
            if central.state != .unknown && central.state != .resetting {
                rmDebug("📡 Direct GATT HID unavailable (state=\(central.state.rawValue))")
            }
            return
        }
        findConnectedRemote()
    }

    private func findConnectedRemote() {
        guard isStarted, let central else { return }
        if let remote = central.retrievePeripherals(withIdentifiers: knownPeripheralIdentifiers).first {
            rmDebug("📡 Direct GATT HID retrieved system peripheral identifier \(remote.identifier.uuidString)")
            use(remote)
            return
        }

        let connected = central.retrieveConnectedPeripherals(withServices: [hidServiceUUID])
        if let remote = connected.first(where: { Self.isRemoteName($0.name ?? "") }) {
            use(remote)
            return
        }

        let identifierDetail = knownPeripheralIdentifiers.first?.uuidString ?? "none"
        rmDebug("📡 Direct GATT HID identifier \(identifierDetail) not retrievable; scanning")
        guard !central.isScanning else { return }
        central.scanForPeripherals(
            withServices: [hidServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        scheduleRetry()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard isStarted else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard Self.isRemoteName(peripheral.name ?? advertisedName ?? "") else { return }
        central.stopScan()
        use(peripheral)
    }

    private func use(_ remote: CBPeripheral) {
        retryTimer?.invalidate()
        retryTimer = nil
        central?.stopScan()
        remember(remote.identifier)
        if peripheral?.identifier == remote.identifier {
            if remote.state == .connecting || (remote.state == .connected && hasConfiguredReports) {
                return
            }
            if remote.state == .connected {
                // A previous service discovery came back empty. Re-drive it instead of
                // abandoning the attached remote.
                rmDebug("📡 Direct GATT HID re-discovering services on attached remote")
                resetReportState()
                remote.delegate = self
                remote.discoverServices(nil)
                return
            }
        }
        peripheral = remote
        remote.delegate = self
        resetReportState()

        // Apple documents that a peripheral returned as system-connected still needs a local
        // CoreBluetooth connection before this app may discover and use its services.
        rmDebug("📡 Direct GATT HID attaching to \(remote.name ?? remote.identifier.uuidString)")
        central?.connect(remote, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard isStarted, self.peripheral?.identifier == peripheral.identifier else { return }
        rmDebug("📡 Direct GATT HID attached; discovering services")
        peripheral.delegate = self
        // Discover every service so the log shows whether macOS exposes HID (0x1812) at all.
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        rmDebug("📡 Direct GATT HID connection failed: \(error?.localizedDescription ?? "unknown")")
        self.peripheral = nil
        scheduleRetry()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        rmDebug("📡 Direct GATT HID disconnected: \(error?.localizedDescription ?? "no error")")
        self.peripheral = nil
        resetReportState()
        serviceDiscoveryFailures = 0
        scheduleRetry()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        let discovered = (peripheral.services ?? []).map(\.uuid.uuidString).joined(separator: ", ")
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == hidServiceUUID }) else {
            serviceDiscoveryFailures += 1
            guard serviceDiscoveryFailures < serviceDiscoveryFailureLimit else {
                rmDebug("📡 Direct GATT HID unavailable after \(serviceDiscoveryFailures) attempts; macOS hides the HID service from apps. Relying on the IOHID path.")
                return
            }
            rmDebug("📡 Direct GATT HID service unavailable: \(error?.localizedDescription ?? "missing"); visible services=[\(discovered)]")
            scheduleRetry()
            return
        }
        serviceDiscoveryFailures = 0
        rmDebug("📡 Direct GATT HID service found; visible services=[\(discovered)]")
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard self.peripheral?.identifier == peripheral.identifier,
              service.uuid == hidServiceUUID else { return }
        guard error == nil else {
            rmDebug("📡 Direct GATT HID characteristic discovery failed: \(error!.localizedDescription)")
            return
        }

        reportCharacteristics = (service.characteristics ?? []).filter {
            $0.uuid == reportCharacteristicUUID
        }
        pendingReferences = Set(reportCharacteristics.map(ObjectIdentifier.init))
        rmDebug("📡 Direct GATT HID discovered \(reportCharacteristics.count) report characteristic(s)")

        guard !reportCharacteristics.isEmpty else { return }
        for characteristic in reportCharacteristics {
            peripheral.discoverDescriptors(for: characteristic)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverDescriptorsFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let key = ObjectIdentifier(characteristic)
        guard pendingReferences.contains(key) else { return }
        guard error == nil,
              let descriptor = characteristic.descriptors?.first(where: {
                  $0.uuid == reportReferenceUUID
              }) else {
            pendingReferences.remove(key)
            configureReportsIfReady(on: peripheral)
            return
        }
        peripheral.readValue(for: descriptor)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor descriptor: CBDescriptor,
        error: Error?
    ) {
        guard descriptor.uuid == reportReferenceUUID,
              let characteristic = descriptor.characteristic else { return }
        let key = ObjectIdentifier(characteristic)
        guard pendingReferences.contains(key) else { return }

        if error == nil, let reference = Self.reportReference(from: descriptor.value) {
            reportReferences[key] = ReportReference(id: reference.id, type: reference.type)
            rmDebug(String(
                format: "📡 Direct GATT HID report reference id=0x%02X type=%u properties=0x%X",
                reference.id,
                reference.type,
                characteristic.properties.rawValue
            ))
        } else {
            rmDebug("📡 Direct GATT HID report reference unreadable: \(error?.localizedDescription ?? "invalid value")")
        }
        pendingReferences.remove(key)
        configureReportsIfReady(on: peripheral)
    }

    private func configureReportsIfReady(on peripheral: CBPeripheral) {
        guard pendingReferences.isEmpty, !hasConfiguredReports else { return }
        hasConfiguredReports = true
        let inputs = reportCharacteristics.filter {
            reportReferences[ObjectIdentifier($0)]?.type == inputReportType
                && ($0.properties.contains(.notify) || $0.properties.contains(.indicate))
        }
        pendingNotifications = Set(inputs.map(ObjectIdentifier.init))
        rmDebug("📡 Direct GATT HID enabling \(inputs.count) input notification(s)")
        for characteristic in inputs {
            peripheral.setNotifyValue(true, for: characteristic)
        }
        if inputs.isEmpty {
            writeInputEnable(on: peripheral)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let key = ObjectIdentifier(characteristic)
        guard pendingNotifications.contains(key) else { return }
        if let error {
            rmDebug("📡 Direct GATT HID notification failed: \(error.localizedDescription)")
        }
        pendingNotifications.remove(key)
        if pendingNotifications.isEmpty {
            writeInputEnable(on: peripheral)
        }
    }

    private func writeInputEnable(on peripheral: CBPeripheral) {
        let controls = reportCharacteristics.filter { characteristic in
            guard let reference = reportReferences[ObjectIdentifier(characteristic)],
                  reference.type != inputReportType else { return false }
            return characteristic.properties.contains(.write)
                || characteristic.properties.contains(.writeWithoutResponse)
        }
        rmDebug("📡 Direct GATT HID writing 0xAF to \(controls.count) control report(s)")
        for characteristic in controls {
            let writeType: CBCharacteristicWriteType = characteristic.properties.contains(.write)
                ? .withResponse
                : .withoutResponse
            peripheral.writeValue(Data([0xAF]), for: characteristic, type: writeType)
            if writeType == .withoutResponse,
               let reference = reportReferences[ObjectIdentifier(characteristic)] {
                rmDebug(String(
                    format: "📡 Direct GATT HID input-enable queued id=0x%02X without response",
                    reference.id
                ))
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let reference = reportReferences[ObjectIdentifier(characteristic)] else { return }
        if let error {
            rmDebug(String(
                format: "📡 Direct GATT HID input-enable failed id=0x%02X: %@",
                reference.id,
                error.localizedDescription
            ))
        } else {
            rmDebug(String(
                format: "📡 Direct GATT HID input enabled id=0x%02X",
                reference.id
            ))
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil,
              let reference = reportReferences[ObjectIdentifier(characteristic)],
              reference.type == inputReportType,
              reference.id == microphoneReportID,
              let data = characteristic.value,
              !data.isEmpty else { return }

        audioReportCount &+= 1
        if audioReportCount == 1 || audioReportCount % 50 == 0 {
            let preview = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            rmDebug("🎙 Direct GATT audio report: count=\(audioReportCount) id=0xFA length=\(data.count) preview=\(preview)")
        }
        microphoneBridgeManager?.handleDirectHIDAudioReport(
            reportID: UInt32(reference.id),
            data: data
        )
    }

    private func resetReportState() {
        reportCharacteristics.removeAll()
        reportReferences.removeAll()
        pendingReferences.removeAll()
        pendingNotifications.removeAll()
        hasConfiguredReports = false
        audioReportCount = 0
    }

    private func scheduleRetry() {
        guard isStarted, retryTimer == nil else { return }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.retryTimer = nil
                self.findConnectedRemote()
            }
        }
    }

    private func remember(_ identifier: UUID) {
        guard !knownPeripheralIdentifiers.contains(identifier) else { return }
        knownPeripheralIdentifiers.insert(identifier, at: 0)
        if knownPeripheralIdentifiers.count > 8 {
            knownPeripheralIdentifiers.removeLast(knownPeripheralIdentifiers.count - 8)
        }
        UserDefaults.standard.set(
            knownPeripheralIdentifiers.map(\.uuidString),
            forKey: savedIdentifiersKey
        )
    }

    nonisolated static func reportReference(from value: Any?) -> (id: UInt8, type: UInt8)? {
        let bytes: [UInt8]
        if let data = value as? Data {
            bytes = Array(data)
        } else if let array = value as? [UInt8] {
            bytes = array
        } else if let numbers = value as? [NSNumber] {
            bytes = numbers.map(\.uint8Value)
        } else {
            return nil
        }
        guard bytes.count >= 2 else { return nil }
        return (bytes[0], bytes[1])
    }

    nonisolated static func peripheralIdentifier(from value: Any?) -> UUID? {
        if let uuid = value as? UUID {
            return uuid
        }
        if let uuid = value as? NSUUID {
            return uuid as UUID
        }
        if let string = value as? String {
            return UUID(uuidString: string)
        }
        return nil
    }

    private nonisolated static func isRemoteName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.contains("remote")
            || normalized.contains("siri")
            || normalized.contains("apple tv")
    }
}
