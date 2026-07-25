// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VibeRemote",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "VibeRemote", targets: ["VibeRemote"]),
        .executable(name: "VibeRemoteVoiceBridge", targets: ["VibeRemoteVoiceBridge"]),
        .executable(name: "VibeRemoteHelper", targets: ["VibeRemoteHelper"])
    ],
    targets: [
        .target(
            name: "HelperProtocol",
            path: "HelperProtocol"
        ),
        .executableTarget(
            name: "VibeRemoteHelper",
            dependencies: ["HelperProtocol"],
            path: "PrivilegedHelper",
            exclude: ["Info.plist"],
            linkerSettings: [
                // A daemon shipped as a standalone executable still needs an embedded
                // identity: without a __TEXT,__info_plist section launchd refuses to load it
                // and SMAppService registration fails with "Operation not permitted".
                // The path is relative to the package root, which is where the build runs.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "PrivilegedHelper/Info.plist",
                ])
            ]
        ),
        .executableTarget(
            name: "VibeRemote",
            dependencies: ["HelperProtocol"],
            path: ".",
            exclude: [
                "build.sh",
                "create_app_bundle.sh",
                "VibeRemote",
                "VibeRemote.app",
                "VibeRemoteVoiceBridge",
                "VibeRemoteHelper",
                "VibeRemoteAppIcon.png",
                "VibeRemote.entitlements",
                "VibeRemote.icon",
                "Vendor",
                "VoiceBridgeHelper",
                "PrivilegedHelper",
                "HelperProtocol",
                "AudioDriver",
                "build_audio_driver.sh",
                "AGENTS.md",
                "Tests",
                "README.md",
                "LICENSE",
                "THIRD_PARTY_NOTICES.md",
            ],
            sources: [
                "main.swift",
                "BluetoothAccessManager.swift",
                "SiriRemoteApp.swift",
                "MenuBarManager.swift",
                "MicrophoneBridgeManager.swift",
                "PrivilegedHelperClient.swift",
                "RemoteBatteryReader.swift",
                "RemoteHIDChannel.swift",
                "RemoteDetector.swift",
                "RemoteInputHandler.swift",
                "MediaKeyInterceptor.swift",
                "SystemVolume.swift"
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "VibeRemoteVoiceBridge",
            path: "VoiceBridgeHelper",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio")
            ]
        ),
        .testTarget(
            name: "VibeRemoteTests",
            dependencies: ["VibeRemote", "HelperProtocol"],
            path: "Tests/VibeRemoteTests"
        )
    ]
)
