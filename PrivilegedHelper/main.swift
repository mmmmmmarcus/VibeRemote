//
//  main.swift
//  VibeRemoteHelper
//
//  A root LaunchDaemon registered through SMAppService. The user approves it once, and it
//  then performs the privileged work the microphone bridge needs — installing the virtual
//  audio driver, and starting the root PacketLogger capture supervisor — so the app never
//  has to raise an administrator prompt again.
//
//  Every incoming XPC connection is validated against our own code-signing requirement
//  before any privileged work is done: this process runs as root, so an unverified peer
//  must never be able to drive it.
//

import Foundation
import HelperProtocol
import Security

private func helperLog(_ message: String) {
    // stdout/stderr are captured by the daemon's launchd log paths.
    print("\(Date()) \(message)")
    fflush(stdout)
}

final class HelperService: NSObject, NSXPCListenerDelegate {
    private let halPlugInDirectory = "/Library/Audio/Plug-Ins/HAL"
    private let audioDriverBundleName = "VibeRemoteAudio.driver"

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard clientIsTrusted(connection) else {
            helperLog("Rejected an XPC connection that failed code-signature validation")
            return false
        }
        // Each connection gets its own handler carrying the peer's uid and pid from the
        // connection itself. Privileged operations scope what they touch (and which process
        // lifetime they bind to) with these values, never with client-supplied ones.
        let handler = HelperRequestHandler(
            service: self,
            clientUID: connection.effectiveUserIdentifier,
            clientPID: connection.processIdentifier
        )
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = handler
        connection.resume()
        return true
    }

    /// Accepts only a peer signed by our Developer ID team with our bundle identifier.
    ///
    /// The audit token is the only race-free way to identify an XPC peer, but NSXPCConnection
    /// exposes it privately, so read it via KVC and fall back to the (less precise) pid when
    /// unavailable. Validation itself is the same either way.
    private func clientIsTrusted(_ connection: NSXPCConnection) -> Bool {
        let attributes: CFDictionary
        if let tokenValue = connection.value(forKey: "auditToken") as? NSValue {
            var token = audit_token_t()
            tokenValue.getValue(&token)
            let tokenData = withUnsafeBytes(of: &token) { Data($0) }
            attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        } else {
            helperLog("Audit token unavailable; validating the peer by pid")
            attributes = [kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)] as CFDictionary
        }

        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else {
            return false
        }

        let requirementText = """
        identifier "\(HelperConstants.expectedClientBundleID)" \
        and anchor apple generic \
        and certificate leaf[subject.OU] = "\(HelperConstants.expectedTeamIdentifier)"
        """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    // MARK: - Privileged capabilities (invoked via HelperRequestHandler)

    func installAudioDriver(fromPath sourcePath: String, reply: @escaping (Bool, String?) -> Void) {
        // The source must be a driver bundle inside a signed VibeRemote app; refuse anything
        // else so this cannot be used to drop arbitrary code into the system HAL directory.
        guard sourcePath.hasSuffix("/\(audioDriverBundleName)"),
              FileManager.default.fileExists(atPath: sourcePath),
              bundleIsTrusted(atPath: sourcePath) else {
            let message = "The audio driver at \(sourcePath) failed validation."
            helperLog(message)
            reply(false, message)
            return
        }

        let destination = "\(halPlugInDirectory)/\(audioDriverBundleName)"
        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination) {
                try fileManager.removeItem(atPath: destination)
            }
            try fileManager.createDirectory(
                atPath: halPlugInDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o755)]
            )
            try fileManager.copyItem(atPath: sourcePath, toPath: destination)
            try setOwnershipToRoot(at: destination)
            try restartCoreAudio()
            helperLog("Installed the audio driver at \(destination)")
            reply(true, nil)
        } catch {
            let message = "Installing the audio driver failed: \(error.localizedDescription)"
            helperLog(message)
            reply(false, message)
        }
    }

    /// Starts the root PacketLogger capture supervisor on behalf of the connected client.
    ///
    /// The supervisor script is the shared `PacketLoggerBridge` one — identical to what the
    /// app's administrator-prompt fallback runs — and it re-validates everything root-side:
    /// runtime directory ownership and 0700 mode against the client's uid, FIFO safety, and
    /// Apple code signatures on PacketLogger and PacketLoggerHelper before any system change.
    /// The client only chooses *which* validated things participate, never what root executes.
    func startPacketLoggerCapture(
        packetLoggerExecutablePath: String,
        runtimeDirectoryPath: String,
        voiceHelperPath: String,
        supervisorToken: String,
        clientUID: uid_t,
        clientPID: pid_t,
        reply: @escaping (Int32, String?) -> Void
    ) {
        // The token is interpolated into a shell command line (unquoted, by design, so the
        // app can find it in ps output). Accept only a canonical UUID.
        guard let token = UUID(uuidString: supervisorToken) else {
            reply(0, "The supervisor token is not a valid UUID.")
            return
        }
        guard packetLoggerExecutablePath.hasPrefix("/"),
              runtimeDirectoryPath.hasPrefix("/"),
              voiceHelperPath.hasPrefix("/") else {
            reply(0, "PacketLogger capture paths must be absolute.")
            return
        }
        guard let appPath = PacketLoggerBridge.appBundlePath(forExecutablePath: packetLoggerExecutablePath) else {
            reply(0, "PacketLogger must be the executable inside PacketLogger.app.")
            return
        }
        // Missing source is tolerated when a valid PacketLoggerHelper is already installed;
        // the script validates whichever it ends up using.
        let helperSourceCandidate = PacketLoggerBridge.systemHelperSourcePath(forAppBundlePath: appPath)
        let helperSource = FileManager.default.isExecutableFile(atPath: helperSourceCandidate)
            ? helperSourceCandidate
            : "/dev/null"

        let command = PacketLoggerBridge.supervisorCommand(
            packetLogger: packetLoggerExecutablePath,
            packetLoggerApp: appPath,
            helperSource: helperSource,
            userHelper: voiceHelperPath,
            runtimeDirectory: runtimeDirectoryPath,
            ownerPID: clientPID,
            ownerUID: clientUID,
            supervisorToken: token.uuidString.uppercased()
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            let message = "Could not launch the PacketLogger supervisor: \(error.localizedDescription)"
            helperLog(message)
            reply(0, message)
            return
        }
        // The setup phase exits quickly after backgrounding the supervisor (which holds no
        // pipe ends open), so reading to EOF here cannot hang on the capture itself.
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0, let pid = Int32(output), pid > 1 else {
            let message = errorText.isEmpty
                ? "The PacketLogger supervisor setup exited with status \(process.terminationStatus)."
                : errorText
            helperLog("PacketLogger capture start failed for uid \(clientUID): \(message)")
            reply(0, message)
            return
        }
        helperLog("Started the PacketLogger supervisor pid=\(pid) for uid \(clientUID) pid \(clientPID)")
        reply(pid, nil)
    }

    // MARK: - Privileged operations

    /// Validates that the bundle is signed by us, so root only ever copies our own code.
    private func bundleIsTrusted(atPath path: String) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        let requirementText = """
        anchor apple generic \
        and certificate leaf[subject.OU] = "\(HelperConstants.expectedTeamIdentifier)"
        """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementText as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            return false
        }
        return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
    }

    private func setOwnershipToRoot(at path: String) throws {
        let attributes: [FileAttributeKey: Any] = [
            .ownerAccountID: NSNumber(value: 0),
            .groupOwnerAccountID: NSNumber(value: 0),
        ]
        let fileManager = FileManager.default
        try fileManager.setAttributes(attributes, ofItemAtPath: path)
        guard let walker = fileManager.enumerator(atPath: path) else { return }
        for case let relative as String in walker {
            try? fileManager.setAttributes(attributes, ofItemAtPath: "\(path)/\(relative)")
        }
    }

    private func restartCoreAudio() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", "system/com.apple.audio.coreaudiod"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "VibeRemote.Helper",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Restarting coreaudiod failed."]
            )
        }
    }
}

/// The object actually exported over XPC: one per connection, so every privileged call is
/// bound to the identity (uid, pid) of the validated peer that made it.
final class HelperRequestHandler: NSObject, HelperProtocol {
    private let service: HelperService
    private let clientUID: uid_t
    private let clientPID: pid_t

    init(service: HelperService, clientUID: uid_t, clientPID: pid_t) {
        self.service = service
        self.clientUID = clientUID
        self.clientPID = clientPID
    }

    func helperVersion(reply: @escaping (Int) -> Void) {
        reply(HelperConstants.version)
    }

    func installAudioDriver(fromPath sourcePath: String, reply: @escaping (Bool, String?) -> Void) {
        service.installAudioDriver(fromPath: sourcePath, reply: reply)
    }

    func startPacketLoggerCapture(
        packetLoggerExecutablePath: String,
        runtimeDirectoryPath: String,
        voiceHelperPath: String,
        supervisorToken: String,
        reply: @escaping (Int32, String?) -> Void
    ) {
        service.startPacketLoggerCapture(
            packetLoggerExecutablePath: packetLoggerExecutablePath,
            runtimeDirectoryPath: runtimeDirectoryPath,
            voiceHelperPath: voiceHelperPath,
            supervisorToken: supervisorToken,
            clientUID: clientUID,
            clientPID: clientPID,
            reply: reply
        )
    }
}

helperLog("VibeRemote helper starting (version \(HelperConstants.version))")
let service = HelperService()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = service
listener.resume()
RunLoop.main.run()
