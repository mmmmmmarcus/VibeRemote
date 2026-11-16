import AppKit
@preconcurrency import CoreBluetooth
import SwiftUI

/// One connection owner for Soundcore Work. CoreBluetooth and all transport state live
/// on the main actor; view construction never requests Bluetooth or starts a microphone.
@MainActor
final class SoundcoreManager: NSObject, ObservableObject, @preconcurrency CBCentralManagerDelegate,
                              @preconcurrency CBPeripheralDelegate {
    static let shared = SoundcoreManager()
    struct Device: Identifiable {
        let id: UUID
        let name: String
        let rssi: Int
        let peripheral: CBPeripheral
        let address: Data?
    }
    @Published private(set) var devices: [Device] = []
    @Published private(set) var status = "Not connected"
    @Published private(set) var scanning = false
    @Published private(set) var connecting = false
    @Published private(set) var ready = false
    @Published private(set) var info: SoundcoreProtocol.DeviceInfo?
    @Published private(set) var microphoneActive = false
    @Published private(set) var level: Float = 0
    @Published private(set) var frameCount = 0
    @Published private(set) var error: String?
    @Published var useForHotkey = UserDefaults.standard.bool(forKey: "soundcoreDictationInput") {
        didSet { UserDefaults.standard.set(useForHotkey, forKey: "soundcoreDictationInput") }
    }

    private static let rememberedDeviceKey = "soundcoreVerifiedDevice"
    private var reconnect = SoundcoreReconnectPolicy(identity: UserDefaults.standard.data(forKey: SoundcoreManager.rememberedDeviceKey)
        .flatMap { try? JSONDecoder().decode(SoundcoreReconnectPolicy.Identity.self, from: $0) })
    private var reconnectTask: Task<Void, Never>?
    private var automaticScan = false
    private var shuttingDown = false
    private var connectionDevice: Device?
    var canReconnect: Bool { reconnect.identity != nil }
    private var advertisedIDs: [Data: UUID] = [:]
    private var scanAdvertisements = 0
    private var scanPeripherals: Set<UUID> = []
    private var scanMatches = 0
    private var scanNonConnectableMatches = 0
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var parser = SoundcoreProtocol.Parser()
    private var crypto = SoundcoreProtocol.Crypto()
    private var writes: [Data] = []
    private var writing = false
    private var pendingScan = false
    private var connectionGeneration = UUID()
    private var capture: SoundcoreAudioSource?
    private var audioID: UInt32?
    private var headReady = false
    private var liveWindow = SoundcoreProtocol.LiveWindow(discardBefore: 0)
    private var baseline = SoundcoreProtocol.CaptureBaseline()
    private var transport = SoundcoreProtocol.LiveTransport()
    private var preparingAudio = false
    private var stopping = false
    private var lastAudio = Date.distantPast
    private var captureStarted = Date.distantPast
    private var continuityHold = 0
    private var recoveringAudio = false
    private var audioRecoveryTask: Task<Void, Never>?
    private var session = UUID()
    private var scanTimeout: Task<Void, Never>?
    private var connectionTimeout: Task<Void, Never>?
    private var connectionStart: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var audioTimeout: Task<Void, Never>?

    func start() {
        guard reconnect.enabled else { return }
        scheduleReconnect(after: 0)
        if CommandLine.arguments.contains("--verify-soundcore-continuity") {
            Task { await runContinuityCheck() }
        }
    }

    /// Explicit developer verification only: memory-only captures, no ASR or files.
    /// Runs on the installed app's existing connection owner, never a second central.
    private func runContinuityCheck() async {
        let deadline = Date().addingTimeInterval(60)
        while !ready, Date() < deadline, !shuttingDown {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard ready, !shuttingDown else { rmDebug("🎤 Soundcore CONTINUITY failed: not connected"); return }
        let durations: [Double] = CommandLine.arguments.contains("--verify-soundcore-buffer")
            ? [6, 6, 6] : [18, 3, 3, 18, 3, 3, 18, 3, 3, 3, 3, 3]
        for (index, duration) in durations.enumerated() {
            guard ready, !shuttingDown, capture == nil, DictationController.shared.recordingSource == nil else {
                rmDebug("🎤 Soundcore CONTINUITY failed: unavailable hold=\(index + 1)")
                return
            }
            continuityHold = index + 1
            do { _ = try makeCapture(onSamples: { _ in }) }
            catch { rmDebug("🎤 Soundcore CONTINUITY failed: \(error.localizedDescription)"); return }
            let token = session
            rmDebug("🎤 Soundcore CONTINUITY begin hold=\(index + 1) duration=\(duration)")
            try? await Task.sleep(for: .seconds(duration))
            guard !shuttingDown, session == token else {
                rmDebug("🎤 Soundcore CONTINUITY failed: interrupted hold=\(index + 1)")
                return
            }
            endDictation(cancel: false)
            let finishDeadline = Date().addingTimeInterval(4)
            while capture != nil, Date() < finishDeadline, !shuttingDown {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard frameCount > 0, ready else {
                rmDebug("🎤 Soundcore CONTINUITY failed: no audio hold=\(index + 1)")
                return
            }
            rmDebug("🎤 Soundcore CONTINUITY passed hold=\(index + 1) frames=\(frameCount)")
            // Exercise quick release/re-press, unlike the slower manual checks.
            try? await Task.sleep(for: .milliseconds(250))
        }
        rmDebug("🎤 Soundcore CONTINUITY complete holds=\(durations.count)")
    }

    func shutdown() {
        shuttingDown = true
        disconnect()
    }

    func resumeReconnect() {
        reconnect.resume()
        scheduleReconnect(after: 0)
    }

    func stopSearching() {
        reconnect.pause()
        reconnectTask?.cancel()
        stopScan()
    }

    private func scheduleReconnect(after seconds: Int) {
        guard reconnect.enabled, !shuttingDown, !ready, !connecting else { return }
        reconnectTask?.cancel()
        status = "Waiting for Soundcore Work…"
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.reconnect.enabled, !self.shuttingDown else { return }
            self.requestScan(automatically: true)
        }
    }

    func scan() {
        reconnect.resume()
        reconnectTask?.cancel()
        requestScan(automatically: false)
    }

    private func requestScan(automatically: Bool) {
        guard !connecting, !ready, !shuttingDown else { return }
        automaticScan = automatically
        error = nil
        pendingScan = true
        if central == nil {
            status = "Checking Bluetooth…"
            central = CBCentralManager(delegate: self, queue: nil,
                                      options: [CBCentralManagerOptionShowPowerAlertKey: false])
        } else if central?.state == .poweredOn { beginScan() }
        else { updateBluetoothState() }
    }

    private func beginScan() {
        pendingScan = false
        devices = []
        advertisedIDs = [:]
        scanAdvertisements = 0
        scanPeripherals = []
        scanMatches = 0
        scanNonConnectableMatches = 0
        central?.stopScan()
        scanning = true
        status = automaticScan ? "Waiting for Soundcore Work…" : "Searching for Soundcore Work…"
        // macOS can omit D3200 scan responses when filtering by service in the OS.
        // Open scan with the reference software filter; log counts, never unrelated identities.
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: !automaticScan])
        for device in central?.retrieveConnectedPeripherals(withServices: [CBUUID(string: SoundcoreProtocol.service)]) ?? [] {
            add(device, name: device.name ?? "Soundcore Work", rssi: 0)
            if connecting { break }
        }
        guard scanning else { return }
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self else { return }
            self.stopScan()
            self.status = self.devices.isEmpty ? "No Soundcore Work found. Wake it and try again." : "Choose your Soundcore Work"
            self.scheduleReconnect(after: 3)
        }
        rmDebug("🎤 Soundcore scan started active=\(central?.isScanning == true) state=\(central?.state.rawValue ?? -1)")
    }

    func stopScan() {
        if scanning {
            rmDebug("🎤 Soundcore scan ended advertisements=\(scanAdvertisements) peripherals=\(scanPeripherals.count) matches=\(scanMatches) nonConnectableMatches=\(scanNonConnectableMatches) candidates=\(devices.count)")
        }
        pendingScan = false
        central?.stopScan()
        scanTimeout?.cancel()
        scanTimeout = nil
        scanning = false
        if !ready && !connecting { status = devices.isEmpty ? "Not connected" : "Choose your Soundcore Work" }
    }

    func connect(_ device: Device, automatically: Bool = false) {
        guard !connecting, !ready, !shuttingDown else { return }
        if !automatically { reconnect.resume() }
        reconnectTask?.cancel()
        stopScan()
        connectionDevice = device
        error = nil
        info = nil
        connecting = true
        status = "Connecting…"
        connectionGeneration = UUID()
        peripheral = device.peripheral
        device.peripheral.delegate = self
        // Reference _stopScanAndWait: stop scanning and let CoreBluetooth
        // settle before opening GATT. Disconnect invalidates this attempt.
        let generation = connectionGeneration
        connectionStart?.cancel()
        connectionStart = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(3)
            while self.central?.isScanning == true, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, self.connectionGeneration == generation else { return }
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, self.connectionGeneration == generation else { return }
            guard let central = self.central, central.state == .poweredOn, !central.isScanning else {
                self.failConnection("Bluetooth scanning did not stop. Search again and reconnect.")
                return
            }
            rmDebug("🎤 Soundcore opening GATT after scan stopped")
            central.connect(device.peripheral)
            self.armConnectionTimeout()
        }
    }

    private func armConnectionTimeout() {
        let generation = connectionGeneration
        connectionTimeout?.cancel()
        connectionTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, let self, self.connectionGeneration == generation, !self.ready else { return }
            self.failConnection("Soundcore connection timed out. Search again to refresh nearby devices.")
        }
    }

    func disconnect() {
        reconnect.pause()
        reconnectTask?.cancel()
        stopScan()
        endDictation(cancel: true)
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        resetConnection()
        status = "Not connected"
    }

    private func resetConnection() {
        audioRecoveryTask?.cancel()
        audioRecoveryTask = nil
        recoveringAudio = false
        connectionStart?.cancel()
        connectionStart = nil
        connectionTimeout?.cancel()
        connectionGeneration = UUID()
        if DictationController.shared.recordingSource == .soundcore { DictationController.shared.cancel() }
        stopTask?.cancel()
        audioTimeout?.cancel()
        capture = nil
        microphoneActive = false
        level = 0
        audioID = nil
        headReady = false
        stopping = false
        peripheral?.delegate = nil
        peripheral = nil
        connectionDevice = nil
        writer = nil
        parser = SoundcoreProtocol.Parser()
        crypto = SoundcoreProtocol.Crypto()
        transport.finish()
        writes = []
        writing = false
        ready = false
        connecting = false
        info = nil
    }

    private func failConnection(_ message: String) {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        resetConnection()
        devices = []
        error = message
        status = "Connection failed"
        rmDebug("🎤 Soundcore connection failed: \(message)")
        scheduleReconnect(after: reconnect.retryDelay())
    }

    func refresh() { if ready { send(1, 1) } }

    var diagnosticSummary: String {
        """
        Soundcore Work
        Connection: \(status)
        Firmware: \(info?.firmware ?? "Unknown")
        Battery: \(info?.battery.map { "\($0)%" } ?? "Unknown")
        Audio frames: \(frameCount)
        Microphone active: \(microphoneActive)
        Error: \(error ?? "None")
        """
    }

    func testMicrophone() {
        guard capture == nil, DictationController.shared.recordingSource == nil else { return }
        do { _ = try makeCapture(onSamples: { _ in }) }
        catch { self.error = error.localizedDescription; return }
        let token = session
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.session == token else { return }
            self.endDictation(cancel: false)
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) { updateBluetoothState() }
    private func updateBluetoothState() {
        guard let central else { return }
        if central.state == .poweredOn {
            if pendingScan { beginScan() }
            else if !scanning { scheduleReconnect(after: 0) }
            return
        }
        if central.state == .unknown || central.state == .resetting { status = "Checking Bluetooth…"; return }
        reconnectTask?.cancel()
        stopScan()
        resetConnection()
        status = central.state == .unauthorized ? "Allow Bluetooth in System Settings › Privacy & Security."
                                               : "Turn on Bluetooth to connect Soundcore Work."
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning else { return }
        scanAdvertisements += 1
        scanPeripherals.insert(peripheral.identifier)
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
            + Array((advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] ?? [:]).keys)
        let name = SoundcoreProtocol.discoveryName(
            advertised: advertisementData[CBAdvertisementDataLocalNameKey] as? String,
            peripheral: peripheral.name)
        let manufacturer = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()
        guard let match = SoundcoreProtocol.discoveryMatch(name: name, services: services.map(\.uuidString), manufacturer: manufacturer) else { return }
        scanMatches += 1
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        if connectable == false { scanNonConnectableMatches += 1 }
        if !devices.contains(where: { $0.peripheral.identifier == peripheral.identifier }) {
            rmDebug("🎤 Soundcore candidate via=\(match) connectable=\(connectable.map(String.init) ?? "unknown") rssi=\(RSSI.intValue)")
        }
        let address = manufacturer.count >= 6 ? Data(manufacturer.prefix(6)) : nil
        add(peripheral, name: name ?? "Soundcore Work", rssi: RSSI.intValue, address: address, connectable: connectable != false)
    }
    private func add(_ peripheral: CBPeripheral, name: String, rssi: Int, address: Data? = nil, connectable: Bool = true) {
        // CoreBluetooth can expose transient identifiers for one D3200; its advertised
        // six-byte address deduplicates the picker without logging that identifier.
        let id = address.flatMap { advertisedIDs[$0] } ?? peripheral.identifier
        if let address { advertisedIDs[address] = id }
        let device = Device(id: id, name: name, rssi: rssi, peripheral: peripheral, address: address)
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
        else { devices.append(device); rmDebug("🎤 Soundcore discovered rssi=\(rssi)") }
        if automaticScan, connectable, reconnect.enabled,
           reconnect.identity?.matches(peripheralID: peripheral.identifier, address: address) == true {
            rmDebug("🎤 Soundcore automatically reconnecting verified device")
            connect(device, automatically: true)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == self.peripheral else { return }
        status = "Discovering microphone…"
        peripheral.discoverServices([CBUUID(string: SoundcoreProtocol.service)])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        failConnection("Could not connect to Soundcore Work. Keep it awake and close to the Mac.")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        resetConnection()
        status = "Disconnected. Wake Soundcore Work and reconnect."
        rmDebug("🎤 Soundcore disconnected")
        scheduleReconnect(after: 3)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral == self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: SoundcoreProtocol.service) }) else {
            failConnection("This device does not expose the Soundcore Work microphone service.")
            return
        }
        peripheral.discoverCharacteristics([CBUUID(string: SoundcoreProtocol.write), CBUUID(string: SoundcoreProtocol.notify)], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral == self.peripheral else { return }
        guard error == nil,
              let writer = service.characteristics?.first(where: { $0.uuid == CBUUID(string: SoundcoreProtocol.write) }),
              let reader = service.characteristics?.first(where: { $0.uuid == CBUUID(string: SoundcoreProtocol.notify) }),
              writer.properties.contains(.write), reader.properties.contains(.notify) else {
            failConnection("Soundcore microphone characteristics are unavailable on this firmware.")
            return
        }
        self.writer = writer
        peripheral.setNotifyValue(true, for: reader)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral else { return }
        guard error == nil, characteristic.isNotifying else { failConnection("Soundcore notifications could not start."); return }
        status = "Preparing secure microphone…"
        send(1, 1)
        send(0x2E, 1, crypto.publicKey)
    }

    private func send(_ type: UInt8, _ command: UInt8, _ payload: [UInt8] = []) {
        guard writer != nil, let peripheral else { return }
        rmDebug(String(format: "🎤 Soundcore TX type=%d cmd=%d queued=%d uptime=%.3f", type, command, writes.count, ProcessInfo.processInfo.systemUptime))
        let data = SoundcoreProtocol.command(type, command, payload)
        let maximum = peripheral.maximumWriteValueLength(for: .withResponse)
        guard maximum > 0, writes.count < 64 else { failConnection("Soundcore write queue is unavailable."); return }
        for offset in stride(from: 0, to: data.count, by: maximum) {
            writes.append(Data(data[offset..<min(offset + maximum, data.count)]))
        }
        drainWrites()
    }
    private func drainWrites() {
        guard !writing, !writes.isEmpty, let peripheral, let writer else { return }
        writing = true
        peripheral.writeValue(writes.removeFirst(), for: writer, type: .withResponse)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral else { return }
        guard error == nil else { failConnection("Soundcore did not accept a microphone command."); return }
        // Preserve command order, including fragments, without blocking the main actor.
        let generation = connectionGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, self.connectionGeneration == generation else { return }
            self.writing = false
            self.drainWrites()
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral == self.peripheral, characteristic.uuid == CBUUID(string: SoundcoreProtocol.notify) else { return }
        guard error == nil, let data = characteristic.value else { failConnection("Soundcore audio connection was interrupted."); return }
        for packet in parser.append(data) {
            do { try receive(packet) }
            catch { failAudio(error.localizedDescription) }
        }
    }

    private func receive(_ packet: SoundcoreProtocol.Packet) throws {
        let p = packet.payload
        if packet.type != 0x1A || (packet.command != 8 && packet.command != 0x12) {
            rmDebug("🎤 Soundcore RX type=\(packet.type) cmd=\(packet.command) status=\(packet.status) bytes=\(p.count)")
        }
        switch (packet.type, packet.command) {
        case (1, 1):
            guard packet.succeeded, let parsed = SoundcoreProtocol.DeviceInfo(p) else { throw SoundcoreProtocol.Failure.invalidHead }
            info = parsed
            rmDebug("🎤 Soundcore info firmware=\(parsed.firmware) battery=\(parsed.battery ?? -1)")
            updateReady()
        case (1, 3): refresh()
        case (0x2E, 1):
            guard packet.succeeded else { throw SoundcoreProtocol.Failure.handshake }
            try crypto.handshake(p)
            updateReady()
        case (0x1A, 6):
            guard capture != nil, !preparingAudio, !stopping, p.count >= 4 else { return }
            requestAudio(SoundcoreProtocol.u32(p, 0))
        case (0x18, 0x82):
            if recoveringAudio, p.first == 0 || p.first == 2 {
                completeAudioRecovery()
                return
            }
            guard capture != nil, let state = p.first else { return }
            rmDebug("🎤 Soundcore control state=\(state) detail=\(p.count > 1 ? Int(p[1]) : -1)")
            if state == 1, !stopping, audioID == nil { send(0x1B, 0x0E, [0, 0]) }
            else if state == 0 || state == 2 { endDictation(cancel: false) }
            else if state == 255 { throw SoundcoreProtocol.Failure.invalidHead }
        case (0x1B, 0x0E), (0x1A, 0x0E):
            guard capture != nil, !stopping, audioID == nil, p.count >= 2 else { return }
            let count = Int(p[0]) | Int(p[1]) << 8
            let end = 2 + count * (packet.type == 0x1B ? 12 : 8)
            guard packet.succeeded, p.count >= end + 8 else { throw SoundcoreProtocol.Failure.invalidHead }
            rmDebug("🎤 Soundcore list preparing=\(preparingAudio) entries=\(count) currentPresent=\(SoundcoreProtocol.u32(p, end) != 0)")
            if preparingAudio {
                // A pause/resume can reuse a file ID. Snapshot its existing frame count
                // before enabling the mic so old speech is never submitted again.
                guard let current = try baseline.append(p, withEndTime: packet.type == 0x1B) else {
                    let page = baseline.page
                    rmDebug("🎤 Soundcore microphone boundary needs metadata page=\(page)")
                    send(0x1B, 0x0E, [UInt8(truncatingIfNeeded: page), UInt8(truncatingIfNeeded: page >> 8)])
                    return
                }
                // The firmware keeps the transfer open when its microphone is
                // paused. Reattach BEFORE resuming, so the first packets of the
                // next sentence are accepted without a second file-head request.
                if current != 0, transport.canResume(current) {
                    audioID = current
                    liveWindow = SoundcoreProtocol.LiveWindow(discardBefore: baseline.frames[current] ?? 0)
                    headReady = true
                    rmDebug("🎤 Soundcore resuming verified transfer boundary=\(liveWindow.discardBefore)")
                }
                preparingAudio = false
                send(0x18, 0x82, [1])
            } else {
                // Only the current live ID, never a historical entry.
                requestAudio(SoundcoreProtocol.u32(p, end))
            }
        case (0x1A, 7), (0x1B, 7):
            guard let expectedID = transport.fileID else { return }
            guard packet.succeeded else { throw SoundcoreProtocol.Failure.invalidHead }
            if p.count >= 87 {
                rmDebug("🎤 Soundcore head matchesRequested=\(SoundcoreProtocol.u32(p, 0) == expectedID) error=\(p[86]) size=\(SoundcoreProtocol.u32(p, 4))")
            }
            try crypto.openHead(p, expectedID: expectedID)
            transport.confirm(expectedID)
            if audioID == expectedID, capture != nil { headReady = true }
        case (0x1A, 8), (0x1A, 0x12), (0x1B, 8), (0x1B, 0x12):
            guard let capture, headReady else { return }
            for slice in try SoundcoreProtocol.Slice.parse(p) {
                if !liveWindow.started || slice.sequence > liveWindow.next {
                    rmDebug("🎤 Soundcore sequence expected=\(liveWindow.next) received=\(slice.sequence) baseline=\(liveWindow.discardBefore)")
                }
                guard try liveWindow.accepts(slice.sequence) else { continue }
                lastAudio = Date()
                level = try capture.append(crypto.decrypt(slice))
                frameCount += 1
                if !stopping { status = "Microphone on" }
            }
        case (0x1A, 0x0A), (0x1B, 0x0A):
            transport.finish()
            headReady = false
            if stopping { finishAudio() }
        default: break
        }
    }

    private func updateReady() {
        guard info != nil, crypto.sessionKey != nil, !recoveringAudio else { return }
        if let device = connectionDevice {
            reconnect.verified(peripheralID: device.peripheral.identifier, address: device.address)
            if let data = try? JSONEncoder().encode(reconnect.identity) {
                UserDefaults.standard.set(data, forKey: Self.rememberedDeviceKey)
            }
        }
        reconnectTask?.cancel()
        ready = true
        connecting = false
        connectionTimeout?.cancel()
        status = "Connected"
        rmDebug("🎤 Soundcore microphone connection ready")
    }

    func makeCapture(onSamples: @escaping @Sendable ([Float]) -> Void) throws -> SoundcoreAudioSource {
        guard ready, capture == nil else {
            throw NSError(domain: "Soundcore", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Connect Soundcore Work in Settings before using it as your microphone."])
        }
        let source = try SoundcoreAudioSource(onSamples: onSamples)
        capture = source
        error = nil
        session = UUID()
        audioID = nil
        liveWindow = SoundcoreProtocol.LiveWindow(discardBefore: 0)
        headReady = false
        stopping = false
        frameCount = 0
        level = 0
        microphoneActive = true
        status = "Starting microphone…"
        lastAudio = Date()
        captureStarted = lastAudio
        preparingAudio = true
        baseline = SoundcoreProtocol.CaptureBaseline()
        send(0x1B, 0x0E, [0, 0])
        let token = session
        audioTimeout = Task { [weak self] in
            let start = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.session == token, self.capture != nil else { return }
                if self.stopping { return }
                if Date().timeIntervalSince(self.lastAudio) > 8 {
                    self.failAudio("Soundcore stopped sending audio. Reconnecting; please repeat your last phrase.")
                    return
                }
                if Date().timeIntervalSince(start) > 115 { self.endDictation(cancel: false); return }
            }
        }
        rmDebug("🎤 Soundcore microphone requested")
        return source
    }

    private func requestAudio(_ id: UInt32) {
        guard id != 0, audioID != id else { return }
        headReady = false
        audioID = id
        liveWindow = SoundcoreProtocol.LiveWindow(discardBefore: baseline.frames[id] ?? 0)
        if transport.canResume(id) {
            headReady = true
            rmDebug("🎤 Soundcore reusing verified transfer boundary=\(liveWindow.discardBefore)")
            return
        }
        transport.request(id)
        // A new transfer starts at the beginning of the CURRENT recording.
        // Buffered mode delivers packets captured before the request, then keeps
        // streaming while the mic is on. The pre-hold boundary rejects older
        // speech; no archive selection or fallback to another recording is used.
        let token = session
        if CommandLine.arguments.contains("--verify-soundcore-buffer") {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.session == token, self.capture != nil, !self.stopping else { return }
                rmDebug("🎤 Soundcore BUFFER delayed current-hold request boundary=\(self.liveWindow.discardBefore)")
                self.send(0x1A, 7, SoundcoreProtocol.littleEndian(0) + SoundcoreProtocol.littleEndian(id) + [0])
            }
        } else {
            send(0x1A, 7, SoundcoreProtocol.littleEndian(0) + SoundcoreProtocol.littleEndian(id) + [0])
        }
    }

    func endDictation(cancel: Bool) {
        guard capture != nil else { return }
        if !stopping && !preparingAudio { send(0x18, 0x82, [2]) }
        stopping = true
        audioTimeout?.cancel()
        if cancel {
            if DictationController.shared.recordingSource == .soundcore { DictationController.shared.cancel() }
            clearAudio()
            return
        }
        guard stopTask == nil else { return }
        status = "Finishing voice input…"
        let token = session
        stopTask = Task { [weak self] in
            let deadline = Date().addingTimeInterval(2)
            repeat {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, self.session == token, self.capture != nil else { return }
                if Date().timeIntervalSince(self.lastAudio) >= 0.4 { break }
            } while Date() < deadline
            guard let self, self.session == token else { return }
            self.finishAudio()
        }
    }
    private func finishAudio() {
        guard capture != nil else { return }
        rmDebug("🎤 Soundcore audio complete frames=\(frameCount)")
        if SoundcoreAudioHealth.needsRecovery(frames: frameCount, elapsed: Date().timeIntervalSince(captureStarted)) {
            recoverAudio("Soundcore stopped sending audio. Reconnecting; please repeat your last phrase.")
            return
        }
        if DictationController.shared.recordingSource == .soundcore { DictationController.shared.end() }
        else if let capture {
            let audio = capture.stop()
            rmDebug("🎤 Soundcore local test seconds=\(audio.duration) rms=\(audio.rms)")
            if audio.rms <= 0.0001, frameCount > 0 {
                error = "Audio arrived, but no sound was detected. Speak near the microphone and test again."
            }
        }
        clearAudio()
    }
    private func clearAudio() {
        preparingAudio = false
        stopTask?.cancel()
        stopTask = nil
        audioTimeout?.cancel()
        capture = nil
        audioID = nil
        headReady = false
        microphoneActive = false
        level = 0
        stopping = false
        session = UUID()
        status = ready ? "Connected" : "Not connected"
    }
    private func failAudio(_ message: String) {
        if !ready { failConnection(message); return }
        recoverAudio(message)
    }

    private func recoverAudio(_ message: String) {
        guard !recoveringAudio, !shuttingDown else { return }
        recoveringAudio = true
        // Make the unhealthy connection unavailable before cancelling this hold.
        // Recovery never reopens capture or replays speech from the failed hold.
        ready = false
        let pauseNeeded = stopping || preparingAudio
        endDictation(cancel: true)
        if pauseNeeded { send(0x18, 0x82, [2]) }
        error = message
        connecting = true
        status = "Recovering microphone…"
        rmDebug("🎤 Soundcore audio recovery: \(message)")
        let generation = connectionGeneration
        audioRecoveryTask?.cancel()
        audioRecoveryTask = Task { [weak self] in
            // Normally the pause acknowledgement completes recovery. Bound the
            // wait so a failed control channel cannot strand the connection.
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.connectionGeneration == generation else { return }
            self.completeAudioRecovery()
        }
    }

    private func completeAudioRecovery() {
        guard recoveringAudio else { return }
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        resetConnection()
        devices = []
        status = "Microphone unavailable"
        scheduleReconnect(after: reconnect.retryDelay())
    }
}

struct SoundcorePane: View {
    @ObservedObject private var microphone = SoundcoreManager.shared
    var body: some View {
        SettingsPane(title: "Soundcore Work") {
            Section {
                SettingsRow(title: "Connection", statusDot: microphone.ready ? .green : .gray) {
                    Text(microphone.status).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                if let info = microphone.info {
                    if let battery = info.battery { LabeledContent("Battery", value: "\(battery)%") }
                    if let battery = info.caseBattery { LabeledContent("Case Battery", value: "\(battery)%") }
                }
                if microphone.ready || microphone.connecting {
                    Button("Disconnect") { microphone.disconnect() }
                } else {
                    Button(microphone.scanning ? "Stop Searching" : "Find Soundcore Work") {
                        if microphone.scanning { microphone.stopSearching() } else { microphone.scan() }
                    }
                    if microphone.canReconnect && !microphone.scanning {
                        Button("Reconnect") { microphone.resumeReconnect() }
                    }
                    ForEach(microphone.devices) { device in
                        SettingsRow(title: device.name, subtitle: device.rssi == 0 ? "Connected to this Mac" : "Nearby · \(device.rssi) dBm") { Button("Connect") { microphone.connect(device) } }
                    }
                }
            } footer: {
                Text("After connecting once, vvhisper reconnects when Soundcore Work is nearby and available. Disconnect pauses automatic reconnect until you choose Reconnect or reopen vvhisper. Keep the phone Bluetooth connection off; its app pairing can stay intact.")
            }
            if let error = microphone.error {
                Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
    }
}

struct SoundcoreDiagnosticsSection: View {
    @ObservedObject private var microphone = SoundcoreManager.shared
    var body: some View {
            Section {
                LabeledContent("Connection", value: microphone.status)
                if let info = microphone.info { LabeledContent("Firmware", value: info.firmware) }
                Button("Test Microphone for 8 Seconds") { microphone.testMicrophone() }
                    .disabled(!microphone.ready || microphone.microphoneActive)
                if microphone.frameCount > 0 {
                    LabeledContent("Audio Received", value: String(format: "%.1f seconds", Double(microphone.frameCount) * 0.02))
                }
                if microphone.microphoneActive {
                    ProgressView(value: Double(min(1, max(0, microphone.level * 10))))
                        .accessibilityLabel("Microphone level")
                    Button("Cancel Voice Input") { microphone.endDictation(cancel: true) }
                }
            } header: { Text("Soundcore Work") } footer: {
                Text("Audio stays in memory in vvhisper; Soundcore’s firmware may retain a recording on the device.")
            }
            if let error = microphone.error {
                Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
    }
}
