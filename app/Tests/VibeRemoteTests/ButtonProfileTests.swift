import XCTest
@testable import VibeRemote

final class ButtonProfileTests: XCTestCase {
    private let figma = "com.figma.Desktop"

    func testDefaultsStartClaudeAndChatGPTEmptyWithPlayPauseComputerUse() {
        let set = ButtonProfileSet.defaults()
        XCTAssertEqual(set.all.map(\.name), ["General", "Claude", "ChatGPT"])
        // Play/Pause opens Computer Use everywhere by default since 2026-11-13; seeds pin nothing.
        for id in [ButtonProfile.generalID, ButtonProfileSet.claudeBundleID, ButtonProfileSet.chatGPTBundleID] {
            XCTAssertEqual(set.action(button: "playPause", generation: .aluminumClickpad, profile: id), .computerUse)
        }
        XCTAssertTrue(set.profile(id: ButtonProfileSet.claudeBundleID)?.overrides.isEmpty == true)
        XCTAssertTrue(set.isAtDefaults(ButtonProfileSet.claudeBundleID))
    }

    func testRetiredSkillSeedsAreRemovedOnceAndLaterChoicesKept() throws {
        let suite = "ButtonProfileTests.migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // A profile saved with the old seeds, plus a deliberate choice that must survive.
        defaults.set([["bundleID": ButtonProfileSet.claudeBundleID, "name": "Claude",
                       "overrides": ["aluminumClickpad": ["playPause": "Skill Picker: /", "power": "Undo"]]],
                      ["bundleID": ButtonProfileSet.chatGPTBundleID, "name": "ChatGPT",
                       "overrides": ["aluminumClickpad": ["playPause": "Skill Picker: $"]]]],
                     forKey: ButtonProfileStore.appsKey)
        var set = ButtonProfileStore.load(defaults)
        XCTAssertEqual(set.action(button: "playPause", generation: .aluminumClickpad, profile: ButtonProfileSet.claudeBundleID), .computerUse)
        XCTAssertEqual(set.action(button: "power", generation: .aluminumClickpad, profile: ButtonProfileSet.claudeBundleID), .undo)
        XCTAssertEqual(set.action(button: "playPause", generation: .aluminumClickpad, profile: ButtonProfileSet.chatGPTBundleID), .computerUse)
        // Choosing Skill again afterwards is kept: the migration runs once.
        set.set(.slashSkill, for: "playPause", generation: .aluminumClickpad, profile: ButtonProfileSet.claudeBundleID)
        ButtonProfileStore.save(set, defaults)
        XCTAssertEqual(ButtonProfileStore.load(defaults).action(button: "playPause", generation: .aluminumClickpad,
                                                                 profile: ButtonProfileSet.claudeBundleID), .slashSkill)
    }

    func testFrontmostAppWithoutProfileUsesGeneral() {
        let set = ButtonProfileSet.defaults()
        XCTAssertEqual(set.profileID(forFrontmost: figma), ButtonProfile.generalID)
        XCTAssertEqual(set.profileID(forFrontmost: nil), ButtonProfile.generalID)
        XCTAssertEqual(set.profileID(forFrontmost: ButtonProfileSet.claudeBundleID), ButtonProfileSet.claudeBundleID)
    }

    func testAppProfileInheritsGeneralUntilChanged() {
        var set = ButtonProfileSet.defaults()
        set.add(bundleID: figma, name: "Figma")
        XCTAssertTrue(set.inherits("power", profile: figma, generation: .aluminumClickpad))
        // A later General change reaches every button the app never touched.
        set.set(.undo, for: "power", generation: .aluminumClickpad, profile: ButtonProfile.generalID)
        XCTAssertEqual(set.action(button: "power", generation: .aluminumClickpad, profile: figma), .undo)
        // An explicit app choice wins, and only in that app.
        set.set(.redo, for: "power", generation: .aluminumClickpad, profile: figma)
        XCTAssertEqual(set.action(button: "power", generation: .aluminumClickpad, profile: figma), .redo)
        XCTAssertEqual(set.action(button: "power", generation: .aluminumClickpad, profile: ButtonProfile.generalID), .undo)
        XCTAssertFalse(set.inherits("power", profile: figma, generation: .aluminumClickpad))
        // An app may pin General's own default; General itself drops that entry.
        set.set(.enterKey, for: "power", generation: .aluminumClickpad, profile: figma)
        XCTAssertEqual(set.profile(id: figma)?.overrides[.aluminumClickpad]?["power"], .enterKey)
        set.set(.enterKey, for: "power", generation: .aluminumClickpad, profile: ButtonProfile.generalID)
        XCTAssertNil(set.general.overrides[.aluminumClickpad])
        // nil follows General again.
        set.set(nil, for: "power", generation: .aluminumClickpad, profile: figma)
        XCTAssertTrue(set.inherits("power", profile: figma, generation: .aluminumClickpad))
        XCTAssertTrue(set.isAtDefaults(figma))
    }

    func testSiriPerProfileAndRejectedChoices() {
        var set = ButtonProfileSet.defaults()
        set.setSiri(.vibeDictation, profile: ButtonProfileSet.claudeBundleID)
        XCTAssertEqual(set.siriAction(profile: ButtonProfileSet.claudeBundleID), .vibeDictation)
        XCTAssertEqual(set.siriAction(profile: ButtonProfileSet.chatGPTBundleID), .spaceKey)
        XCTAssertEqual(set.profiles(withSiri: .vibeDictation).map(\.name), ["Claude"])
        // Siri never takes an instant action; fixed-role buttons never take any.
        set.setSiri(.enterKey, profile: ButtonProfileSet.claudeBundleID)
        XCTAssertEqual(set.siriAction(profile: ButtonProfileSet.claudeBundleID), .vibeDictation)
        set.set(.undo, for: "mute", generation: .aluminumClickpad, profile: ButtonProfileSet.claudeBundleID)
        XCTAssertEqual(set.action(button: "mute", generation: .aluminumClickpad, profile: ButtonProfileSet.claudeBundleID), .advancedMenu)
        // General cannot follow itself: nil restores its default.
        set.setSiri(.rightOpt, profile: ButtonProfile.generalID)
        set.setSiri(nil, profile: ButtonProfile.generalID)
        XCTAssertEqual(set.general.siriAction, .spaceKey)
        set.setSiri(nil, profile: ButtonProfileSet.claudeBundleID)
        XCTAssertTrue(set.inherits("siri", profile: ButtonProfileSet.claudeBundleID, generation: .aluminumClickpad))
    }

    func testRestoreAndRemove() {
        var set = ButtonProfileSet.defaults()
        set.set(.undo, for: "playPause", generation: .aluminumClickpad, profile: ButtonProfileSet.claudeBundleID)
        XCTAssertFalse(set.isAtDefaults(ButtonProfileSet.claudeBundleID))
        set.restore(ButtonProfileSet.claudeBundleID)
        XCTAssertEqual(set.action(button: "playPause", generation: .aluminumClickpad, profile: ButtonProfileSet.claudeBundleID), .computerUse)
        set.add(bundleID: ButtonProfileSet.claudeBundleID, name: "Duplicate")
        XCTAssertEqual(set.apps.count, 2, "adding an app that already has a profile does nothing")
        set.remove(ButtonProfileSet.claudeBundleID)
        set.remove(ButtonProfile.generalID)
        XCTAssertEqual(set.all.map(\.name), ["General", "ChatGPT"])
    }

    func testStoreKeepsGeneralKeysAndSeedsOnce() throws {
        let suite = "ButtonProfileTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // An install from before profiles: its General choices load unchanged, apps get seeded.
        defaults.set(ButtonAction.vibeDictation.rawValue, forKey: "siriButtonAction")
        defaults.set(["aluminumClickpad": ["power": ButtonAction.undo.rawValue, "mute": ButtonAction.undo.rawValue]],
                     forKey: "buttonActionOverrides")
        var set = ButtonProfileStore.load(defaults)
        XCTAssertEqual(set.general.siriAction, .vibeDictation)
        XCTAssertEqual(set.general.overrides[.aluminumClickpad], ["power": .undo], "fixed-role entries are dropped")
        XCTAssertEqual(set.apps.map(\.name), ["Claude", "ChatGPT"])
        // Removing a seeded profile sticks; added ones round-trip with their choices.
        set.remove(ButtonProfileSet.chatGPTBundleID)
        set.add(bundleID: figma, name: "Figma")
        set.setSiri(.rightCmd, profile: figma)
        set.set(.redo, for: "back", generation: .glassTouchSurface, profile: figma)
        ButtonProfileStore.save(set, defaults)
        XCTAssertEqual(ButtonProfileStore.load(defaults), set)
        XCTAssertEqual(defaults.string(forKey: "siriButtonAction"), ButtonAction.vibeDictation.rawValue)
    }

    func testPressLatchesProfileUntilRelease() {
        var latch = ButtonProfileLatch()
        var frontmost = ButtonProfileSet.claudeBundleID
        let resolve = { frontmost }
        XCTAssertEqual(latch.profile(button: "playPause", generation: .aluminumClickpad, pressed: true, resolve: resolve),
                       ButtonProfileSet.claudeBundleID)
        // The press switched apps (Toggle Codex / Claude); its release still maps under Claude.
        frontmost = ButtonProfileSet.chatGPTBundleID
        XCTAssertEqual(latch.profile(button: "playPause", generation: .aluminumClickpad, pressed: false, resolve: resolve),
                       ButtonProfileSet.claudeBundleID)
        // Another remote family's button, and the next press, resolve fresh.
        XCTAssertEqual(latch.profile(button: "playPause", generation: .glassTouchSurface, pressed: false, resolve: resolve),
                       ButtonProfileSet.chatGPTBundleID)
        XCTAssertEqual(latch.profile(button: "playPause", generation: .aluminumClickpad, pressed: true, resolve: resolve),
                       ButtonProfileSet.chatGPTBundleID)
    }

    @MainActor
    func testAppProfileSnapshotAndPillMenu() {
        var set = ButtonProfileSet.defaults()
        set.add(bundleID: figma, name: "Figma")
        set.set(.undo, for: "power", generation: .aluminumClickpad, profile: figma)
        let snapshot = RemoteSettingsSnapshot(connected: true, batteryPercent: 50,
                                              siriAction: set.siriAction(profile: figma), generation: .aluminumClickpad,
                                              buttonOverrides: set.overrides(profile: figma, generation: .aluminumClickpad),
                                              profiles: set, editingProfileID: figma)
        XCTAssertFalse(snapshot.isAtDefaults)
        XCTAssertTrue(snapshot.followsGeneral("tv"))
        XCTAssertEqual(snapshot.generalAction(for: "power"), .enterKey)
        let options = RemoteSettingsGuide.pillOptions(for: "tv", snapshot: snapshot)!
        let menu = ButtonActionMenu.makeMenu(choices: options.choices, current: options.current, defaultChoice: options.choices.first,
                                             general: .init(action: snapshot.generalAction(for: "tv"), following: true), target: nil)
        XCTAssertEqual(menu.items.first?.title, "Same as General (Shift + Enter)")
        XCTAssertEqual(menu.items.filter { $0.state == .on }.count, 1, "only Same as General is checked")
        XCTAssertEqual(menu.items.first?.state, .on)
        XCTAssertTrue(options.choices.contains(.slashSkill) && options.choices.contains(.dollarSkill))
    }

    func testInstalledAppScanSkipsDuplicatesAndFindsAnApp() {
        let apps = InstalledApp.scan()
        XCTAssertEqual(Set(apps.map(\.bundleID)).count, apps.count)
        // Every Mac has Finder's neighbours in /System/Applications.
        XCTAssertTrue(apps.contains { $0.bundleID == "com.apple.TextEdit" })
    }
}
