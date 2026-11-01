//
//  main.swift
//  VibeRemote
//
//  Application entry point
//

import AppKit

// A macOS application's entry point runs on the process main thread. Make that
// executor contract explicit so the AppKit delegate remains main-actor isolated.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    // NSApplicationMain blocks for the app lifetime, retaining the local delegate.
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
