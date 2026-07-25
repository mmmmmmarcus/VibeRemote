// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VibeRemote",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "VibeRemote", targets: ["VibeRemote"]),
        .executable(name: "VibeRemoteVoiceBridge", targets: ["VibeRemoteVoiceBridge"])
    ],
    targets: [
        .executableTarget(
            name: "VibeRemote",
            path: ".",
            exclude: [
                "build.sh",
                "create_app_bundle.sh",
                "VibeRemote",
                "VibeRemote.app",
                "VibeRemoteVoiceBridge",
                "VibeRemoteAppIcon.png",
                "VibeRemote.entitlements",
                "VibeRemote.icon",
                "Vendor",
                "VoiceBridgeHelper",
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
            dependencies: ["VibeRemote"],
            path: "Tests/VibeRemoteTests"
        )
    ]
)
