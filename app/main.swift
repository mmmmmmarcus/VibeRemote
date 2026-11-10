//
//  main.swift
//  VibeRemote
//
//  Application entry point
//

import AppKit

// Developer check of the streaming dictation protocol; see SeedStreamVerifier.
if let index = CommandLine.arguments.firstIndex(of: "--verify-seed-stream"),
   CommandLine.arguments.indices.contains(index + 1) {
    SeedStreamVerifier.run(path: CommandLine.arguments[index + 1])
}

// A macOS application's entry point runs on the process main thread. Make that
// executor contract explicit so the AppKit delegate remains main-actor isolated.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate

    // NSApplicationMain blocks for the app lifetime, retaining the local delegate.
    _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
}
