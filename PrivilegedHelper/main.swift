//
//  main.swift
//  VibeRemoteHelper
//
//  A root LaunchDaemon registered through SMAppService. The user approves it once, and it
//  then performs the privileged work the microphone bridge needs — installing the virtual
//  audio driver today, and the Bluetooth capture setup as that migrates over — so the app
//  never has to raise an administrator prompt again.
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

final class HelperService: NSObject, HelperProtocol, NSXPCListenerDelegate {
    private let halPlugInDirectory = "/Library/Audio/Plug-Ins/HAL"
    private let audioDriverBundleName = "VibeRemoteAudio.driver"

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard clientIsTrusted(connection) else {
            helperLog("Rejected an XPC connection that failed code-signature validation")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = self
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

    // MARK: - HelperProtocol

    func helperVersion(reply: @escaping (Int) -> Void) {
        reply(HelperConstants.version)
    }

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

helperLog("VibeRemote helper starting (version \(HelperConstants.version))")
let service = HelperService()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = service
listener.resume()
RunLoop.main.run()
