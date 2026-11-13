import XCTest
@testable import VibeRemote

final class AdvancedMenuMappingTests: XCTestCase {
    func testDefaultsMatchTheBuiltInLayout() {
        // With no choices saved, every non-opener button keeps the built-in action.
        for generation in [RemoteGeneration.glassTouchSurface, .aluminumClickpad] {
            for button in ["back", "menu", "tv", "volumeUp", "volumeDown", "playPause", "power", "siri"]
            where button != AdvancedMenuInputState.trigger(for: generation) {
                XCTAssertEqual(AdvancedMenuMapping.action(button: button, generation: generation, overrides: [:]),
                               AdvancedMenuInputState.action(button: button, generation: generation))
            }
        }
        XCTAssertEqual(AdvancedMenuMapping.action(button: "back", generation: .aluminumClickpad, overrides: [:]), .deleteAll)
        XCTAssertNil(AdvancedMenuMapping.action(button: "tv", generation: .aluminumClickpad, overrides: [:]))
    }

    func testOverridesReplaceClearAndNeverTouchTheOpener() {
        let overrides = ["volumeUp": AdvancedMenuAction.paste.rawValue, "back": AdvancedMenuMapping.noneValue,
                         "mute": AdvancedMenuAction.undo.rawValue]
        XCTAssertEqual(AdvancedMenuMapping.action(button: "volumeUp", generation: .aluminumClickpad, overrides: overrides), .paste)
        XCTAssertNil(AdvancedMenuMapping.action(button: "back", generation: .aluminumClickpad, overrides: overrides))
        // The 1st-gen Menu button shares Back's choice.
        XCTAssertNil(AdvancedMenuMapping.action(button: "menu", generation: .glassTouchSurface, overrides: overrides))
        XCTAssertNil(AdvancedMenuMapping.action(button: "mute", generation: .aluminumClickpad, overrides: overrides),
                     "the opener stays fixed")
        XCTAssertFalse(AdvancedMenuMapping.buttons(for: .aluminumClickpad).contains("mute"))
        XCTAssertFalse(AdvancedMenuMapping.buttons(for: .glassTouchSurface).contains("playPause"))
        XCTAssertFalse(AdvancedMenuMapping.buttons(for: .glassTouchSurface).contains("power"))
    }

    func testStorageDropsUnknownValuesAndDefaultChoices() throws {
        let suite = "AdvancedMenuMappingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["aluminumClickpad": ["volumeUp": "bogus", "back": "none", "mute": "undo"]],
                     forKey: AdvancedMenuMapping.defaultsKey)
        XCTAssertEqual(AdvancedMenuMapping.load(from: defaults)[.aluminumClickpad], ["back": "none"])
        AdvancedMenuMapping.set(.paste, isNone: false, button: "tv", generation: .aluminumClickpad, in: defaults)
        XCTAssertEqual(AdvancedMenuMapping.load(from: defaults)[.aluminumClickpad]?["tv"], "paste")
        // Picking a button's own default removes the entry instead of storing it.
        AdvancedMenuMapping.set(.deleteAll, isNone: false, button: "back", generation: .aluminumClickpad, in: defaults)
        AdvancedMenuMapping.set(nil, isNone: true, button: "tv", generation: .aluminumClickpad, in: defaults)
        XCTAssertNil(AdvancedMenuMapping.load(from: defaults)[.aluminumClickpad])
    }

    func testTheOpenMenuPerformsTheChosenAction() {
        var state = AdvancedMenuInputState()
        state.overrides = [.aluminumClickpad: ["volumeUp": AdvancedMenuAction.paste.rawValue,
                                               "volumeDown": AdvancedMenuMapping.noneValue]]
        _ = state.handle(button: "mute", pressed: true, device: "d", generation: .aluminumClickpad, time: 0)
        _ = state.handle(button: "mute", pressed: false, device: "d", generation: .aluminumClickpad, time: 0.1)
        XCTAssertTrue(state.isVisible)
        // Volume Down set to None no longer acts in the menu.
        XCTAssertNil(state.handle(button: "volumeDown", pressed: true, device: "d", generation: .aluminumClickpad, time: 1).command)
        _ = state.handle(button: "volumeDown", pressed: false, device: "d", generation: .aluminumClickpad, time: 1.1)
        _ = state.handle(button: "volumeUp", pressed: true, device: "d", generation: .aluminumClickpad, time: 2)
        XCTAssertEqual(state.handle(button: "volumeUp", pressed: false, device: "d", generation: .aluminumClickpad, time: 2.1).command,
                       .perform(.paste))
    }
}
