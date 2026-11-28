// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "vvhisper",
    platforms: [.macOS("27.0")],
    products: [
        .executable(name: "vvhisper", targets: ["vvhisper"]),
        .executable(name: "vvhisperVoiceBridge", targets: ["vvhisperVoiceBridge"]),
        .executable(name: "vvhisperHelper", targets: ["vvhisperHelper"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
        // On-device Whisper for vvhisper Dictation; only its WhisperKit library is linked.
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "1.1.1"),
    ],
    targets: [
        .target(name: "SharedAudio", path: "SharedAudio", publicHeadersPath: "include"),
        .target(name: "NativeTouch", path: "NativeTouch", publicHeadersPath: "include", linkerSettings: [.linkedFramework("CoreFoundation")]),
        .target(name: "RemoteAudioProtocol", path: "RemoteAudioProtocol"),
        .target(
            name: "HelperProtocol",
            path: "HelperProtocol"
        ),
        .executableTarget(
            name: "vvhisperHelper",
            dependencies: ["HelperProtocol", "SharedAudio"],
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
            name: "vvhisper",
            dependencies: ["HelperProtocol", "NativeTouch", "RemoteAudioProtocol", .product(name: "Sparkle", package: "Sparkle"),
                           .product(name: "WhisperKit", package: "WhisperKit")],
            path: ".",
            exclude: [
                "SharedAudio", "NativeTouch", "scripts",
                "build.sh",
                "create_app_bundle.sh",
                "install.sh",
                "VibeRemote", "vvhisper",
                "VibeRemote.app", "vvhisper.app", "VibeRemoteHelper", "VibeRemoteVoiceBridge",
                "vvhisperVoiceBridge",
                "vvhisperHelper",
                "vvhisperAppIcon.png",
                "vvhisper.entitlements",
                "vvhisper.icon",
                "Vendor",
                "VoiceBridgeHelper",
                "RemoteAudioProtocol",
                "PrivilegedHelper",
                "HelperProtocol",
                "AudioDriver",
                "build_audio_driver.sh",
                "Design", "Release",
                "Tests",
                "README.md",
                "THIRD_PARTY_NOTICES.md",
            ],
            sources: [
                "main.swift", "DictationNotice.swift", "AppUpdater.swift", "OnboardingWindowController.swift",
                "RemoteInputPolicy.swift", "ButtonProfiles.swift", "RemoteCaretController.swift",
                "BluetoothAccessManager.swift", "SoundcoreManager.swift", "SoundcoreProtocol.swift", "SoundcoreAudio.swift",
                "SiriRemoteApp.swift",
                "MenuBarManager.swift",
                "SettingsWindowController.swift", "SettingsPanes.swift", "RemoteModelView.swift",
                "MicrophoneBridgeManager.swift",
                "PrivilegedHelperClient.swift",
                "RemoteBatteryReader.swift",
                "RemoteHIDChannel.swift",
                "RemoteDetector.swift",
                "RemoteGeneration.swift",
                "RemoteInputHandler.swift",
                "ListEditingController.swift",
                "MediaKeyInterceptor.swift", "PacketLoggerButtons.swift", "AdvancedMenu.swift",
                "SystemVolume.swift", "AgentLocalActions.swift", "AgentDecision.swift", "AgentConversationModel.swift", "AgentConversationAliases.swift", "AgentConversationSections.swift", "AgentConversationTraversal.swift", "AgentConversationAttributes.swift", "AgentConversationActions.swift", "ComputerUseAgent.swift", "AgentPanel.swift", "AgentDock.swift",
                "SharedConfiguration/PrivateCredentials.swift", "SharedConfiguration/PortableConfiguration.swift", "SharedConfiguration/EncryptedConfiguration.swift", "SharedConfiguration/ConfigurationFile.swift", "SharedConfiguration/ConfigurationSync.swift", "ConfigurationTransfer.swift", "Dictation.swift", "DictationEngines.swift", "DictationPane.swift", "DictationStreaming.swift", "DictationDraftUnderline.swift", "DictationPolisher.swift", "DictationLatency.swift", "DictationSentencePunctuation.swift", "DictationDictionary.swift", "DictationFillers.swift", "DictationHotkey.swift", "DictationBridgeAudio.swift", "AutoComputerUse.swift"
            ],
            resources: [.copy("Resources/PrivateCredentials"), .copy("Resources/SiriRemote.png"), .copy("Resources/SiriRemoteFirstGeneration.png"),
                        .copy("Resources/RemoteModels"), .copy("Resources/OnboardingSky.png"), .copy("Resources/CaretBubble.png"), .copy("Resources/CaretBubble.svg")],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Carbon"),
                .linkedFramework("AppKit"),
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("Security"),
                .linkedFramework("Speech"),
                .linkedFramework("AVFoundation"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .executableTarget(
            name: "vvhisperVoiceBridge",
            dependencies: ["RemoteAudioProtocol", "SharedAudio"],
            path: "VoiceBridgeHelper",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio")
            ]
        ),
        .testTarget(
            name: "vvhisperTests",
            dependencies: ["vvhisper", "HelperProtocol", "RemoteAudioProtocol", "SharedAudio"],
            path: "Tests/vvhisperTests"
        )
    ]
)
