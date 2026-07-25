//
//  MicrophoneBridgeManager.swift
//  VibeRemote
//
//  Controls the Siri Remote microphone bridge.
//

import AppKit
import AudioToolbox
import CoreAudio
@preconcurrency import CoreBluetooth
import Darwin
import Foundation
import HelperProtocol
import IOBluetooth

struct MicrophoneBridgeStatus: Sendable {
    var running: Bool
    var remoteAddress: String?
    var packetLoggerPath: String?
    var helperPath: String?
    var packetLoggerHelperInstalled: Bool
    var bluetoothPacketLoggingConfigured: Bool
    var outputDeviceAvailable: Bool
    var outputDeviceName: String?
    var lastError: String?
}

struct MicrophoneBridgeDiagnostics: Sendable {
    var generatedAt: Date
    var remoteAddress: String?
    var bridgeRunning: Bool
    var helperPID: Int32?
    var helperAlive: Bool
    var packetLoggerPID: Int32?
    var packetLoggerAlive: Bool
    var packetLoggerHelperInstalled: Bool
    var bluetoothPacketLoggingConfigured: Bool
    var outputDeviceName: String?
    var defaultInputDeviceName: String?
    var helperLogSize: UInt64
    var helperLogAge: String
    var helperSelectedOutput: Bool
    var helperVoiceStartedCount: Int
    var helperVoiceEndedCount: Int
    var helperErrorCount: Int
    var helperLastLine: String?
    var packetLoggerDisconnected: Bool
    var packetLoggerLogSize: UInt64
    var packetLoggerLogAge: String
    var packetLoggerLastLine: String?
    var packetCaptureSize: UInt64
    var packetCaptureAge: String
    var recentPacketLineCount: Int
    var recentRemoteLineCount: Int
    var recentRemoteSendCount: Int
    var recentRemoteRecvCount: Int
    var recentOldVoiceStartCount: Int
    var recentOldVoiceEndCount: Int
    var recentOldAudioFrameCount: Int
    var recentNewVoiceFrameCount: Int
    var recentNewVoiceContinuationCount: Int
    var recentNewVoiceEndCount: Int
    var recentRaw4020Count: Int
    var lastRemotePacketLine: String?
    var lastOldVoiceMarkerLine: String?
    var lastNewVoiceMarkerLine: String?
    var hidAudioInterfaceMode: String?
    var hidInputEnableSuccessCount: Int
    var hidInputEnableFailureCount: Int
    var lastHIDInputEnableLine: String?
    var lastDirectGATTLine: String?
    var recentSiriHIDEventCount: Int
    var lastHIDEventLine: String?
    var directHIDReportCount: Int
    var directHIDCaptureSize: UInt64
    var directHIDCaptureAge: String
    var lastDirectHIDReportSummary: String?
    var lastBridgeLogLine: String?
    var appLogAge: String
    var blockingIssues: [String]
    var lastError: String?

    var copyText: String {
        var lines: [String] = []
        lines.append("VibeRemote diagnostics")
        lines.append("Generated: \(generatedAt)")
        lines.append("Remote: \(remoteAddress ?? "not detected")")
        if blockingIssues.isEmpty {
            lines.append("Blocking issues: none")
        } else {
            lines.append("Blocking issues:")
            for issue in blockingIssues {
                lines.append("- \(issue)")
            }
        }
        lines.append("Bridge running: \(bridgeRunning)")
        lines.append("Helper: \(helperAlive ? "alive" : "not alive") pid=\(helperPID.map(String.init) ?? "-")")
        lines.append("PacketLogger: \(packetLoggerAlive ? "alive" : "not alive") pid=\(packetLoggerPID.map(String.init) ?? "-")")
        lines.append("PacketLogger helper installed: \(packetLoggerHelperInstalled)")
        lines.append("Bluetooth packet logging configured: \(bluetoothPacketLoggingConfigured)")
        lines.append("Output device: \(outputDeviceName ?? "missing")")
        lines.append("Default input: \(defaultInputDeviceName ?? "unknown")")
        lines.append("Helper output selected: \(helperSelectedOutput)")
        lines.append("Helper voice started/ended/errors: \(helperVoiceStartedCount)/\(helperVoiceEndedCount)/\(helperErrorCount)")
        lines.append("Helper log: \(helperLogSize) bytes, age \(helperLogAge)")
        lines.append("Helper last line: \(helperLastLine ?? "-")")
        lines.append("PacketLogger disconnected: \(packetLoggerDisconnected)")
        lines.append("PacketLogger log: \(packetLoggerLogSize) bytes, age \(packetLoggerLogAge)")
        lines.append("PacketLogger last line: \(packetLoggerLastLine ?? "-")")
        lines.append("Packet capture: \(packetCaptureSize) bytes, age \(packetCaptureAge)")
        lines.append("Recent packet lines: \(recentPacketLineCount)")
        lines.append("Recent remote HCI lines: \(recentRemoteLineCount) send=\(recentRemoteSendCount) recv=\(recentRemoteRecvCount)")
        lines.append("Recent old voice markers: start=\(recentOldVoiceStartCount) end=\(recentOldVoiceEndCount) audioFrames=\(recentOldAudioFrameCount)")
        lines.append("Recent new voice packets: frames=\(recentNewVoiceFrameCount) continuations=\(recentNewVoiceContinuationCount) end=\(recentNewVoiceEndCount)")
        lines.append("Recent raw 40 20 occurrences: \(recentRaw4020Count)")
        lines.append("Last remote packet: \(lastRemotePacketLine ?? "-")")
        lines.append("Last old voice marker: \(lastOldVoiceMarkerLine ?? "-")")
        lines.append("Last new voice marker: \(lastNewVoiceMarkerLine ?? "-")")
        lines.append("HID Siri interface: \(hidAudioInterfaceMode ?? "unknown")")
        lines.append("HID input enable success/failure: \(hidInputEnableSuccessCount)/\(hidInputEnableFailureCount)")
        lines.append("Last HID input enable: \(lastHIDInputEnableLine ?? "-")")
        lines.append("Last Direct GATT: \(lastDirectGATTLine ?? "-")")
        lines.append("Recent Siri HID events: \(recentSiriHIDEventCount)")
        lines.append("Last HID event: \(lastHIDEventLine ?? "-")")
        lines.append("Direct HID reports: \(directHIDReportCount)")
        lines.append("Direct HID capture: \(directHIDCaptureSize) bytes, age \(directHIDCaptureAge)")
        lines.append("Last Direct HID report: \(lastDirectHIDReportSummary ?? "-")")
        lines.append("Last bridge log: \(lastBridgeLogLine ?? "-")")
        lines.append("App log age: \(appLogAge)")
        lines.append("Last error: \(lastError ?? "-")")
        return lines.joined(separator: "\n")
    }
}

final class MicrophoneBridgeManager: @unchecked Sendable {
    private enum DefaultsKey {
        static let remoteAddress = "microphoneRemoteAddress"
        static let packetLoggerPath = "microphonePacketLoggerPath"
    }

    private struct SupervisorIdentity {
        let pid: Int32
        let token: String
    }

    private let runtimeDirectoryPath: String
    // Names the root supervisor also derives from the runtime directory come from the shared
    // PacketLoggerBridge definitions so the two sides cannot disagree.
    private var helperPIDFilePath: String { runtimePath(PacketLoggerBridge.RuntimeFile.voiceHelperPID) }
    private var packetLoggerPIDFilePath: String { runtimePath("packetlogger-supervisor.pid") }
    private var previousInputDeviceFilePath: String { runtimePath("previous-input-device.id") }
    private var fifoPath: String { runtimePath(PacketLoggerBridge.RuntimeFile.voiceFIFO) }
    private var packetLoggerFIFOPath: String { runtimePath(PacketLoggerBridge.RuntimeFile.packetLoggerFIFO) }
    private var stopSignalPath: String { runtimePath(PacketLoggerBridge.RuntimeFile.stopSignal) }
    private var helperLogPath: String { runtimePath("voice-helper.log") }
    private var packetLoggerLogPath: String { runtimePath(PacketLoggerBridge.RuntimeFile.packetLoggerLog) }
    private var packetCapturePath: String { runtimePath(PacketLoggerBridge.RuntimeFile.packetCapture) }
    private var directHIDCapturePath: String { runtimePath("direct-hid-audio.log") }
    private var packetLoggerSessionPath: String { runtimePath(PacketLoggerBridge.RuntimeFile.packetLoggerSession) }
    private var appLogPath: String { vibeRemoteLogPath }
    private let packetLoggerHelperInstallPath = PacketLoggerBridge.systemHelperInstallPath
    private let packetLoggerHelperPlistPath = PacketLoggerBridge.systemHelperPlistPath
    private let bluetoothDebugPreferencesPath = PacketLoggerBridge.bluetoothDebugPreferencesPath
    private let appBundle: Bundle
    private let workQueue = DispatchQueue(label: "com.viberemote.microphoneBridge", qos: .userInitiated)
    private let workQueueKey = DispatchSpecificKey<Void>()
    private let stateLock = NSLock()
    private var storedHelperProcess: Process?
    private var storedHelperPID: Int32?
    private var storedPacketLoggerIdentity: SupervisorIdentity?
    private var storedPreviousDefaultInputDeviceID: AudioDeviceID?
    private var storedLastError: String?
    /// Accessed only on workQueue. The write end feeds raw HID report records to the user-session helper.
    private var helperInputPipe: Pipe?
    private var directHIDCapturedReportCount = 0
    private let directHIDCaptureLimit = 128

    private var helperProcess: Process? {
        get { withStateLock { storedHelperProcess } }
        set { withStateLock { storedHelperProcess = newValue } }
    }

    private var helperPID: Int32? {
        get { withStateLock { storedHelperPID } }
        set { withStateLock { storedHelperPID = newValue } }
    }

    private var packetLoggerIdentity: SupervisorIdentity? {
        get { withStateLock { storedPacketLoggerIdentity } }
        set { withStateLock { storedPacketLoggerIdentity = newValue } }
    }

    private var previousDefaultInputDeviceID: AudioDeviceID? {
        get { withStateLock { storedPreviousDefaultInputDeviceID } }
        set { withStateLock { storedPreviousDefaultInputDeviceID = newValue } }
    }

    private var lastError: String? {
        get { withStateLock { storedLastError } }
        set { withStateLock { storedLastError = newValue } }
    }

    init(appBundle: Bundle = .main) {
        self.appBundle = appBundle
        self.runtimeDirectoryPath = Self.defaultRuntimeDirectoryPath()
        self.workQueue.setSpecific(key: workQueueKey, value: ())
    }

    deinit {
        syncOnWorkQueue {
            stopLocked()
        }
    }

    /// Launch-time housekeeping. The bridge itself is never auto-started: starting swaps the
    /// system default input device (and can still raise an admin prompt when the privileged
    /// helper is unavailable), so it stays an explicit, user-initiated menu action.
    func prepareAtLaunch(completion: (@Sendable () -> Void)? = nil) {
        workQueue.async { [weak self] in
            guard let self else { return }
            if self.prepareRuntimeDirectory() {
                self.restoreDefaultInputDevice()
            }
            self.appendAppLog("Microphone bridge requires an explicit Start/Restart action after app launch")
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    func handleButton(button: String, pressed: Bool) {
        // Siri Remote decides when to emit microphone audio. Button presses should not
        // start/stop the bridge; the bridge stays online and passively waits for audio.
    }

    func handleDirectHIDAudioReport(reportID: UInt32, data: Data) {
        workQueue.async { [weak self] in
            guard let self,
                  self.helperProcess?.isRunning == true,
                  let pipe = self.helperInputPipe else { return }

            let line = Self.directHIDReportLine(reportID: reportID, data: data)
            guard let encoded = line.data(using: .utf8) else { return }

            do {
                try pipe.fileHandleForWriting.write(contentsOf: encoded)
            } catch {
                self.setLastError("Direct HID audio pipe failed: \(error.localizedDescription)")
                self.stopUserHelper()
                return
            }

            if self.directHIDCapturedReportCount < self.directHIDCaptureLimit {
                if self.appendPrivateData(encoded, at: self.directHIDCapturePath) {
                    self.directHIDCapturedReportCount += 1
                    if self.directHIDCapturedReportCount == self.directHIDCaptureLimit {
                        self.appendAppLog("Direct HID diagnostic capture reached its \(self.directHIDCaptureLimit)-report limit")
                    }
                }
            }
        }
    }

    nonisolated static func directHIDReportLine(reportID: UInt32, data: Data) -> String {
        let hex = data.map { String(format: "%02X", $0) }.joined(separator: " ")
        return "HID REPORT id=\(String(format: "%02X", reportID)) length=\(data.count) data=\(hex)\n"
    }

    func status() -> MicrophoneBridgeStatus {
        statusLocked()
    }

    /// Lightweight snapshot for menu rendering. It intentionally avoids Bluetooth discovery,
    /// process launches, code-signature validation, and other work that could block AppKit.
    func menuStatus() -> MicrophoneBridgeStatus {
        let outputDeviceName = preferredOutputDeviceName()
        return MicrophoneBridgeStatus(
            running: helperProcess?.isRunning == true,
            remoteAddress: nil,
            packetLoggerPath: nil,
            helperPath: nil,
            packetLoggerHelperInstalled: false,
            bluetoothPacketLoggingConfigured: false,
            outputDeviceAvailable: outputDeviceName != nil,
            outputDeviceName: outputDeviceName,
            lastError: lastError
        )
    }

    private func statusLocked() -> MicrophoneBridgeStatus {
        MicrophoneBridgeStatus(
            running: isRunningLocked(),
            remoteAddress: configuredOrDetectedRemoteAddress(),
            packetLoggerPath: packetLoggerExecutablePath(),
            helperPath: helperExecutablePath(),
            packetLoggerHelperInstalled: packetLoggerSystemHelperInstalled(),
            bluetoothPacketLoggingConfigured: bluetoothPacketLoggingConfigured(),
            outputDeviceAvailable: preferredOutputDeviceName() != nil,
            outputDeviceName: preferredOutputDeviceName(),
            lastError: lastError
        )
    }

    func diagnostics() -> MicrophoneBridgeDiagnostics {
        diagnosticsLocked()
    }

    func diagnosticsAsync(completion: @escaping @Sendable (MicrophoneBridgeDiagnostics) -> Void) {
        workQueue.async { [weak self] in
            guard let diagnostics = self?.diagnosticsLocked() else { return }
            DispatchQueue.main.async {
                completion(diagnostics)
            }
        }
    }

    private func diagnosticsLocked() -> MicrophoneBridgeDiagnostics {
        let helperLivePID = liveHelperPID()
        if let helperLivePID {
            helperPID = helperLivePID
        }
        let packetLoggerLiveIdentity = livePacketLoggerIdentity()
        let packetLoggerLivePID = packetLoggerLiveIdentity?.pid
        packetLoggerIdentity = packetLoggerLiveIdentity

        let helperText = tailText(path: helperLogPath, maxBytes: 128 * 1024)
        let packetLoggerText = tailText(path: packetLoggerLogPath, maxBytes: 128 * 1024)
        let packetText = tailText(path: packetCapturePath, maxBytes: 768 * 1024)
        let directHIDText = tailText(path: directHIDCapturePath, maxBytes: 128 * 1024)
        let appText = tailText(path: appLogPath, maxBytes: 256 * 1024)
        let helperLines = nonEmptyLines(helperText)
        let packetLoggerLines = nonEmptyLines(packetLoggerText)
        let packetLines = nonEmptyLines(packetText)
        let directHIDLines = nonEmptyLines(directHIDText)
        let appLines = nonEmptyLines(appText)
        let bridgeLogLines = appLines.filter {
            $0.contains("Microphone bridge") || $0.contains("Microphone saved mode")
        }

        let remoteAddress = configuredOrDetectedRemoteAddress()
        let reverseAddressBytes = remoteAddress.map(reverseAddressByteString)
        let remoteLines = packetLines.filter { line in
            line.contains("Marcus Siri Remot")
                || line.contains("0x004E")
                || reverseAddressBytes.map { line.contains($0) } == true
        }
        let oldVoiceMarkerLines = packetLines.filter {
            $0.contains("1B 23 00 00 10") || $0.contains("1B 23 00 10 00")
        }
        let newVoiceMarkerLines = packetLines.filter {
            isNewSiriRemoteVoiceFrame($0) || isNewSiriRemoteVoiceContinuation($0) || isNewSiriRemoteVoiceEnd($0)
        }
        let hidAudioInterfaceLines = appLines.filter {
            $0.contains("usagePage=0xC usage=0x4") && ($0.contains("SEIZED") || $0.contains("LISTENING"))
        }
        let hidInputEnableSuccessLines = appLines.filter { $0.contains("Siri Remote input enabled") }
        let hidInputEnableFailureLines = appLines.filter { $0.contains("Siri Remote input-enable feature ignored") }
        let hidInputEnableLines = appLines.filter {
            $0.contains("Siri Remote input enabled") || $0.contains("Siri Remote input-enable feature ignored")
        }
        let directGATTLines = appLines.filter {
            $0.contains("Direct GATT HID") || $0.contains("Direct GATT audio report")
        }
        let hidEventLines = appLines.filter { $0.contains("HID event:") }
        let hidAudioReportLines = appLines.filter { $0.contains("HID audio report:") }
        let outputDeviceName = preferredOutputDeviceName()
        let defaultInputName = defaultInputDeviceName()
        let packetLoggerIsDisconnected = packetLoggerDisconnected()
        let helperAlive = helperLivePID != nil
        let packetLoggerAlive = packetLoggerLivePID != nil
        let recentOldVoiceStartCount = packetLines.filter { $0.contains("1B 23 00 00 10") }.count
        let recentOldAudioFrameCount = packetLines.filter { isOldSiriRemoteAudioFrame($0) }.count
        let recentNewVoiceFrameCount = packetLines.filter { isNewSiriRemoteVoiceFrame($0) }.count
        let recentNewVoiceContinuationCount = packetLines.filter { isNewSiriRemoteVoiceContinuation($0) }.count
        let recentNewVoiceEndCount = packetLines.filter { isNewSiriRemoteVoiceEnd($0) }.count
        let blockingIssues = diagnosticsBlockingIssues(
            helperAlive: helperAlive,
            packetLoggerAlive: packetLoggerAlive,
            packetLoggerDisconnected: packetLoggerIsDisconnected,
            outputDeviceName: outputDeviceName,
            defaultInputDeviceName: defaultInputName,
            remoteLineCount: remoteLines.count,
            oldVoiceStartCount: recentOldVoiceStartCount,
            oldAudioFrameCount: recentOldAudioFrameCount,
            newVoiceFrameCount: recentNewVoiceFrameCount,
            newVoiceContinuationCount: recentNewVoiceContinuationCount,
            directHIDReportCount: directHIDLines.count,
            lastDirectGATTLine: directGATTLines.last
        )

        return MicrophoneBridgeDiagnostics(
            generatedAt: Date(),
            remoteAddress: remoteAddress,
            bridgeRunning: isRunningLocked(),
            helperPID: helperLivePID,
            helperAlive: helperAlive,
            packetLoggerPID: packetLoggerLivePID,
            packetLoggerAlive: packetLoggerAlive,
            packetLoggerHelperInstalled: packetLoggerSystemHelperInstalled(),
            bluetoothPacketLoggingConfigured: bluetoothPacketLoggingConfigured(),
            outputDeviceName: outputDeviceName,
            defaultInputDeviceName: defaultInputName,
            helperLogSize: fileSize(path: helperLogPath),
            helperLogAge: fileAgeDescription(path: helperLogPath),
            helperSelectedOutput: Self.supportedOutputDeviceNames.contains {
                helperText.contains("Output device set to: \($0)")
            },
            helperVoiceStartedCount: helperLines.filter { $0.contains("Voice started") }.count,
            helperVoiceEndedCount: helperLines.filter { $0.contains("Voice ended") }.count,
            helperErrorCount: helperLines.filter { $0.localizedCaseInsensitiveContains("error") }.count,
            helperLastLine: helperLines.last,
            packetLoggerDisconnected: packetLoggerIsDisconnected,
            packetLoggerLogSize: fileSize(path: packetLoggerLogPath),
            packetLoggerLogAge: fileAgeDescription(path: packetLoggerLogPath),
            packetLoggerLastLine: packetLoggerLines.last,
            packetCaptureSize: fileSize(path: packetCapturePath),
            packetCaptureAge: fileAgeDescription(path: packetCapturePath),
            recentPacketLineCount: packetLines.count,
            recentRemoteLineCount: remoteLines.count,
            recentRemoteSendCount: remoteLines.filter { $0.contains(" SEND ") }.count,
            recentRemoteRecvCount: remoteLines.filter { $0.contains(" RECV ") }.count,
            recentOldVoiceStartCount: recentOldVoiceStartCount,
            recentOldVoiceEndCount: packetLines.filter { $0.contains("1B 23 00 10 00") }.count,
            recentOldAudioFrameCount: recentOldAudioFrameCount,
            recentNewVoiceFrameCount: recentNewVoiceFrameCount,
            recentNewVoiceContinuationCount: recentNewVoiceContinuationCount,
            recentNewVoiceEndCount: recentNewVoiceEndCount,
            recentRaw4020Count: packetLines.filter { $0.contains("40 20") }.count,
            lastRemotePacketLine: remoteLines.last,
            lastOldVoiceMarkerLine: oldVoiceMarkerLines.last,
            lastNewVoiceMarkerLine: newVoiceMarkerLines.last,
            hidAudioInterfaceMode: hidAudioInterfaceLines.last.map { $0.contains("LISTENING") ? "LISTENING" : "SEIZED" },
            hidInputEnableSuccessCount: hidInputEnableSuccessLines.count,
            hidInputEnableFailureCount: hidInputEnableFailureLines.count,
            lastHIDInputEnableLine: hidInputEnableLines.last,
            lastDirectGATTLine: directGATTLines.last,
            recentSiriHIDEventCount: appLines.filter {
                ($0.contains("HID event:") && ($0.contains("usage=0x4") || $0.contains("→ siri")))
                    || $0.contains("HID audio report:")
            }.count,
            lastHIDEventLine: (hidEventLines + hidAudioReportLines).last,
            directHIDReportCount: directHIDLines.count,
            directHIDCaptureSize: fileSize(path: directHIDCapturePath),
            directHIDCaptureAge: fileAgeDescription(path: directHIDCapturePath),
            lastDirectHIDReportSummary: directHIDLines.last.map {
                $0.components(separatedBy: " data=").first ?? $0
            },
            lastBridgeLogLine: bridgeLogLines.last,
            appLogAge: fileAgeDescription(path: appLogPath),
            blockingIssues: blockingIssues,
            lastError: lastError
        )
    }

    var isRunning: Bool {
        isRunningLocked()
    }

    private func isRunningLocked() -> Bool {
        liveHelperPID().map {
            helperPID = $0
            return true
        } ?? false
    }

    func start() {
        syncOnWorkQueue {
            startLocked()
        }
    }

    private func startLocked() {
        // macOS's IOHID proxy never delivers Siri Remote 0xFA audio reports to user space,
        // so the PacketLogger capture bridge remains the only working audio path. The
        // Direct HID engine stays the default while that conclusion is revalidated;
        // opt into the capture engine with:
        //   defaults write com.viberemote.app microphoneBridgeEngine packetlogger
        if UserDefaults.standard.string(forKey: "microphoneBridgeEngine") == "packetlogger" {
            startPacketLoggerBridgeLocked()
            return
        }
        appendAppLog("Direct HID microphone bridge start requested")
        guard prepareRuntimeDirectory() else { return }

        if isRunningLocked() {
            if let outputDeviceName = preferredOutputDeviceName() {
                loadPreviousInputDeviceIfNeeded()
                _ = setDefaultInputDevice(named: outputDeviceName)
                clearLastError()
                appendAppLog("Direct HID microphone bridge already running")
            } else {
                setLastError("The VibeRemote audio device is not installed.")
            }
            return
        }

        stopUserHelper()
        // Clean up a legacy capture supervisor if an older build left one running. This sends
        // only its private stop signal and never starts PacketLogger or invokes osascript.
        stopPacketLogger()
        restoreDefaultInputDevice()

        guard let helperCandidate = helperExecutablePath() else {
            setLastError("VibeRemoteVoiceBridge helper was not found.")
            return
        }
        let helper = URL(fileURLWithPath: helperCandidate)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        guard let outputDeviceName = preferredOutputDeviceName() else {
            setLastError("The VibeRemote audio device is not installed.")
            return
        }

        guard writePrivateFile("", at: helperLogPath),
              writePrivateFile("", at: directHIDCapturePath) else {
            setLastError("Could not prepare Direct HID microphone bridge files.")
            return
        }
        directHIDCapturedReportCount = 0

        let inputPipe = Pipe()
        // Prevent a helper exit from delivering SIGPIPE to the menu-bar process.
        _ = fcntl(inputPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let helperCommand = """
        exec \(shellEscape(helper)) >> \(shellEscape(helperLogPath)) 2>&1
        """
        let helperRunner = Process()
        helperRunner.executableURL = URL(fileURLWithPath: "/bin/bash")
        helperRunner.arguments = ["-c", helperCommand]
        helperRunner.standardInput = inputPipe

        do {
            try helperRunner.run()
            helperProcess = helperRunner
            helperPID = helperRunner.processIdentifier
            helperInputPipe = inputPipe
            guard writePrivateFile("\(helperRunner.processIdentifier)\n", at: helperPIDFilePath) else {
                throw NSError(
                    domain: "VibeRemote.MicrophoneBridge",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Could not record the Direct HID helper identity."]
                )
            }
            guard captureDefaultInputDevice() else {
                throw NSError(
                    domain: "VibeRemote.MicrophoneBridge",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Could not save the current default input device."]
                )
            }
            guard setDefaultInputDevice(named: outputDeviceName) else {
                throw NSError(
                    domain: "VibeRemote.MicrophoneBridge",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Could not select \(outputDeviceName) as the default input device."]
                )
            }
            clearLastError()
            appendAppLog("Direct HID microphone bridge started pid=\(helperRunner.processIdentifier); waiting for Siri Remote audio reports")
        } catch {
            setLastError("Could not start Direct HID microphone bridge: \(error.localizedDescription)")
            stopLocked()
        }
    }

    /// Retained temporarily as an implementation reference and compatibility fallback while the
    /// Direct HID framing is validated. The normal menu flow never calls this method.
    private func startPacketLoggerBridgeLocked() {
        appendAppLog("Microphone bridge start requested")
        guard prepareRuntimeDirectory() else { return }

        if isRunningLocked() {
            if let outputDeviceName = preferredOutputDeviceName() {
                loadPreviousInputDeviceIfNeeded()
                _ = setDefaultInputDevice(named: outputDeviceName)
                clearLastError()
                appendAppLog("Microphone bridge already running")
            } else {
                setLastError("The VibeRemote audio device is not installed.")
            }
            return
        }

        stopUserHelper()
        stopPacketLogger()
        restoreDefaultInputDevice()
        guard let remoteAddress = configuredOrDetectedRemoteAddress() else {
            setLastError("No paired Siri Remote Bluetooth address found.")
            return
        }
        appendAppLog("Microphone bridge remote address: \(remoteAddress)")
        guard let packetLogger = packetLoggerExecutablePath() else {
            setLastError("A valid Apple-signed PacketLogger.app was not found.")
            return
        }
        guard let packetLoggerApp = packetLoggerAppPath(for: packetLogger) else {
            setLastError("PacketLogger must be the executable inside PacketLogger.app.")
            return
        }
        if let validationError = packetLoggerValidationError(
            executablePath: packetLogger,
            appPath: packetLoggerApp
        ) {
            setLastError(validationError)
            return
        }
        appendAppLog("Microphone bridge PacketLogger: \(packetLogger)")
        if !packetLoggerSystemHelperInstalledAndValid(),
           packetLoggerSystemHelperSourcePath(for: packetLogger) == nil {
            setLastError("An Apple-signed PacketLoggerHelper was not found inside PacketLogger.app.")
            return
        }
        guard let helperCandidate = helperExecutablePath() else {
            setLastError("SiriRemoteVoiceControl helper was not found.")
            return
        }
        let helper = URL(fileURLWithPath: helperCandidate)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        appendAppLog("Microphone bridge voice helper: \(helper)")
        guard let outputDeviceName = preferredOutputDeviceName() else {
            setLastError("The VibeRemote audio device is not installed.")
            return
        }
        appendAppLog("Microphone bridge output device: \(outputDeviceName)")

        let escapedHelper = shellEscape(helper)
        let escapedFIFO = shellEscape(fifoPath)
        let escapedHelperLog = shellEscape(helperLogPath)

        guard prepareBridgeFIFOs(),
              writePrivateFile("", at: helperLogPath) else {
            if lastError == nil {
                setLastError("Could not prepare microphone bridge files.")
            }
            removeBridgeFIFOs()
            return
        }

        // Keep the helper in the logged-in user's CoreAudio session. Only PacketLogger
        // needs elevated privileges; running the whole pipeline as root prevents audio
        // from reaching the user's BlackHole device reliably.
        let helperCommand = """
        exec \(escapedHelper) < \(escapedFIFO) >> \(escapedHelperLog) 2>&1
        """
        let helperRunner = Process()
        helperRunner.executableURL = URL(fileURLWithPath: "/bin/bash")
        helperRunner.arguments = ["-c", helperCommand]

        let supervisorToken = UUID().uuidString.uppercased()
        appendAppLog("Microphone bridge starting PacketLogger supervisor")
        let pid: Int32
        switch startPacketLoggerSupervisor(
            packetLogger: packetLogger,
            packetLoggerApp: packetLoggerApp,
            userHelper: helper,
            supervisorToken: supervisorToken
        ) {
        case .started(let supervisorPID):
            pid = supervisorPID
        case .failed(let message):
            setLastError(message)
            stopUserHelper()
            removeBridgeFIFOs()
            return
        }
        let identity = SupervisorIdentity(pid: pid, token: supervisorToken)
        guard packetLoggerSupervisorMatches(identity) else {
            setLastError("The privileged PacketLogger supervisor could not be verified.")
            _ = writePrivateFile("stop\n", at: stopSignalPath)
            removeBridgeFIFOs()
            return
        }
        packetLoggerIdentity = identity
        guard writePrivateFile("\(pid) \(supervisorToken)\n", at: packetLoggerPIDFilePath) else {
            setLastError("Could not record the verified PacketLogger supervisor identity.")
            stopPacketLogger()
            removeBridgeFIFOs()
            return
        }
        do {
            try helperRunner.run()
            helperProcess = helperRunner
            helperPID = helperRunner.processIdentifier
            guard writePrivateFile("\(helperRunner.processIdentifier)\n", at: helperPIDFilePath) else {
                throw NSError(
                    domain: "VibeRemote.MicrophoneBridge",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not record the voice-helper identity."]
                )
            }
            appendAppLog("Microphone bridge helper runner started pid=\(helperRunner.processIdentifier)")
        } catch {
            setLastError("Could not start voice helper: \(error.localizedDescription)")
            stopPacketLogger()
            removeBridgeFIFOs()
            return
        }
        guard captureDefaultInputDevice() else {
            setLastError("Could not save the current default input device for later restoration.")
            stopLocked()
            return
        }
        guard setDefaultInputDevice(named: outputDeviceName) else {
            setLastError("Could not select \(outputDeviceName) as the default input device.")
            stopLocked()
            return
        }
        Thread.sleep(forTimeInterval: 1.5)
        if packetLoggerDisconnected() {
            setLastError("PacketLogger disconnected from OS X Device. Live Bluetooth capture is unavailable.")
            stopLocked()
            return
        }
        if liveHelperPID() == nil || livePacketLoggerIdentity() == nil {
            setLastError("The microphone bridge exited during startup.")
            stopLocked()
            return
        }
        clearLastError()
        appendAppLog("Microphone bridge started successfully pid=\(pid)")
    }

    /// Starts the root capture supervisor, preferring the approved privileged helper daemon
    /// (no password prompt) and falling back to a one-off administrator authorization when
    /// the daemon is unavailable or predates the capture capability.
    private enum SupervisorStartOutcome {
        case started(Int32)
        case failed(String)
    }

    private func startPacketLoggerSupervisor(
        packetLogger: String,
        packetLoggerApp: String,
        userHelper: String,
        supervisorToken: String
    ) -> SupervisorStartOutcome {
        if let viaHelper = startSupervisorViaPrivilegedHelper(
            packetLogger: packetLogger,
            userHelper: userHelper,
            supervisorToken: supervisorToken
        ) {
            return viaHelper
        }
        return startSupervisorViaAdministratorPrompt(
            packetLogger: packetLogger,
            packetLoggerApp: packetLoggerApp,
            userHelper: userHelper,
            supervisorToken: supervisorToken
        )
    }

    /// Returns nil when the daemon cannot be used, which sends the caller to the prompt path.
    /// A returned failure is final: the daemon ran the same validated script the prompt path
    /// would run, so re-prompting the user could only fail the same way.
    private func startSupervisorViaPrivilegedHelper(
        packetLogger: String,
        userHelper: String,
        supervisorToken: String
    ) -> SupervisorStartOutcome? {
        guard PrivilegedHelperClient.shared.state == .ready else { return nil }
        // An approved daemon keeps running the binary it launched with, which may predate
        // this capability. Probe its version instead of sending a selector it may lack.
        guard let version = fetchPrivilegedHelperVersion(timeout: 10) else {
            appendAppLog("Microphone bridge helper did not answer a version probe; falling back to an administrator prompt")
            return nil
        }
        guard version >= HelperConstants.packetLoggerCaptureMinimumVersion else {
            appendAppLog("Microphone bridge helper is version \(version), needs \(HelperConstants.packetLoggerCaptureMinimumVersion); falling back to an administrator prompt (restarting the daemon picks up the new binary)")
            return nil
        }
        appendAppLog("Microphone bridge starting the supervisor via the privileged helper")
        let outcome = ValueBox<(pid: Int32, message: String?)>()
        let semaphore = DispatchSemaphore(value: 0)
        PrivilegedHelperClient.shared.startPacketLoggerCapture(
            packetLoggerExecutablePath: packetLogger,
            runtimeDirectoryPath: runtimeDirectoryPath,
            voiceHelperPath: userHelper,
            supervisorToken: supervisorToken
        ) { pid, message in
            outcome.store((pid, message))
            semaphore.signal()
        }
        // Root-side codesign --deep of PacketLogger.app plus daemon setup takes seconds,
        // not minutes; a hang beyond this is a failure, not a reason to also prompt.
        guard semaphore.wait(timeout: .now() + 60) == .success,
              let result = outcome.value else {
            return .failed("The VibeRemote helper did not finish starting the capture supervisor in time.")
        }
        guard result.pid > 1 else {
            return .failed(result.message ?? "The VibeRemote helper could not start the capture supervisor.")
        }
        return .started(result.pid)
    }

    private func fetchPrivilegedHelperVersion(timeout: TimeInterval) -> Int? {
        let outcome = ValueBox<Int?>()
        let semaphore = DispatchSemaphore(value: 0)
        PrivilegedHelperClient.shared.fetchVersion { version, _ in
            outcome.store(version)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return outcome.value ?? nil
    }

    /// The pre-daemon path: one `osascript … with administrator privileges` run of the same
    /// shared supervisor script, raising a password prompt.
    private func startSupervisorViaAdministratorPrompt(
        packetLogger: String,
        packetLoggerApp: String,
        userHelper: String,
        supervisorToken: String
    ) -> SupervisorStartOutcome {
        let command = privilegedPacketLoggerCommand(
            packetLogger: packetLogger,
            packetLoggerApp: packetLoggerApp,
            userHelper: userHelper,
            supervisorToken: supervisorToken
        )
        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = ["-e", "do shell script \(appleScriptString(command)) with administrator privileges"]

        let out = Pipe()
        let err = Pipe()
        osa.standardOutput = out
        osa.standardError = err

        do {
            try osa.run()
        } catch {
            return .failed("Could not start microphone bridge: \(error.localizedDescription)")
        }
        osa.waitUntilExit()
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        appendAppLog("Microphone bridge osascript exit=\(osa.terminationStatus) output=\(output) error=\(errorText)")
        guard osa.terminationStatus == 0, let pid = Int32(output) else {
            return .failed(errorText.isEmpty ? "Could not start microphone bridge." : errorText)
        }
        return .started(pid)
    }

    /// One-shot storage a @Sendable XPC reply can fill while the work queue waits on it.
    private final class ValueBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: T?

        func store(_ value: T) {
            lock.lock()
            defer { lock.unlock() }
            if stored == nil { stored = value }
        }

        var value: T? {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    func stop() {
        syncOnWorkQueue {
            stopLocked()
        }
    }

    private func stopLocked() {
        stopUserHelper()
        stopPacketLogger()
        removeBridgeFIFOs()
        restoreDefaultInputDevice()
    }

    func maintainBridgeHealth() {
        workQueue.async { [weak self] in
            guard let self else { return }
            let running = self.isRunningLocked()
            if !running {
                if self.previousDefaultInputDeviceID != nil {
                    self.setLastError("The microphone bridge stopped unexpectedly; restoring the previous input device.")
                    self.stopLocked()
                }
                return
            }
            if let outputDeviceName = self.preferredOutputDeviceName(),
               self.defaultInputDeviceName() != outputDeviceName {
                _ = self.setDefaultInputDevice(named: outputDeviceName)
            }
        }
    }

    func startAsync(completion: (@Sendable () -> Void)? = nil) {
        workQueue.async { [weak self] in
            self?.startLocked()
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    func restartAsync(completion: (@Sendable () -> Void)? = nil) {
        workQueue.async { [weak self] in
            self?.stopLocked()
            self?.startLocked()
            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    /// True when the bundled audio driver is present in the app bundle and can be installed.
    var bundledAudioDriverAvailable: Bool {
        bundledAudioDriverPath() != nil
    }

    private func bundledAudioDriverPath() -> String? {
        guard let resourcePath = appBundle.resourcePath else { return nil }
        let path = "\(resourcePath)/\(Self.audioDriverBundleName)"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Installs the bundled VibeRemote audio driver into the system HAL plug-in directory and
    /// restarts coreaudiod so the device appears immediately. Prefers the privileged helper so
    /// no administrator prompt is needed; falls back to a one-off authorization otherwise.
    func installAudioDriver(completion: (@Sendable (Bool, String?) -> Void)? = nil) {
        workQueue.async { [weak self] in
            guard let self else { return }
            guard let source = self.bundledAudioDriverPath() else {
                let message = "The bundled VibeRemote audio driver is missing from this build."
                self.setLastError(message)
                DispatchQueue.main.async { completion?(false, message) }
                return
            }

            if PrivilegedHelperClient.shared.state == .ready {
                PrivilegedHelperClient.shared.installAudioDriver(fromPath: source) { [weak self] succeeded, message in
                    guard let self else { return }
                    if succeeded {
                        self.appendAppLog("Installed the VibeRemote audio driver via the helper")
                        self.workQueue.async {
                            Thread.sleep(forTimeInterval: 2.0)
                            let installed = self.preferredOutputDeviceName() != nil
                            if installed { self.clearLastError() }
                            DispatchQueue.main.async {
                                completion?(installed, installed ? nil : "The driver was installed but no virtual audio device appeared yet.")
                            }
                        }
                        return
                    }
                    // The helper is registered but could not do the work; surface why rather
                    // than silently falling back to a password prompt.
                    let failure = message ?? "The VibeRemote helper could not install the audio driver."
                    self.setLastError(failure)
                    DispatchQueue.main.async { completion?(false, failure) }
                }
                return
            }

            let destination = "\(Self.halPlugInDirectory)/\(Self.audioDriverBundleName)"
            let command = """
            set -eu
            /bin/rm -rf \(self.shellEscape(destination))
            /usr/bin/install -d -o root -g wheel -m 755 \(self.shellEscape(Self.halPlugInDirectory))
            /bin/cp -R \(self.shellEscape(source)) \(self.shellEscape(Self.halPlugInDirectory))/
            /usr/sbin/chown -R root:wheel \(self.shellEscape(destination))
            /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod
            """

            let osa = Process()
            osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            osa.arguments = [
                "-e",
                "do shell script \(self.appleScriptString(command)) with administrator privileges",
            ]
            let errorPipe = Pipe()
            osa.standardError = errorPipe
            osa.standardOutput = FileHandle.nullDevice

            do {
                try osa.run()
                let errorText = String(
                    data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                osa.waitUntilExit()
                guard osa.terminationStatus == 0 else {
                    let message = errorText.isEmpty
                        ? "Installing the VibeRemote audio driver was cancelled or failed."
                        : errorText
                    self.setLastError(message)
                    DispatchQueue.main.async { completion?(false, message) }
                    return
                }
                self.appendAppLog("Installed the VibeRemote audio driver")
                // coreaudiod needs a moment to publish the new device.
                Thread.sleep(forTimeInterval: 2.0)
                let installed = self.preferredOutputDeviceName() != nil
                if installed {
                    self.clearLastError()
                }
                DispatchQueue.main.async { completion?(installed, installed ? nil : "The driver was installed but no virtual audio device appeared yet.") }
            } catch {
                let message = "Could not install the VibeRemote audio driver: \(error.localizedDescription)"
                self.setLastError(message)
                DispatchQueue.main.async { completion?(false, message) }
            }
        }
    }

    func openPacketCaptureLog() {
        openFile(path: directHIDCapturePath)
    }

    func openHelperLog() {
        openFile(path: helperLogPath)
    }

    func openAppLog() {
        openFile(path: appLogPath)
    }

    @MainActor
    func promptForRemoteAddress() {
        let alert = NSAlert()
        alert.messageText = "Siri Remote Bluetooth Address"
        alert.informativeText = "Enter the Siri Remote address, for example AA:BB:CC:DD:EE:FF."
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = configuredOrDetectedRemoteAddress() ?? ""
        alert.accessoryView = input
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let normalized = normalizeAddress(input.stringValue)
        if normalized.isEmpty {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.remoteAddress)
        } else {
            UserDefaults.standard.set(normalized, forKey: DefaultsKey.remoteAddress)
        }
        restartBridgeIfActive()
    }

    @MainActor
    func promptForPacketLogger() {
        let panel = NSOpenPanel()
        panel.title = "Choose PacketLogger.app"
        panel.message = "Select Apple's signed PacketLogger.app. Standalone executables are not accepted."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let appPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        let path = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/Resources/packetlogger")
            .path
        let validationError = packetLoggerValidationError(executablePath: path, appPath: appPath)
        if url.pathExtension.lowercased() == "app",
           validationError == nil {
            UserDefaults.standard.set(path, forKey: DefaultsKey.packetLoggerPath)
            restartBridgeIfActive()
        } else {
            syncOnWorkQueue {
                setLastError(
                    validationError ?? "Select Apple's signed PacketLogger.app bundle."
                )
            }
        }
    }

    private func restartBridgeIfActive() {
        guard syncOnWorkQueue({ isRunningLocked() }) else { return }
        restartAsync()
    }

    private func openFile(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func setLastError(_ message: String) {
        lastError = message
        appendAppLog("Microphone bridge error: \(message)")
    }

    private func clearLastError() {
        lastError = nil
    }

    private func appendAppLog(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: appLogPath),
           let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: appLogPath)) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            _ = try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: appLogPath), options: .atomic)
        }
    }

    private func pidIsAlive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func liveHelperPID() -> Int32? {
        if let helperProcess, helperProcess.isRunning {
            return helperProcess.processIdentifier
        }
        let candidates = [helperPID, readStoredPID(at: helperPIDFilePath)].compactMap { $0 }
        return candidates.first(where: helperPIDMatches)
    }

    private func livePacketLoggerIdentity() -> SupervisorIdentity? {
        if let packetLoggerIdentity, packetLoggerSupervisorMatches(packetLoggerIdentity) {
            return packetLoggerIdentity
        }
        guard let storedIdentity = readStoredSupervisorIdentity(),
              packetLoggerSupervisorMatches(storedIdentity) else {
            return nil
        }
        return storedIdentity
    }

    private func stopUserHelper() {
        if let helperInputPipe {
            try? helperInputPipe.fileHandleForWriting.close()
            self.helperInputPipe = nil
        }
        if let helperProcess {
            if helperProcess.isRunning {
                helperProcess.terminate()
                waitForExit(pid: helperProcess.processIdentifier, timeout: 1.0)
                if helperProcess.isRunning {
                    kill(helperProcess.processIdentifier, SIGKILL)
                }
            }
        } else if let pid = liveHelperPID(), helperPIDMatches(pid) {
            kill(pid, SIGTERM)
            waitForExit(pid: pid, timeout: 1.0)
            if helperPIDMatches(pid) {
                kill(pid, SIGKILL)
            }
        }
        helperProcess = nil
        helperPID = nil
        removePrivateItem(at: helperPIDFilePath)
    }

    private func stopPacketLogger() {
        guard directoryIsPrivate(runtimeDirectoryPath) else {
            packetLoggerIdentity = nil
            return
        }
        let identity = livePacketLoggerIdentity()
        _ = writePrivateFile("stop\n", at: stopSignalPath)
        if let identity {
            waitForExit(pid: identity.pid, timeout: 4.0)
            if packetLoggerSupervisorMatches(identity) {
                appendAppLog("Microphone bridge supervisor did not stop before timeout; leaving its validated stop signal in place")
                packetLoggerIdentity = identity
                return
            }
        }
        packetLoggerIdentity = nil
        removePrivateItem(at: packetLoggerPIDFilePath)
    }

    private func prepareBridgeFIFOs() -> Bool {
        guard prepareRuntimeDirectory() else { return false }
        removeBridgeFIFOs()
        for path in [fifoPath, packetLoggerFIFOPath] {
            guard mkfifo(path, 0o600) == 0 else {
                let errorNumber = errno
                let errorText = String(cString: strerror(errorNumber))
                setLastError("Could not create microphone bridge FIFO: \(errorText) (\(errorNumber)).")
                removeBridgeFIFOs()
                return false
            }
        }
        return true
    }

    private func removeBridgeFIFOs() {
        removePrivateItem(at: fifoPath)
        removePrivateItem(at: packetLoggerFIFOPath)
    }

    private static func defaultRuntimeDirectoryPath() -> String {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return baseURL
            .appendingPathComponent("VibeRemote", isDirectory: true)
            .appendingPathComponent("MicrophoneBridge", isDirectory: true)
            .path
    }

    private func runtimePath(_ name: String) -> String {
        (runtimeDirectoryPath as NSString).appendingPathComponent(name)
    }

    private func prepareRuntimeDirectory() -> Bool {
        let runtimeURL = URL(fileURLWithPath: runtimeDirectoryPath, isDirectory: true)
        let parentURL = runtimeURL.deletingLastPathComponent()

        for url in [parentURL, runtimeURL] {
            if FileManager.default.fileExists(atPath: url.path) {
                guard directoryIsOwnedByCurrentUser(url.path) else {
                    setLastError("Microphone runtime path is not a private directory: \(url.path)")
                    return false
                }
            } else {
                do {
                    try FileManager.default.createDirectory(
                        at: url,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: NSNumber(value: 0o700)]
                    )
                } catch {
                    setLastError("Could not create the private microphone runtime directory: \(error.localizedDescription)")
                    return false
                }
            }
            guard clearAccessControlList(at: url.path),
                  chmod(url.path, 0o700) == 0,
                  directoryIsPrivate(url.path) else {
                setLastError("Could not secure the microphone runtime directory: \(url.path)")
                return false
            }
        }
        return true
    }

    private func clearAccessControlList(at path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["-N", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func directoryIsOwnedByCurrentUser(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
    }

    private func directoryIsPrivate(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
            && info.st_uid == getuid()
            && (info.st_mode & 0o777) == 0o700
    }

    @discardableResult
    private func writePrivateFile(_ contents: String, at path: String) -> Bool {
        guard path.hasPrefix(runtimeDirectoryPath + "/"), directoryIsPrivate(runtimeDirectoryPath) else {
            return false
        }

        var template = Array("\(path).tmp.XXXXXX".utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in
            mkstemp(buffer.baseAddress!)
        }
        guard descriptor >= 0 else { return false }

        let temporaryPath = String(cString: template)
        var succeeded = false
        defer {
            close(descriptor)
            if !succeeded {
                unlink(temporaryPath)
            }
        }

        guard fchmod(descriptor, 0o600) == 0,
              let data = contents.data(using: .utf8) else {
            return false
        }

        let writeSucceeded = data.withUnsafeBytes { rawBuffer -> Bool in
            guard var baseAddress = rawBuffer.baseAddress else { return data.isEmpty }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let count = Darwin.write(descriptor, baseAddress, remaining)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= count
                baseAddress = baseAddress.advanced(by: count)
            }
            return true
        }
        guard writeSucceeded, fsync(descriptor) == 0,
              rename(temporaryPath, path) == 0 else {
            return false
        }
        succeeded = true
        return true
    }

    @discardableResult
    private func appendPrivateData(_ data: Data, at path: String) -> Bool {
        guard path.hasPrefix(runtimeDirectoryPath + "/"),
              directoryIsPrivate(runtimeDirectoryPath) else {
            return false
        }
        if !FileManager.default.fileExists(atPath: path), !writePrivateFile("", at: path) {
            return false
        }

        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o600 else {
            return false
        }

        let descriptor = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        return data.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress else { return data.isEmpty }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                guard written > 0 else { return false }
                cursor = cursor.advanced(by: written)
                remaining -= written
            }
            return true
        }
    }

    private func readPrivateFile(at path: String, maxBytes: Int = 4_096) -> String? {
        guard path.hasPrefix(runtimeDirectoryPath + "/"), directoryIsPrivate(runtimeDirectoryPath) else {
            return nil
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= maxBytes else {
            return nil
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(maxBytes, 1_024))
        while data.count < maxBytes {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, min(rawBuffer.count, maxBytes - data.count))
            }
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                return nil
            }
            data.append(buffer, count: bytesRead)
        }
        return String(data: data, encoding: .utf8)
    }

    private func removePrivateItem(at path: String) {
        guard path.hasPrefix(runtimeDirectoryPath + "/"), directoryIsPrivate(runtimeDirectoryPath) else {
            return
        }
        unlink(path)
    }

    private func readStoredPID(at path: String) -> Int32? {
        guard let text = readPrivateFile(at: path),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1 else {
            return nil
        }
        return pid
    }

    private func readStoredSupervisorIdentity() -> SupervisorIdentity? {
        guard let text = readPrivateFile(at: packetLoggerPIDFilePath) else { return nil }
        let fields = text.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 2,
              let pid = Int32(fields[0]), pid > 1,
              let uuid = UUID(uuidString: String(fields[1])) else {
            return nil
        }
        return SupervisorIdentity(pid: pid, token: uuid.uuidString.uppercased())
    }

    private func processExecutablePath(pid: Int32) -> String? {
        guard pid > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN * 4))
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer))
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func helperPIDMatches(_ pid: Int32) -> Bool {
        guard pidIsAlive(pid), let helper = helperExecutablePath() else { return false }
        let expected = URL(fileURLWithPath: helper).standardizedFileURL.resolvingSymlinksInPath().path
        return processExecutablePath(pid: pid) == expected
    }

    private func packetLoggerSupervisorMatches(_ identity: SupervisorIdentity) -> Bool {
        guard pidIsAlive(identity.pid),
              ["/bin/bash", "/bin/sh"].contains(processExecutablePath(pid: identity.pid) ?? ""),
              let process = processUIDAndCommand(pid: identity.pid),
              process.uid == 0 else {
            return false
        }
        return process.command.contains("viberemote_supervisor_token=\(identity.token)")
            && process.command.contains(runtimeDirectoryPath)
    }

    private func processUIDAndCommand(pid: Int32) -> (uid: uid_t, command: String)? {
        guard pid > 1 else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-p", String(pid), "-o", "uid=", "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let output = String(data: outputData, encoding: .utf8) else {
                return nil
            }
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            guard parts.count == 2, let uid = uid_t(parts[0]) else { return nil }
            return (uid, String(parts[1]))
        } catch {
            return nil
        }
    }

    private func waitForExit(pid: Int32, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while pidIsAlive(pid), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func syncOnWorkQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: workQueueKey) != nil {
            return body()
        }
        return workQueue.sync(execute: body)
    }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func configuredOrDetectedRemoteAddress() -> String? {
        if let configured = configuredRemoteAddress() { return configured }
        return detectRemoteAddress()
    }

    private func configuredRemoteAddress() -> String? {
        guard let configured = UserDefaults.standard.string(forKey: DefaultsKey.remoteAddress),
              !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return normalizeAddress(configured)
    }

    private func detectRemoteAddress() -> String? {
        // IOBluetooth can synchronously block while TCC is unresolved. Discovery is optional
        // and must never initiate Bluetooth authorization as a side effect of menu rendering.
        guard CBManager.authorization == .allowedAlways else { return nil }
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return nil }
        for device in devices {
            let name = (device.name ?? "").lowercased()
            guard name.contains("remote") || name.contains("siri") || name.contains("apple tv") else { continue }
            if let address = device.addressString {
                return normalizeAddress(address)
            }
        }
        return nil
    }

    private func packetLoggerExecutablePath() -> String? {
        var candidates: [String] = []
        if let configured = UserDefaults.standard.string(forKey: DefaultsKey.packetLoggerPath) {
            candidates.append(configured)
        }
        candidates.append(contentsOf: [
            appBundle.resourcePath.map { "\($0)/PacketLogger.app/Contents/Resources/packetlogger" },
            "/Applications/Additional Tools for Xcode/Hardware/PacketLogger.app/Contents/Resources/packetlogger",
            "/Applications/Additional Tools/Hardware/PacketLogger.app/Contents/Resources/packetlogger",
            "\(NSHomeDirectory())/Desktop/SiriRemote/PacketLogger.app/Contents/Resources/packetlogger",
            "\(NSHomeDirectory())/Downloads/Additional Tools for Xcode/Hardware/PacketLogger.app/Contents/Resources/packetlogger",
            "\(NSHomeDirectory())/Downloads/Additional Tools/Hardware/PacketLogger.app/Contents/Resources/packetlogger",
        ].compactMap { $0 })

        for candidate in candidates {
            let executablePath = URL(fileURLWithPath: candidate)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
            guard let appPath = packetLoggerAppPath(for: executablePath),
                  packetLoggerValidationError(executablePath: executablePath, appPath: appPath) == nil else {
                continue
            }
            return executablePath
        }
        return nil
    }

    private func packetLoggerAppPath(for executablePath: String) -> String? {
        PacketLoggerBridge.appBundlePath(forExecutablePath: executablePath)
    }

    private func packetLoggerValidationError(executablePath: String, appPath: String) -> String? {
        guard packetLoggerAppPath(for: executablePath) == appPath,
              FileManager.default.isExecutableFile(atPath: executablePath),
              FileManager.default.fileExists(atPath: appPath),
              Bundle(url: URL(fileURLWithPath: appPath))?.bundleIdentifier == "com.apple.PacketLogger" else {
            return "PacketLogger must be Apple's PacketLogger.app with its original bundle structure."
        }

        if let error = codeSignatureError(
            path: appPath,
            requirement: "identifier \"com.apple.PacketLogger\" and anchor apple",
            deep: true
        ) {
            return "PacketLogger.app failed Apple signature validation: \(error)"
        }
        if let error = codeSignatureError(
            path: executablePath,
            requirement: "identifier \"com.apple.packetlogger\" and anchor apple"
        ) {
            return "The packetlogger executable failed Apple signature validation: \(error)"
        }
        guard let helperPath = packetLoggerSystemHelperSourcePath(for: executablePath) else {
            return "PacketLogger.app does not contain PacketLoggerHelper."
        }
        if let error = codeSignatureError(
            path: helperPath,
            requirement: "identifier \"com.apple.bluetooth.PacketLoggerHelper\" and anchor apple"
        ) {
            return "PacketLoggerHelper failed Apple signature validation: \(error)"
        }
        return nil
    }

    private func codeSignatureError(path: String, requirement: String, deep: Bool = false) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        var arguments = ["--verify", "--strict"]
        if deep {
            arguments.append("--deep")
        }
        arguments.append("-R=\(requirement)")
        arguments.append(path)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        do {
            try process.run()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus != 0 else { return nil }
            let message = String(
                data: errorData,
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines)
            return message?.isEmpty == false ? message! : "codesign exited with status \(process.terminationStatus)"
        } catch {
            return error.localizedDescription
        }
    }

    private func packetLoggerSystemHelperSourcePath(for packetLogger: String) -> String? {
        guard let appPath = packetLoggerAppPath(for: packetLogger) else { return nil }
        let helperPath = PacketLoggerBridge.systemHelperSourcePath(forAppBundlePath: appPath)
        return FileManager.default.isExecutableFile(atPath: helperPath) ? helperPath : nil
    }

    private func packetLoggerSystemHelperInstalled() -> Bool {
        packetLoggerSystemHelperInstalledAndValid()
    }

    private func packetLoggerSystemHelperInstalledAndValid() -> Bool {
        FileManager.default.isExecutableFile(atPath: packetLoggerHelperInstallPath)
            && FileManager.default.fileExists(atPath: packetLoggerHelperPlistPath)
            && codeSignatureError(
                path: packetLoggerHelperInstallPath,
                requirement: "identifier \"com.apple.bluetooth.PacketLoggerHelper\" and anchor apple"
            ) == nil
    }

    private func bluetoothPacketLoggingConfigured() -> Bool {
        guard let dict = NSDictionary(contentsOfFile: bluetoothDebugPreferencesPath) as? [String: Any],
              let hciTraces = dict["HCITraces"] as? [String: Any],
              let hci = dict["HCI"] as? [String: Any],
              let fw = dict["FWStreamLogging"] as? [String: Any] else {
            return false
        }
        return boolValue(hciTraces["StackDebugEnabled"])
            && boolValue(hci["lmpRouting"])
            && boolValue(fw["FWCoreDumpEnable"])
            && boolValue(fw["FWStreamLoggingEnable"])
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let bool = value as? Bool {
            return bool
        }
        return false
    }

    private func tailText(path: String, maxBytes: UInt64) -> String {
        guard FileManager.default.fileExists(atPath: path) else {
            return ""
        }
        let size = fileSize(path: path)
        guard size > 0 else {
            return ""
        }
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            if size > maxBytes {
                try handle.seek(toOffset: size - maxBytes)
            }
            let data = handle.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        } catch {
            return ""
        }
    }

    private func nonEmptyLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func lastNonEmptyLine(path: String) -> String? {
        nonEmptyLines(tailText(path: path, maxBytes: 64 * 1024)).last
    }

    private func fileSize(path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.size] as? UInt64 ?? 0
    }

    private func fileAgeDescription(path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else {
            return "missing"
        }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 2 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    private func reverseAddressByteString(_ address: String) -> String {
        address
            .split(separator: ":")
            .reversed()
            .joined(separator: " ")
            .uppercased()
    }

    private func rawBytes(fromPacketLine line: String) -> [String]? {
        let marker: String
        if line.contains(" RECV ") {
            marker = " RECV "
        } else if line.contains(" SEND ") {
            marker = " SEND "
        } else {
            return nil
        }
        guard let range = line.range(of: marker) else { return nil }
        return line[range.upperBound...]
            .split(separator: " ")
            .map { String($0).uppercased() }
    }

    private func isOldSiriRemoteAudioFrame(_ line: String) -> Bool {
        guard let bytes = rawBytes(fromPacketLine: line), bytes.count == 31 else {
            return false
        }
        return bytes[0] == "40" && bytes[1] == "20" && bytes.indices.contains(18) && bytes[18] == "B8"
    }

    private func isNewSiriRemoteVoiceFrame(_ line: String) -> Bool {
        guard let bytes = rawBytes(fromPacketLine: line),
              bytes.indices.contains(16) else {
            return false
        }
        return bytes[1] == "20"
            && bytes[8] == "1B"
            && bytes[9] == "35"
            && bytes[16] == "B8"
    }

    private func isNewSiriRemoteVoiceContinuation(_ line: String) -> Bool {
        guard let bytes = rawBytes(fromPacketLine: line),
              bytes.count > 4 else {
            return false
        }
        return bytes[1] == "10"
    }

    private func isNewSiriRemoteVoiceEnd(_ line: String) -> Bool {
        guard let bytes = rawBytes(fromPacketLine: line),
              bytes.indices.contains(9) else {
            return false
        }
        return bytes[1] == "20"
            && bytes[8] == "1B"
            && bytes[9] == "39"
    }

    private func packetCaptureSize() -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: packetCapturePath)
        return attrs?[.size] as? UInt64 ?? 0
    }

    private func packetLoggerDisconnected() -> Bool {
        [packetLoggerLogPath, packetCapturePath, packetLoggerSessionPath].contains { path in
            lastNonEmptyLine(path: path)?.contains("Disconnected from OS X Device") == true
        }
    }

    private func diagnosticsBlockingIssues(
        helperAlive: Bool,
        packetLoggerAlive: Bool,
        packetLoggerDisconnected: Bool,
        outputDeviceName: String?,
        defaultInputDeviceName: String?,
        remoteLineCount: Int,
        oldVoiceStartCount: Int,
        oldAudioFrameCount: Int,
        newVoiceFrameCount: Int,
        newVoiceContinuationCount: Int,
        directHIDReportCount: Int,
        lastDirectGATTLine: String?
    ) -> [String] {
        var issues: [String] = []
        if outputDeviceName == nil {
            issues.append("The VibeRemote audio device is missing.")
        } else if defaultInputDeviceName != outputDeviceName {
            issues.append("System default input is \(defaultInputDeviceName ?? "unknown"), not \(outputDeviceName ?? "VibeRemote").")
        }
        if !helperAlive {
            issues.append("Voice helper is not running.")
        }
        if lastDirectGATTLine?.contains("waiting for Bluetooth permission") == true {
            issues.append("Bluetooth audio permission is required. Choose Allow Bluetooth Audio in the main menu.")
        } else if helperAlive && directHIDReportCount == 0 {
            issues.append("No Direct HID audio reports have arrived. Hold the Siri button and speak, then refresh diagnostics.")
        }
        return issues
    }

    private func privilegedPacketLoggerCommand(
        packetLogger: String,
        packetLoggerApp: String,
        userHelper: String,
        supervisorToken: String
    ) -> String {
        // The script itself lives in the shared HelperProtocol target so this fallback and
        // the privileged helper daemon run byte-identical supervisors.
        let helperSource = packetLoggerSystemHelperSourcePath(for: packetLogger) ?? "/dev/null"
        return PacketLoggerBridge.supervisorCommand(
            packetLogger: packetLogger,
            packetLoggerApp: packetLoggerApp,
            helperSource: helperSource,
            userHelper: userHelper,
            runtimeDirectory: runtimeDirectoryPath,
            ownerPID: getpid(),
            ownerUID: getuid(),
            supervisorToken: supervisorToken
        )
    }

    private func helperExecutablePath() -> String? {
        let candidates = [
            appBundle.resourcePath.map { "\($0)/SiriRemoteVoiceControl/VibeRemoteVoiceBridge" },
            appBundle.resourcePath.map { "\($0)/SiriRemoteVoiceControl/SiriRemoteVoiceControl-BlackHole" },
            "\(FileManager.default.currentDirectoryPath)/VibeRemoteVoiceBridge",
            "\(FileManager.default.currentDirectoryPath)/Vendor/SiriRemoteVoiceControl/SiriRemoteVoiceControl-BlackHole",
            appBundle.resourcePath.map { "\($0)/SiriRemoteVoiceControl/SiriRemoteVoiceControl" },
            "\(FileManager.default.currentDirectoryPath)/Vendor/SiriRemoteVoiceControl/SiriRemoteVoiceControl",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Virtual audio devices the bridge can play into, most preferred first. "VibeRemote" is
    /// the driver we bundle and install ourselves; the others are honored so an existing
    /// BlackHole/Soundflower setup keeps working.
    static let supportedOutputDeviceNames = ["VibeRemote", "BlackHole 2ch", "Soundflower (2ch)"]

    static let audioDriverBundleName = "VibeRemoteAudio.driver"
    static let halPlugInDirectory = "/Library/Audio/Plug-Ins/HAL"

    private func preferredOutputDeviceName() -> String? {
        Self.supportedOutputDeviceNames.first { audioDeviceID(named: $0) != nil }
    }

    private func audioDeviceID(named expectedName: String) -> AudioDeviceID? {
        var size: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else {
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = Array(repeating: AudioDeviceID(), count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devices) == noErr else {
            return nil
        }
        return devices.first { deviceName($0) == expectedName }
    }

    @discardableResult
    private func setDefaultInputDevice(named expectedName: String) -> Bool {
        guard let deviceID = audioDeviceID(named: expectedName) else {
            lastError = "\(expectedName) is not installed."
            return false
        }
        // A freshly installed virtual device can come up attenuated (observed at 0.47),
        // which buries remote speech under the noise floor and looks like "no audio".
        raiseInputVolumeIfNeeded(deviceID, name: expectedName)
        return setDefaultInputDevice(deviceID)
    }

    /// Ensures the virtual device's input volume is at unity so decoded speech is audible.
    private func raiseInputVolumeIfNeeded(_ id: AudioDeviceID, name: String) {
        // Element 0 is the master channel; per-channel elements are only touched if the
        // device does not expose a master control.
        for element in [UInt32(0), UInt32(1), UInt32(2)] {
            var addr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: element
            )
            guard AudioObjectHasProperty(id, &addr) else { continue }

            var volume: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &volume) == noErr else { continue }
            guard volume < 0.99 else {
                if element == 0 { return }
                continue
            }

            var unity: Float32 = 1.0
            let status = AudioObjectSetPropertyData(
                id,
                &addr,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &unity
            )
            if status == noErr {
                appendAppLog("Raised \(name) input volume from \(volume) to 1.0")
            }
            if element == 0 { return }
        }
    }

    @discardableResult
    private func setDefaultInputDevice(_ id: AudioDeviceID) -> Bool {
        var deviceID = id
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            size,
            &deviceID
        ) == noErr
    }

    private func captureDefaultInputDevice() -> Bool {
        loadPreviousInputDeviceIfNeeded()
        if previousDefaultInputDeviceID != nil {
            return true
        }
        guard let currentDeviceID = defaultInputDeviceID() else {
            return false
        }
        previousDefaultInputDeviceID = currentDeviceID
        guard writePrivateFile("\(currentDeviceID)\n", at: previousInputDeviceFilePath) else {
            previousDefaultInputDeviceID = nil
            return false
        }
        return true
    }

    private func loadPreviousInputDeviceIfNeeded() {
        guard previousDefaultInputDeviceID == nil,
              let text = readPrivateFile(at: previousInputDeviceFilePath),
              let deviceID = AudioDeviceID(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              deviceName(deviceID) != nil else {
            return
        }
        previousDefaultInputDeviceID = deviceID
    }

    private func restoreDefaultInputDevice() {
        loadPreviousInputDeviceIfNeeded()
        guard let deviceID = previousDefaultInputDeviceID else {
            removePrivateItem(at: previousInputDeviceFilePath)
            return
        }
        if setDefaultInputDevice(deviceID) {
            appendAppLog("Microphone bridge restored previous input device: \(deviceName(deviceID) ?? String(deviceID))")
            previousDefaultInputDeviceID = nil
            removePrivateItem(at: previousInputDeviceFilePath)
        } else {
            appendAppLog("Microphone bridge could not restore previous input device id=\(deviceID)")
        }
    }

    private func defaultInputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr else {
            return nil
        }
        return deviceID
    }

    private func defaultInputDeviceName() -> String? {
        defaultInputDeviceID().flatMap(deviceName)
    }

    private func deviceName(_ id: AudioDeviceID) -> String? {
        var name = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        return status == noErr ? (name as String) : nil
    }

    private func normalizeAddress(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: ":")
            .uppercased()
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptString(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
