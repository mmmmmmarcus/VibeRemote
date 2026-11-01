//
//  RemoteBatteryReader.swift
//  VibeRemote
//
//  Reads Siri Remote battery level from macOS Bluetooth metadata, with a
//  CoreBluetooth Battery Service fallback when system_profiler omits it.
//

@preconcurrency import CoreBluetooth
import Darwin
import Foundation

@MainActor
final class RemoteBatteryReader: NSObject,
    @preconcurrency CBCentralManagerDelegate,
    @preconcurrency CBPeripheralDelegate {
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func store(_ value: Data) {
            lock.lock()
            data = value
            lock.unlock()
        }

        func load() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private let batteryServiceUUID = CBUUID(string: "180F")
    private let batteryLevelUUID = CBUUID(string: "2A19")
    private let profilerWaitQueue = DispatchQueue(
        label: "com.viberemote.battery.system-profiler.wait",
        qos: .utility
    )
    private let profilerIOQueue = DispatchQueue(
        label: "com.viberemote.battery.system-profiler.io",
        qos: .utility,
        attributes: .concurrent
    )
    private let profilerTimeout: TimeInterval = 10
    private let bluetoothTimeout: TimeInterval = 20

    private var centralManager: CBCentralManager?
    private var activePeripheral: CBPeripheral?
    private var activeRequestID: UUID?
    private var profilerProcess: Process?
    private var pendingCompletion: (@MainActor (Int?) -> Void)?
    private var timeoutTimer: Timer?

    /// Reads a battery percentage and always calls `completion` on the main thread.
    /// Starting a new read cancels and completes any older read with `nil`.
    func readBatteryPercent(completion: @escaping @MainActor (Int?) -> Void) {
        cancelCurrentRequest(deliverCompletion: true)
        let requestID = UUID()
        activeRequestID = requestID
        pendingCompletion = completion
        startSystemProfiler(requestID: requestID)
    }

    /// Cancels an in-flight profiler/Bluetooth lookup and completes it with `nil`.
    /// This is used when the remote disconnects so menu state cannot remain "Loading".
    func cancel() {
        cancelCurrentRequest(deliverCompletion: true)
    }

    private func startSystemProfiler(requestID: UUID) {
        let process = Process()
        let output = Pipe()
        let outputData = DataBox()
        let drainGroup = DispatchGroup()
        let terminated = DispatchSemaphore(value: 0)

        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "SPBluetoothDataType"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in
            terminated.signal()
        }

        // Drain concurrently with process execution. system_profiler output is often much
        // larger than a pipe buffer, so waiting for exit before reading can deadlock.
        drainGroup.enter()
        profilerIOQueue.async {
            outputData.store(output.fileHandleForReading.readDataToEndOfFile())
            drainGroup.leave()
        }

        do {
            try process.run()
            output.fileHandleForWriting.closeFile()
            profilerProcess = process
        } catch {
            output.fileHandleForWriting.closeFile()
            rmDebug("🔋 system_profiler launch failed: \(error.localizedDescription)")
            readCoreBluetoothBatteryPercent(requestID: requestID)
            return
        }

        let profilerTimeout = self.profilerTimeout
        profilerWaitQueue.async { [weak self] in
            let timedOut = terminated.wait(timeout: .now() + profilerTimeout) == .timedOut
            if timedOut, process.isRunning {
                process.terminate()
                if terminated.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    _ = terminated.wait(timeout: .now() + 1)
                }
            }

            _ = drainGroup.wait(timeout: .now() + 2)
            let data = outputData.load()
            let status: Int32? = process.isRunning ? nil : process.terminationStatus

            DispatchQueue.main.async { [weak self] in
                self?.systemProfilerFinished(
                    requestID: requestID,
                    process: process,
                    data: data,
                    terminationStatus: status,
                    timedOut: timedOut
                )
            }
        }
    }

    private func systemProfilerFinished(
        requestID: UUID,
        process: Process,
        data: Data,
        terminationStatus: Int32?,
        timedOut: Bool
    ) {
        guard activeRequestID == requestID else { return }
        if profilerProcess === process {
            profilerProcess = nil
        }

        if !timedOut,
           terminationStatus == 0,
           let percent = Self.batteryPercent(fromSystemProfilerJSON: data) {
            rmDebug("🔋 Siri Remote battery read via system_profiler: \(percent)%")
            finish(percent, requestID: requestID)
            return
        }

        if timedOut {
            rmDebug("🔋 system_profiler battery read timed out; trying CoreBluetooth")
        } else if terminationStatus != 0 {
            rmDebug("🔋 system_profiler battery read failed (status=\(terminationStatus.map(String.init) ?? "unknown")); trying CoreBluetooth")
        }
        readCoreBluetoothBatteryPercent(requestID: requestID)
    }

    private func readCoreBluetoothBatteryPercent(requestID: UUID) {
        guard activeRequestID == requestID, pendingCompletion != nil else { return }

        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: bluetoothTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeRequestID == requestID else { return }
                rmDebug("🔋 Siri Remote CoreBluetooth battery read timed out")
                self.finish(nil, requestID: requestID)
            }
        }

        if centralManager == nil {
            centralManager = CBCentralManager(
                delegate: self,
                queue: nil,
                options: [CBCentralManagerOptionShowPowerAlertKey: false]
            )
            return
        }

        guard let centralManager else {
            finish(nil, requestID: requestID)
            return
        }
        switch centralManager.state {
        case .poweredOn:
            startBluetoothLookup()
        case .unknown, .resetting:
            break
        default:
            finish(nil, requestID: requestID)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let requestID = activeRequestID, pendingCompletion != nil else { return }
        if central.state == .poweredOn {
            startBluetoothLookup()
        } else if central.state != .unknown && central.state != .resetting {
            rmDebug("🔋 CoreBluetooth unavailable for battery read (state=\(central.state.rawValue))")
            finish(nil, requestID: requestID)
        }
    }

    private func startBluetoothLookup() {
        guard let centralManager, pendingCompletion != nil, activePeripheral == nil else { return }

        let connected = centralManager.retrieveConnectedPeripherals(withServices: [batteryServiceUUID])
        if let remote = connected.first(where: { Self.isRemoteName($0.name ?? "") }) {
            connectOrDiscover(remote)
            return
        }

        guard !centralManager.isScanning else { return }
        centralManager.scanForPeripherals(
            withServices: [batteryServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard pendingCompletion != nil else { return }
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard Self.isRemoteName(peripheral.name ?? advertisedName ?? "") else { return }
        central.stopScan()
        connectOrDiscover(peripheral)
    }

    private func connectOrDiscover(_ peripheral: CBPeripheral) {
        guard let centralManager, pendingCompletion != nil else { return }
        centralManager.stopScan()
        activePeripheral = peripheral
        peripheral.delegate = self

        if peripheral.state == .connected {
            peripheral.discoverServices([batteryServiceUUID])
        } else {
            centralManager.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard pendingCompletion != nil, activePeripheral?.identifier == peripheral.identifier else { return }
        peripheral.delegate = self
        peripheral.discoverServices([batteryServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard activePeripheral?.identifier == peripheral.identifier,
              let requestID = activeRequestID else { return }
        rmDebug("🔋 Siri Remote battery connect failed: \(error?.localizedDescription ?? "unknown")")
        finish(nil, requestID: requestID)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard pendingCompletion != nil,
              activePeripheral?.identifier == peripheral.identifier,
              let requestID = activeRequestID else { return }
        rmDebug("🔋 Siri Remote disconnected during battery read: \(error?.localizedDescription ?? "no error")")
        finish(nil, requestID: requestID)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard pendingCompletion != nil,
              activePeripheral?.identifier == peripheral.identifier,
              let requestID = activeRequestID else { return }
        guard error == nil, let services = peripheral.services else {
            rmDebug("🔋 Siri Remote battery services unavailable: \(error?.localizedDescription ?? "missing")")
            finish(nil, requestID: requestID)
            return
        }

        guard let batteryService = services.first(where: { $0.uuid == batteryServiceUUID }) else {
            finish(nil, requestID: requestID)
            return
        }
        peripheral.discoverCharacteristics([batteryLevelUUID], for: batteryService)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard pendingCompletion != nil,
              activePeripheral?.identifier == peripheral.identifier,
              let requestID = activeRequestID else { return }
        guard error == nil,
              let characteristic = service.characteristics?.first(where: { $0.uuid == batteryLevelUUID }) else {
            rmDebug("🔋 Siri Remote battery characteristic unavailable: \(error?.localizedDescription ?? "missing")")
            finish(nil, requestID: requestID)
            return
        }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard pendingCompletion != nil,
              activePeripheral?.identifier == peripheral.identifier,
              let requestID = activeRequestID else { return }
        guard error == nil,
              characteristic.uuid == batteryLevelUUID,
              let value = characteristic.value,
              let firstByte = value.first else {
            rmDebug("🔋 Siri Remote battery value unavailable: \(error?.localizedDescription ?? "missing")")
            finish(nil, requestID: requestID)
            return
        }

        let percent = Int(firstByte)
        rmDebug("🔋 Siri Remote battery read via BLE: \(percent)%")
        finish((0...100).contains(percent) ? percent : nil, requestID: requestID)
    }

    private func finish(_ percent: Int?, requestID: UUID) {
        guard activeRequestID == requestID else { return }
        let completion = pendingCompletion
        cancelCurrentRequest(deliverCompletion: false)
        completion?(percent)
    }

    private func cancelCurrentRequest(deliverCompletion: Bool) {
        timeoutTimer?.invalidate()
        timeoutTimer = nil

        if let process = profilerProcess, process.isRunning {
            process.terminate()
        }
        profilerProcess = nil

        centralManager?.stopScan()
        if let activePeripheral {
            activePeripheral.delegate = nil
            if activePeripheral.state != .disconnected {
                centralManager?.cancelPeripheralConnection(activePeripheral)
            }
        }
        activePeripheral = nil

        let completion = deliverCompletion ? pendingCompletion : nil
        pendingCompletion = nil
        activeRequestID = nil
        completion?(nil)
    }

    /// Internal parser entry point for tests and the profiler process result.
    nonisolated static func batteryPercent(fromSystemProfilerJSON data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }
        return batteryPercent(fromSystemProfilerObject: object)
    }

    /// Internal object-level parser entry point for focused fixtures in tests.
    nonisolated static func batteryPercent(fromSystemProfilerObject object: Any) -> Int? {
        findRemoteBatteryPercent(in: object)
    }

    private nonisolated static func findRemoteBatteryPercent(in object: Any, inRemoteContext: Bool = false) -> Int? {
        if let array = object as? [Any] {
            for value in array {
                if let percent = findRemoteBatteryPercent(in: value, inRemoteContext: inRemoteContext) {
                    return percent
                }
            }
            return nil
        }

        guard let dictionary = object as? [String: Any] else { return nil }
        let remoteContext = inRemoteContext
            || dictionary.keys.contains(where: isRemoteName)
            || dictionary.values.contains { value in
                guard let string = value as? String else { return false }
                return isRemoteName(string)
            }
        if remoteContext, let percent = batteryPercent(in: dictionary) {
            return percent
        }

        for (key, value) in dictionary {
            if let percent = findRemoteBatteryPercent(in: value, inRemoteContext: remoteContext || isRemoteName(key)) {
                return percent
            }
        }
        return nil
    }

    private nonisolated static func isRemoteName(_ value: String) -> Bool {
        let lowercased = value.lowercased()
        return lowercased.contains("siri remote")
            || lowercased.contains("apple tv remote")
            || lowercased.contains(" remote")
            || lowercased.hasSuffix("remote")
    }

    private nonisolated static func batteryPercent(in dictionary: [String: Any]) -> Int? {
        for (key, value) in dictionary where key.lowercased().contains("battery") {
            if let percent = numericPercent(from: value) {
                return percent
            }
        }
        return nil
    }

    private nonisolated static func numericPercent(from value: Any) -> Int? {
        if let value = value as? Int, (0...100).contains(value) {
            return value
        }
        if let value = value as? NSNumber {
            let percent = value.intValue
            return (0...100).contains(percent) ? percent : nil
        }
        if let value = value as? String {
            let digits = value.filter { $0.isNumber }
            if let percent = Int(digits), (0...100).contains(percent) {
                return percent
            }
        }
        return nil
    }

}
