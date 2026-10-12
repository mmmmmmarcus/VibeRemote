//
//  main.swift
//  VibeRemote
//
//  Application entry point
//

import AppKit

if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--command-mcp-proxy",
   let owner = Int32(CommandLine.arguments[4]), owner > 1 {
    exit(CommandMCPProxy.run(driver: URL(fileURLWithPath: CommandLine.arguments[2]),
                            directory: URL(fileURLWithPath: CommandLine.arguments[3]), ownerPID: owner))
}

if CommandLine.arguments.count == 5, CommandLine.arguments[1] == "--command-jev-worker",
   let owner = Int32(CommandLine.arguments[4]), owner > 1 {
    exit(CommandJevWorker.run(driver: URL(fileURLWithPath: CommandLine.arguments[2]),
                             directory: URL(fileURLWithPath: CommandLine.arguments[3]), ownerPID: owner))
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
