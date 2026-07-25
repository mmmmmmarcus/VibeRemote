//
//  PrivilegedHelperClient.swift
//  VibeRemote
//
//  App-side access to the privileged helper daemon. Registering the daemon asks the user for
//  approval once (System Settings › Login Items & Extensions); after that the app performs
//  privileged work over XPC with no administrator prompts.
//

import Foundation
import HelperProtocol
import ServiceManagement

enum PrivilegedHelperState: Equatable, Sendable {
    /// The daemon has never been registered, or the user removed it.
    case notRegistered
    /// Registered, but the user has not yet approved it in System Settings.
    case awaitingApproval
    /// Registered and approved; XPC calls should succeed.
    case ready
    /// This build cannot use a helper (registration requires macOS 13 or newer).
    case unsupported

    var needsUserAction: Bool {
        self == .notRegistered || self == .awaitingApproval
    }
}

final class PrivilegedHelperClient {
    static let shared = PrivilegedHelperClient()

    private let connectionLock = NSLock()
    private var storedConnection: NSXPCConnection?

    private init() {}

    // MARK: - Registration

    var state: PrivilegedHelperState {
        guard #available(macOS 13.0, *) else { return .unsupported }
        switch SMAppService.daemon(plistName: HelperConstants.daemonPlistName).status {
        case .enabled:
            return .ready
        case .requiresApproval:
            return .awaitingApproval
        case .notRegistered, .notFound:
            return .notRegistered
        @unknown default:
            return .notRegistered
        }
    }

    /// Registers the daemon. On first run macOS surfaces an approval request; `openSettings`
    /// takes the user straight to the switch they need to flip.
    @discardableResult
    func register() -> Result<PrivilegedHelperState, Error> {
        guard #available(macOS 13.0, *) else {
            return .success(.unsupported)
        }
        let service = SMAppService.daemon(plistName: HelperConstants.daemonPlistName)
        do {
            if service.status != .enabled {
                try service.register()
            }
            rmDebug("🔐 Privileged helper registration requested; status=\(service.status.rawValue)")
            return .success(state)
        } catch {
            rmDebug("🔐 Privileged helper registration failed: \(error.localizedDescription)")
            return .failure(error)
        }
    }

    func unregister(completion: @escaping @Sendable (Error?) -> Void) {
        guard #available(macOS 13.0, *) else {
            completion(nil)
            return
        }
        invalidateConnection()
        SMAppService.daemon(plistName: HelperConstants.daemonPlistName).unregister { error in
            completion(error)
        }
    }

    @available(macOS 13.0, *)
    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - XPC

    private func connection() -> NSXPCConnection {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        if let storedConnection {
            return storedConnection
        }
        let connection = NSXPCConnection(
            machServiceName: HelperConstants.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        let clear: @Sendable () -> Void = { [weak self] in self?.invalidateConnection() }
        connection.invalidationHandler = clear
        connection.interruptionHandler = clear
        connection.resume()
        storedConnection = connection
        return connection
    }

    private func invalidateConnection() {
        connectionLock.lock()
        let connection = storedConnection
        storedConnection = nil
        connectionLock.unlock()
        connection?.invalidate()
    }

    /// Obtains the remote proxy, reporting connection failures through `onError` exactly once.
    private func proxy(
        onError: @escaping @Sendable (String) -> Void
    ) -> HelperProtocol? {
        let reported = ErrorLatch()
        let remote = connection().remoteObjectProxyWithErrorHandler { error in
            guard reported.trip() else { return }
            onError("The VibeRemote helper is not reachable: \(error.localizedDescription)")
        }
        guard let helper = remote as? HelperProtocol else {
            if reported.trip() {
                onError("The VibeRemote helper interface is unavailable.")
            }
            return nil
        }
        return helper
    }

    /// Ensures a one-shot completion cannot fire twice when both the error handler and a
    /// reply race each other.
    private final class ErrorLatch: @unchecked Sendable {
        private let lock = NSLock()
        private var tripped = false
        func trip() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if tripped { return false }
            tripped = true
            return true
        }
    }

    func fetchVersion(completion: @escaping @Sendable (Int?, String?) -> Void) {
        let latch = ErrorLatch()
        guard let helper = proxy(onError: { message in
            completion(nil, message)
        }) else { return }
        helper.helperVersion { version in
            guard latch.trip() else { return }
            completion(version, nil)
        }
    }

    func installAudioDriver(
        fromPath path: String,
        completion: @escaping @Sendable (Bool, String?) -> Void
    ) {
        let latch = ErrorLatch()
        guard let helper = proxy(onError: { message in
            completion(false, message)
        }) else { return }
        helper.installAudioDriver(fromPath: path) { succeeded, message in
            guard latch.trip() else { return }
            completion(succeeded, message)
        }
    }
}
