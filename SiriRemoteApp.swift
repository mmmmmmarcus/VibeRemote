//
//  SiriRemoteApp.swift
//  VibeRemote
//
//  Menu bar application for controlling Mac with Siri Remote
//

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import IOBluetooth

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    
    private var statusItem: NSStatusItem!
    private var menuBarManager: MenuBarManager!
    private var microphoneBridgeManager: MicrophoneBridgeManager!
    private var bluetoothAccessManager: BluetoothAccessManager!
    private var remoteHIDChannel: RemoteHIDChannel?
    private var remoteDetector: RemoteDetector?
    private var remoteInputHandler: RemoteInputHandler?
    private var mediaKeyInterceptor: MediaKeyInterceptor?
    private var consumedRemoteMediaButtons: Set<String> = []
    private let advancedMenu = AdvancedMenuController()
    private var microphoneHealthTimer: Timer?
    private var bridgeHealthTimer: Timer?
    private var bridgeWakeObserver: NSObjectProtocol?
    private var bluetoothConnectNotification: IOBluetoothUserNotification?
    /// Disconnect notifications are per-device, not global: IOBluetooth has no
    /// `registerForDisconnectNotifications` counterpart to the class-level connect observer.
    /// Keyed by lowercased address so a reconnect replaces its own stale observer.
    private var bluetoothDisconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var bluetoothBridgeRecoveryTimer: Timer?
    private var initialBluetoothConnections: Set<String> = []
    private var initialBluetoothConnectionTimer: Timer?
    private var pendingIdleDisconnects: Set<String> = []
    private var inputAccessPollTimer: Timer?
    private var controlAccessPollTimer: Timer?
    private var hidDetectionStarted = false
    private var mediaKeyInterceptorStarted = false
    private var didCleanUp = false
    private let caretController = RemoteCaretController()
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 VibeRemote starting...")

        // Run as menu bar app (no dock icon)
        NSApp.setActivationPolicy(.accessory)
        
        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let statusItem = statusItem else {
            NSApp.terminate(nil)
            return
        }
        statusItem.isVisible = true
        
        // Initialize menu bar manager
        microphoneBridgeManager = MicrophoneBridgeManager()
        bluetoothAccessManager = BluetoothAccessManager()
        menuBarManager = MenuBarManager(statusItem: statusItem, microphoneBridgeManager: microphoneBridgeManager)
        remoteHIDChannel = RemoteHIDChannel(microphoneBridgeManager: microphoneBridgeManager)
        
        remoteInputHandler = RemoteInputHandler(
            menuBarManager: menuBarManager,
            microphoneBridgeManager: microphoneBridgeManager
        )
        // Which Siri Remote family is attached decides the button profile and the microphone
        // path, and it is only knowable once its HID interfaces are open.
        remoteInputHandler?.onGenerationChanged = { [weak self] generation in
            self?.menuBarManager.updateRemoteGeneration(generation)
            self?.microphoneBridgeManager.updateRemoteGeneration(generation)
        }
        remoteInputHandler?.onRemoteIdleDisconnectRequested = { [weak self] deviceKey in
            self?.disconnectIdleRemote(deviceKey: deviceKey)
        }
        
        // Start remote detection
        remoteDetector = RemoteDetector(
            deviceCallback: { [weak self] event in
                guard let self else { return }

                let inputReady: Bool
                switch event {
                case .added(let device):
                    self.remoteHIDChannel?.resumeAfterIdleDisconnect()
                    self.remoteHIDChannel?.considerHIDDevice(device)
                    inputReady = self.remoteInputHandler?.addRemoteDevice(device) ?? false
                    self.menuBarManager.updateBluetoothConnectionStatus(connected: true)
                case .removed(let device):
                    inputReady = self.remoteInputHandler?.removeRemoteDevice(device) ?? false
                    self.menuBarManager.updateBluetoothConnectionStatus(connected: inputReady)
                }
                self.menuBarManager.updateRemoteInputState(inputReady ? .ready : .waitingForRemote)
            },
            stateCallback: { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.menuBarManager.updateRemoteInputState(.waitingForRemote)
                    self.startMediaKeyInterceptorIfNeeded()
                case .failed(let result):
                    self.hidDetectionStarted = false
                    self.menuBarManager.updateRemoteInputState(
                        result == kIOReturnNotPermitted ? .permissionRequired : .unavailable
                    )
                }
            }
        )

        menuBarManager.setInputAccessRequestHandler { [weak self] in
            self?.requestInputMonitoringAccess()
        }
        menuBarManager.setControlAccessRequestHandler { [weak self] in
            self?.requestAccessibilityAccess()
        }
        menuBarManager.setBluetoothAccessRequestHandler { [weak self] in
            self?.bluetoothAccessManager.requestAccess()
        }
        menuBarManager.setStatusRefreshHandler { [weak self] in
            self?.refreshPermissionStates()
        }
        menuBarManager.setRemoteIdleTimeoutHandler { [weak self] timeout in
            self?.remoteInputHandler?.updateRemoteIdleTimeout(timeout)
        }
        caretController.onVoiceSuppression = { [weak self] blocked in self?.microphoneBridgeManager.setVoiceSuppressed(blocked) }
        menuBarManager.advancedMenuHandler = { [weak self] in self?.caretController.cancel(); self?.advancedMenu.show() }
        advancedMenu.onAction = { [weak self] action, pid in
            guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.caretController.cancel()
            self.remoteInputHandler?.performAdvancedAction(action, targetPID: pid)
        }
        remoteInputHandler?.onAdvancedButton = { [weak self] button, pressed, device, generation in
            if button == "select", pressed { self?.advancedMenu.dismiss() }
            if self?.caretController.button(button, pressed: pressed, device: device) == true { return true }
            return self?.advancedMenu.handle(button: button, pressed: pressed, device: device, generation: generation) ?? false
        }

        bluetoothAccessManager.onStateChanged = { [weak self] state in
            self?.menuBarManager.updateBluetoothAccessState(state)
            if state == .allowed {
                self?.remoteHIDChannel?.startIfAuthorized()
                self?.startBluetoothConnectionMonitoringIfAuthorized()
            }
        }
        menuBarManager.updateBluetoothAccessState(bluetoothAccessManager.state)
        remoteHIDChannel?.startIfAuthorized()
        startBluetoothConnectionMonitoringIfAuthorized()

        // Configure the media-key interceptor now, but only start it after Input Monitoring
        // access is confirmed. Requesting permission is an explicit menu action.
        mediaKeyInterceptor = MediaKeyInterceptor()
        mediaKeyInterceptor?.capturePath = microphoneBridgeManager.buttonCapturePath
        remoteInputHandler?.usesPassiveButtonCapture = { [weak self] generation in
            guard let self else { return false }
            return self.usesPassiveButtonCapture(generation: generation)
        }
        mediaKeyInterceptor?.onSourceReset = { [weak self] in
            self?.caretController.reset()
            self?.advancedMenu.reset(); self?.remoteInputHandler?.resetCapturedButtons()
        }
        mediaKeyInterceptor?.onEscape = { [weak self] in
            guard let self, self.advancedMenu.isVisible else { return false }
            self.advancedMenu.dismiss(); return true
        }
        mediaKeyInterceptor?.onEditorInput = { [weak self] code, down in self?.caretController.keyboardInput(code: code, down: down) ?? false }
        mediaKeyInterceptor?.onCapturedTouch = { [weak self] frame in
            guard let self, !self.advancedMenu.isVisible else { return }
            self.caretController.receive(frame)
        }
        mediaKeyInterceptor?.onCapturedButton = { [weak self] edge in self?.handleCapturedAuxiliaryButton(edge) ?? false }
        mediaKeyInterceptor?.shouldAwaitRemoteSource = { [weak self] key in
            guard let self, self.usesPassiveButtonCapture(generation: self.remoteInputHandler?.generation ?? .unknown) else { return false }
            return [.playPause, .mute, .volumeUp, .volumeDown].contains(key)
        }
        mediaKeyInterceptor?.onMediaKey = { [weak self] keyType, isPressed, remoteSource in
            guard let self = self else { return false }
            return self.handleInterceptedMediaKey(keyType, isPressed: isPressed, remoteSource: remoteSource)
        }
        refreshInputMonitoringAccess()
        refreshAccessibilityAccess()
        VolumeRevertGuard.shared.prewarm()
        logPrivilegedHelperState()
        let bridgeManager = microphoneBridgeManager
        bridgeManager?.prepareAtLaunch {
            bridgeManager?.startAtLaunchIfPromptFree()
        }
        bridgeHealthTimer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.microphoneBridgeManager.maintainBridgeHealth()
                self?.menuBarManager.refreshBridgeStatusIcon()
            }
        }
        if let bridgeHealthTimer { RunLoop.main.add(bridgeHealthTimer, forMode: .common) }
        bridgeWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recoverFromStaleHIDInterfacesIfNeeded()
                self?.microphoneBridgeManager.recoverPacketLoggerAfterBluetoothConnectionAsync(deviceDescription: "Mac woke from sleep")
            }
        }
        microphoneHealthTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.recoverFromStaleHIDInterfacesIfNeeded()
                self?.refreshPermissionStates()
                self?.menuBarManager.refresh()
            }
        }
    }

    /// HID watchdog. macOS can silently re-enumerate the remote's HID services (observed when
    /// screen mirroring reconfigures the Bluetooth stack): our open device objects stop firing
    /// callbacks without any removal notification, killing buttons and the firmware's voice
    /// enable with no error anywhere. Detect the vanished services and re-arm the whole HID
    /// path — rediscovery re-seizes the fresh interfaces and re-writes the 0xAF enable.
    private func recoverFromStaleHIDInterfacesIfNeeded() {
        guard let remoteInputHandler else { return }
        guard remoteInputHandler.hasStaleInterfaces() else {
            recoverMissingRemoteInterfaces()
            return
        }
        rmDebug("🛰 HID watchdog: held interfaces vanished from the IOKit registry; re-arming detection")
        remoteInputHandler.resetForRediscovery()
        remoteDetector?.stopDetection()
        hidDetectionStarted = false
        startHIDDetectionIfNeeded()
    }

    /// Also handles zero open interfaces after an idle disconnect, which the registry-ID
    /// watchdog cannot detect. Read connection state without initiating any Bluetooth link.
    private func recoverMissingRemoteInterfaces() {
        guard let remoteInputHandler else { return }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let connected = Set(paired.compactMap { device -> String? in
            device.isConnected() ? device.addressString : nil
        })
        remoteDetector?.recoverMissingInterfaces(
            opened: remoteInputHandler.openedInterfaceIDs,
            connectedAddresses: connected,
            disconnectingAddresses: pendingIdleDisconnects
        )
    }

    /// PacketLogger can remain alive while its local HCI capture session silently stops
    /// forwarding Siri Remote traffic after the Bluetooth controller accepts another device.
    /// Process and HID-registry health checks cannot see that state: remote button events keep
    /// arriving and every PID remains valid. Observe the system's connection notification and
    /// debounce recovery until the Bluetooth stack has finished its short reconfiguration.
    private func startBluetoothConnectionMonitoringIfAuthorized() {
        guard bluetoothAccessManager.state == .allowed,
              bluetoothConnectNotification == nil else { return }
        // IOBluetooth may immediately replay devices that were already connected when the
        // observer registered. Seed a short-lived suppression set so app launch does not cause
        // a needless second bridge start; genuine connections after this window still recover.
        let pairedDevices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        initialBluetoothConnections = Set(pairedDevices.compactMap { device in
            guard device.isConnected() else { return nil }
            return device.addressString?.lowercased()
        })
        initialBluetoothConnectionTimer?.invalidate()
        initialBluetoothConnectionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.initialBluetoothConnections.removeAll()
                self?.initialBluetoothConnectionTimer = nil
            }
        }
        let notification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(bluetoothDeviceConnected(_:device:))
        )
        bluetoothConnectNotification = notification
        // Devices already connected never fire the connect observer, so their disconnects
        // would otherwise go unwatched until they reconnect once.
        for device in pairedDevices where device.isConnected() {
            observeDisconnect(of: device)
        }
        rmDebug(notification == nil
            ? "⚠️ Bluetooth connection monitoring could not be registered"
            : "📡 Bluetooth connection monitoring started")
    }

    /// Arms a one-shot disconnect observer for a single connected device. IOBluetooth
    /// invalidates the notification once it fires, so the connect handler re-arms it on the
    /// next connection.
    private func observeDisconnect(of device: IOBluetoothDevice) {
        guard let address = device.addressString?.lowercased() else { return }
        bluetoothDisconnectNotifications.removeValue(forKey: address)?.unregister()
        guard let notification = device.register(
            forDisconnectNotification: self,
            selector: #selector(bluetoothDeviceDisconnected(_:device:))
        ) else {
            rmDebug("⚠️ Could not observe disconnects for \(device.name ?? address)")
            return
        }
        bluetoothDisconnectNotifications[address] = notification
    }

    /// IOBluetooth does not guarantee the observer selector runs on the main thread. Hop to the
    /// main actor before touching timers; a Timer scheduled on its callback thread may never
    /// fire because that thread has no running RunLoop.
    @objc nonisolated private func bluetoothDeviceConnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        let deviceDescription = device.name ?? device.addressString ?? "Unknown Bluetooth device"
        let address = device.addressString?.lowercased()
        Task { @MainActor [weak self] in
            self?.observeDisconnect(of: device)
            self?.handleBluetoothDeviceConnected(
                deviceDescription: deviceDescription,
                address: address
            )
        }
    }

    /// A disconnect reconfigures the controller exactly like a connect does, and leaves the
    /// live capture just as silent — this is why the bridge previously needed a manual restart
    /// after unplugging a headset or walking away with a phone. Same debounced recovery.
    @objc nonisolated private func bluetoothDeviceDisconnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        let deviceDescription = device.name ?? device.addressString ?? "Unknown Bluetooth device"
        let address = device.addressString?.lowercased()
        Task { @MainActor [weak self] in
            self?.handleBluetoothDeviceDisconnected(
                deviceDescription: deviceDescription,
                address: address
            )
        }
    }

    private func handleBluetoothDeviceDisconnected(deviceDescription: String, address: String?) {
        caretController.reset()
        if let address {
            // The notification is spent once it fires; the connect handler re-arms it.
            bluetoothDisconnectNotifications.removeValue(forKey: address)
            // A device that disconnects before the launch replay window closes never had its
            // connect recovery run, so drop its suppression entry with it.
            initialBluetoothConnections.remove(address)
        }
        rmDebug("📡 Bluetooth device disconnected: \(deviceDescription); scheduling PacketLogger recovery")
        scheduleBridgeRecovery(reason: "\(deviceDescription) disconnected")
    }

    private func handleBluetoothDeviceConnected(deviceDescription: String, address: String?) {
        recoverMissingRemoteInterfaces()
        if let address,
           initialBluetoothConnections.remove(address) != nil {
            rmDebug("📡 Ignoring existing Bluetooth connection replay: \(deviceDescription)")
            return
        }
        let normalizedName = deviceDescription.lowercased()
        if normalizedName.contains("remote") || normalizedName.contains("siri") ||
            normalizedName.contains("apple tv") {
            // The Bluetooth notification precedes HID enumeration, so this closes the gap
            // where an AVRCP volume update could settle before the HID-side quarantine arms.
            VolumeRevertGuard.shared.beginRemoteConnectionQuarantine()
        }
        rmDebug("📡 Bluetooth device connected: \(deviceDescription); scheduling PacketLogger recovery")
        scheduleBridgeRecovery(reason: "\(deviceDescription) connected")
    }

    /// The HID descriptor exposes the physical remote's Bluetooth address as its serial. Close
    /// only that paired device after its idle timer expires; if lookup fails, HID
    /// keepalive has already stopped and the remote can still enter its normal firmware sleep.
    private func disconnectIdleRemote(deviceKey: String) {
        pendingIdleDisconnects.insert(deviceKey)
        remoteHIDChannel?.suspendForIdleDisconnect()
        // CoreBluetooth cancellation completes asynchronously. Give it a short head start so
        // IOBluetooth does not close and immediately reopen a link that still has a GATT client.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closeIdleBluetoothConnection(deviceKey: deviceKey)
            }
        }
    }

    private func closeIdleBluetoothConnection(deviceKey: String) {
        defer { pendingIdleDisconnects.remove(deviceKey) }
        let normalizedKey = deviceKey.lowercased().filter(\.isHexDigit)
        let pairedDevices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        guard let device = pairedDevices.first(where: {
            $0.addressString?.lowercased().filter(\.isHexDigit) == normalizedKey
        }) else {
            rmDebug("⚠️ Remote idle disconnect could not match Bluetooth address \(deviceKey)")
            return
        }
        guard device.isConnected() else {
            rmDebug("📡 Remote idle disconnect skipped; remote is already disconnected")
            return
        }
        let result = device.closeConnection()
        if result == kIOReturnSuccess {
            rmDebug("📡 Remote disconnected after configured idle timeout")
        } else {
            rmDebug(String(
                format: "⚠️ Remote idle disconnect failed (IOReturn=0x%X)",
                result
            ))
        }
    }

    /// Coalesces bursts of topology changes into one restart. A single user action routinely
    /// produces several notifications (a keyboard and trackpad waking together, a headset
    /// bringing up its profiles one at a time), and each restart costs a couple of seconds of
    /// capture.
    private func scheduleBridgeRecovery(reason: String) {
        microphoneBridgeManager.markBluetoothRecoveryPending()
        menuBarManager.refreshBridgeStatusIcon()
        bluetoothBridgeRecoveryTimer?.invalidate()
        bluetoothBridgeRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.bluetoothBridgeRecoveryTimer = nil
                self.microphoneBridgeManager.recoverPacketLoggerAfterBluetoothConnectionAsync(
                    deviceDescription: reason
                )
            }
        }
    }

    /// Records the helper's state at launch, and when it is approved verifies the XPC round
    /// trip. This is the health check that tells us the daemon is genuinely reachable rather
    /// than merely registered.
    private func logPrivilegedHelperState() {
        let client = PrivilegedHelperClient.shared
        let state = client.state
        rmDebug("🔐 Privileged helper state at launch: \(state)")
        guard state == .ready else { return }
        client.fetchVersion { version, error in
            if let version {
                rmDebug("🔐 Privileged helper reachable over XPC; version=\(version)")
            } else {
                rmDebug("🔐 Privileged helper unreachable: \(error ?? "unknown error")")
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard menuBarManager != nil else { return }
        refreshPermissionStates()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        menuBarManager?.showSettings()
        return true
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        cleanup()
        return .terminateNow
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        cleanup()
    }
    
    @MainActor
    private func cleanup() {
        guard !didCleanUp else { return }
        didCleanUp = true

        bridgeHealthTimer?.invalidate()
        bridgeHealthTimer = nil
        if let bridgeWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(bridgeWakeObserver)
            self.bridgeWakeObserver = nil
        }
        microphoneHealthTimer?.invalidate()
        microphoneHealthTimer = nil
        bluetoothBridgeRecoveryTimer?.invalidate()
        bluetoothBridgeRecoveryTimer = nil
        initialBluetoothConnectionTimer?.invalidate()
        initialBluetoothConnectionTimer = nil
        initialBluetoothConnections.removeAll()
        bluetoothConnectNotification?.unregister()
        bluetoothConnectNotification = nil
        for notification in bluetoothDisconnectNotifications.values {
            notification.unregister()
        }
        bluetoothDisconnectNotifications.removeAll()
        inputAccessPollTimer?.invalidate()
        inputAccessPollTimer = nil
        controlAccessPollTimer?.invalidate()
        controlAccessPollTimer = nil

        // Stop new HID callbacks first, then synchronously close every opened interface and
        // release the keys actually held by RemoteInputHandler before the process terminates.
        remoteDetector?.stopDetection()
        caretController.stop()
        remoteInputHandler?.stop()
        remoteHIDChannel?.stop()
        mediaKeyInterceptor?.stop()
        VolumeRevertGuard.shared.stop()
        advancedMenu.reset()
        microphoneBridgeManager?.stop()
        consumedRemoteMediaButtons.removeAll()
    }
    
    // MARK: - Media Key Handling

    /// Convert mach_absolute_time() delta to seconds (machine ticks vary; use timebase).
    private static let machTimebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t(numer: 0, denom: 0)
        guard mach_timebase_info(&info) == 0 else { return (1, 1) }
        return (info.numer, info.denom)
    }()

    private static func machDeltaToSeconds(from start: UInt64) -> Double {
        guard start > 0 else { return .infinity }
        let now = mach_absolute_time()
        let delta = now >= start ? (now - start) : 0
        let nanos = delta * UInt64(Self.machTimebase.numer) / UInt64(Self.machTimebase.denom)
        return Double(nanos) / 1_000_000_000.0
    }
    
    private func usesPassiveButtonCapture(generation: RemoteGeneration) -> Bool {
        RemoteButtonMapping.usesPassiveCapture(generation: generation,
            packetLogger: UserDefaults.standard.string(forKey: "microphoneBridgeEngine") == "packetlogger",
            mediaTap: mediaKeyInterceptorStarted)
    }

    private func handleCapturedAuxiliaryButton(_ edge: PacketLoggerButtonParser.Edge) -> Bool {
        guard usesPassiveButtonCapture(generation: .aluminumClickpad) else { return false }
        if edge.pressed && edge.button != "back" { remoteInputHandler?.cancelBackDoubleClick() }
        if edge.pressed { caretController.cancel() }
        remoteInputHandler?.recordCapturedActivity(edge)
        let device = "capture:\(edge.sender)"
        let claimed = advancedMenu.handle(button: edge.button, pressed: edge.pressed, device: device, generation: .aluminumClickpad, time: edge.capturedAt.timeIntervalSinceReferenceDate)
        if ["mute", "volumeUp", "volumeDown"].contains(edge.button) {
            VolumeRevertGuard.shared.handleRemoteButton(edge.button, pressed: edge.pressed)
        }
        if claimed { remoteInputHandler?.cancelBackDoubleClick(); return true }
        // Reserved buttons stay inert in Touch too; do not forward native media keys.
        if menuBarManager.getMapping(for: edge.button, generation: .aluminumClickpad) == .none { return true }

        remoteInputHandler?.handleCapturedButton(edge)
        return true
    }

    @MainActor
    private func handleInterceptedMediaKey(_ keyType: MediaKeyInterceptor.MediaKeyType, isPressed: Bool, remoteSource: UInt64?) -> Bool {
        let buttonName: String
        switch keyType {
        case .playPause:  buttonName = "playPause"
        case .next:       buttonName = "nextTrack"
        case .previous:   buttonName = "prevTrack"
        case .volumeUp:   buttonName = "volumeUp"
        case .volumeDown: buttonName = "volumeDown"
        case .mute:       buttonName = "mute"
        }

        // HID-owned mappings retain suppression through their corresponding releases.
        if !isPressed, consumedRemoteMediaButtons.remove(buttonName) != nil { return true }

        // System repeats arrive without another HID down. Keep consuming them for the
        // physical hold instead of letting them escape after the initial 350ms marker.
        if VolumeRevertGuard.shared.suppressesMediaKey(buttonName) {
            if isPressed { consumedRemoteMediaButtons.insert(buttonName) }
            else { consumedRemoteMediaButtons.remove(buttonName) }
            return true
        }

        if !isPressed {
            if consumedRemoteMediaButtons.remove(buttonName) != nil {
                return true
            }
            return false
        }

        // Only consume media-key events that match a just-seen Siri Remote HID event.
        // Keyboard media keys also arrive here, but they do not have this HID marker.
        if RemoteInputHandler.lastProcessedButton == buttonName {
            let timeSinceLastProcess = Self.machDeltaToSeconds(from: RemoteInputHandler.lastProcessedTime)
            if timeSinceLastProcess < 0.35 {
                consumedRemoteMediaButtons.insert(buttonName)
                return true
            }
        }

        return false
    }
    
    // MARK: - Permissions

    private func refreshInputMonitoringAccess() {
        guard #available(macOS 10.15, *) else {
            startHIDDetectionIfNeeded()
            return
        }
        guard CGPreflightListenEventAccess() else {
            if !hidDetectionStarted {
                menuBarManager.updateRemoteInputState(.permissionRequired)
            }
            return
        }

        inputAccessPollTimer?.invalidate()
        inputAccessPollTimer = nil
        startHIDDetectionIfNeeded()
        startMediaKeyInterceptorIfNeeded()
    }

    private func requestInputMonitoringAccess() {
        guard #available(macOS 10.15, *) else {
            startHIDDetectionIfNeeded()
            return
        }

        rmDebug("🔐 Input Monitoring access requested from menu")
        menuBarManager.updateRemoteInputState(.starting)
        let granted = CGRequestListenEventAccess()
        rmDebug("🔐 Input Monitoring request result: \(granted ? "granted" : "not granted")")
        if granted {
            startHIDDetectionIfNeeded()
            return
        }

        // Once macOS has recorded a denial, CGRequestListenEventAccess() returns false
        // without showing another dialog. Because this method only runs after an explicit
        // menu click, take the user directly to the Input Monitoring pane instead.
        if let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        ) {
            let opened = NSWorkspace.shared.open(settingsURL)
            rmDebug("🔐 Open Input Monitoring settings: \(opened ? "success" : "failed")")
        }

        // The system may require the user to finish the change in System Settings. Polling
        // only checks the result; it never reissues the permission request or another prompt.
        inputAccessPollTimer?.invalidate()
        inputAccessPollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshInputMonitoringAccess()
            }
        }
        menuBarManager.updateRemoteInputState(.permissionRequired)
    }

    private func refreshAccessibilityAccess() {
        let trusted = AXIsProcessTrusted()
        menuBarManager.updateRemoteControlState(trusted ? .ready : .permissionRequired)
        if trusted {
            controlAccessPollTimer?.invalidate()
            controlAccessPollTimer = nil
        }
    }

    private func refreshPermissionStates() {
        menuBarManager.updateBluetoothAccessState(bluetoothAccessManager.state)
        refreshInputMonitoringAccess()
        refreshAccessibilityAccess()
    }

    private func requestAccessibilityAccess() {
        rmDebug("🔐 Accessibility access requested from menu")
        menuBarManager.updateRemoteControlState(.starting)

        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let trusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        rmDebug("🔐 Accessibility request result: \(trusted ? "granted" : "not granted")")
        if trusted {
            refreshAccessibilityAccess()
            return
        }

        // A previous denial suppresses the system prompt. The user explicitly selected the
        // menu item, so opening this pane is intentional rather than an automatic launch action.
        if let settingsURL = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            let opened = NSWorkspace.shared.open(settingsURL)
            rmDebug("🔐 Open Accessibility settings: \(opened ? "success" : "failed")")
        }

        controlAccessPollTimer?.invalidate()
        controlAccessPollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAccessibilityAccess()
            }
        }
        menuBarManager.updateRemoteControlState(.permissionRequired)
    }



    private func startHIDDetectionIfNeeded() {
        guard !hidDetectionStarted else { return }
        hidDetectionStarted = true
        menuBarManager.updateRemoteInputState(.starting)
        remoteDetector?.startDetection()
    }

    private func startMediaKeyInterceptorIfNeeded() {
        guard !mediaKeyInterceptorStarted else { return }
        guard mediaKeyInterceptor?.start() == true else {
            print("⚠️ Media-key interception unavailable even though HID access is granted")
            return
        }
        mediaKeyInterceptorStarted = true
    }
}
