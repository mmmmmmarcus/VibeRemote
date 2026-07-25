//
//  HelperProtocol.swift
//  VibeRemote
//
//  The XPC contract between the menu-bar app and the privileged helper daemon.
//  Shared by both targets so the interface cannot drift.
//

import Foundation

/// Identifiers shared by the app (client) and the helper (daemon).
public enum HelperConstants {
    /// Mach service the daemon listens on. Must match MachServices in the daemon plist.
    public static let machServiceName = "com.viberemote.helper"

    /// Daemon plist name inside the app bundle's Contents/Library/LaunchDaemons.
    public static let daemonPlistName = "com.viberemote.helper.plist"

    /// Bumped whenever the helper's capabilities change so the app can prompt for a
    /// re-registration instead of talking to a stale daemon.
    public static let version = 1

    /// Team identifier the helper requires of any connecting client.
    public static let expectedTeamIdentifier = "SM96W8VVK9"

    /// Bundle identifier the helper requires of any connecting client.
    public static let expectedClientBundleID = "com.viberemote.app"
}

/// Operations the app may ask the privileged helper to perform. Everything here needs root,
/// which is the entire reason the helper exists: the user authorizes it once, and the app
/// never has to raise an administrator prompt again.
@objc public protocol HelperProtocol {
    /// Liveness and compatibility probe. Returns `HelperConstants.version` of the installed
    /// helper, which may be older than the app's if the daemon was not re-registered.
    func helperVersion(reply: @escaping (Int) -> Void)

    /// Installs the VibeRemote virtual audio driver from the given source path into the
    /// system HAL plug-in directory and restarts coreaudiod.
    func installAudioDriver(fromPath sourcePath: String, reply: @escaping (Bool, String?) -> Void)
}
