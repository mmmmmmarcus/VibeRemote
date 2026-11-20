import XCTest
import UIKit
@testable import vvhisper

final class KeyboardPreferencesTests: XCTestCase {
    func testHapticPrecisionAndSharpnessMigrationRoundTripIndependently() throws {
        let old = try JSONDecoder().decode(KeyboardPreferences.self, from: Data(#"{"hapticStrength":0.45}"#.utf8))
        XCTAssertEqual(old.hapticStrength, 0.45); XCTAssertEqual(old.hapticSharpness, 0.7)
        XCTAssertEqual(KeyboardPreferences.normalizedStrength(0.463), 0.46)
        XCTAssertEqual(KeyboardPreferences.normalizedSharpness(0.874), 0.87)
        XCTAssertEqual(KeyboardPreferences.normalizedSharpness(.nan), 0.7)
        XCTAssertEqual(KeyboardPreferences.normalizedSharpness(-1), 0)
        XCTAssertEqual(KeyboardPreferences.normalizedSharpness(2), 1)
        let settings = KeyboardPreferences(hapticStrength: 0.46, hapticSharpness: 0.87, mixedTypingEnabled: true, voiceSessionMinutes: 5)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(settings)), settings)
    }
    @MainActor func testFineHapticControlsSaveIndependentlyAndRollback() throws {
        var stored = KeyboardPreferences(hapticStrength: 0.45, hapticSharpness: 0.7, mixedTypingEnabled: true)
        let settings = MainSettingsViewController(loadPreferences: { stored }, savePreferences: { stored = $0 })
        settings.loadViewIfNeeded()
        XCTAssertTrue(settings.setHaptics(sharpness: 0.88)); XCTAssertEqual(stored.hapticStrength, 0.45)
        XCTAssertEqual(stored.hapticSharpness, 0.88); XCTAssertTrue(stored.mixedTypingEnabled)
        func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
        let cell = settings.tableView(settings.tableView, cellForRowAt: IndexPath(row: 0, section: 2))
        let stepper = try XCTUnwrap(descendants(cell).compactMap { $0 as? UIStepper }.first)
        stepper.value = 46; stepper.sendActions(for: .valueChanged)
        XCTAssertEqual(stored.hapticStrength, 0.46); XCTAssertEqual(stored.hapticSharpness, 0.88)
        XCTAssertTrue(settings.setHaptics(strength: 0)); XCTAssertEqual(stored.hapticStrength, 0)
        let reopened = MainSettingsViewController(loadPreferences: { stored }, savePreferences: { _ in throw CocoaError(.fileWriteNoPermission) })
        reopened.loadViewIfNeeded()
        XCTAssertFalse(reopened.setHaptics(sharpness: 0.4))
        let sharpCell = reopened.tableView(reopened.tableView, cellForRowAt: IndexPath(row: 1, section: 2))
        XCTAssertEqual(descendants(sharpCell).compactMap { $0 as? UISlider }.first?.value, 0.88)
    }
    func testSessionDurationMigrationAndValidation() throws {
        let old = try JSONDecoder().decode(KeyboardPreferences.self, from: Data(#"{"hapticStrength":0.8,"mixedTypingEnabled":true}"#.utf8))
        XCTAssertEqual(old.voiceSessionMinutes, 15)
        for minutes in KeyboardPreferences.voiceSessionChoices {
            let settings = KeyboardPreferences(hapticStrength: 0.8, mixedTypingEnabled: true, voiceSessionMinutes: minutes)
            XCTAssertEqual(try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(settings)), settings)
        }
        for invalid in [-1, 0, 2, 10000] { XCTAssertEqual(KeyboardPreferences(voiceSessionMinutes: invalid).voiceSessionMinutes, 15) }
    }

    func testSessionExpiresAtSelectedDeadlineAndChangingDurationDoesNotRestartIt() {
        let start = Date(timeIntervalSince1970: 1000)
        var lifetime = VoiceSessionLifetime(startedAt: start, minutes: 5)
        XCTAssertFalse(lifetime.hasExpired(at: start.addingTimeInterval(299.99)))
        XCTAssertTrue(lifetime.hasExpired(at: start.addingTimeInterval(300)))
        lifetime.minutes = 15
        XCTAssertEqual(lifetime.expiresAt, start.addingTimeInterval(900))
        lifetime.minutes = 1
        XCTAssertTrue(lifetime.hasExpired(at: start.addingTimeInterval(61)))
    }

    @MainActor func testDurationSettingSavesReloadsAndRollsBackFailedWrite() throws {
        var stored = KeyboardPreferences(hapticStrength: 0.8, mixedTypingEnabled: true)
        let settings = MainSettingsViewController(loadPreferences: { stored }, savePreferences: { stored = $0 })
        settings.loadViewIfNeeded()
        XCTAssertTrue(settings.setVoiceSessionMinutes(5))
        XCTAssertEqual(stored, KeyboardPreferences(hapticStrength: 0.8, mixedTypingEnabled: true, voiceSessionMinutes: 5))
        let failing = MainSettingsViewController(loadPreferences: { stored }, savePreferences: { _ in throw CocoaError(.fileWriteNoPermission) })
        failing.loadViewIfNeeded()
        XCTAssertFalse(failing.setVoiceSessionMinutes(1))
        let cell = failing.tableView(failing.tableView, cellForRowAt: IndexPath(row: 2, section: 0))
        XCTAssertEqual((cell.contentConfiguration as? UIListContentConfiguration)?.secondaryText, "5 minutes")
    }
    func testExperimentDefaultsOffAndMigratesExistingHapticSetting() throws {
        XCTAssertFalse(KeyboardPreferences().mixedTypingEnabled)
        let decoder = JSONDecoder()
        let old = try decoder.decode(KeyboardPreferences.self, from: Data(#"{"hapticStrength":0.8}"#.utf8))
        XCTAssertEqual(old.hapticStrength, 0.8)
        XCTAssertFalse(old.mixedTypingEnabled)
        let empty = try decoder.decode(KeyboardPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, KeyboardPreferences())
    }

    func testBothToggleValuesRoundTripWithoutChangingHaptics() throws {
        for enabled in [true, false] {
            let preferences = KeyboardPreferences(hapticStrength: 0.7, mixedTypingEnabled: enabled)
            let decoded = try JSONDecoder().decode(KeyboardPreferences.self, from: JSONEncoder().encode(preferences))
            XCTAssertEqual(decoded, preferences)
        }
    }

    @MainActor
    func testSettingsSwitchSavesAndReloadsTheExperiment() throws {
        var stored = KeyboardPreferences(hapticStrength: 0.8)
        let settings = MainSettingsViewController(loadPreferences: { stored }, savePreferences: { stored = $0 })
        settings.loadViewIfNeeded()
        settings.viewWillAppear(false)
        let cell = settings.tableView(settings.tableView, cellForRowAt: IndexPath(row: 0, section: 3))
        let toggle = try XCTUnwrap(cell.accessoryView as? UISwitch)
        XCTAssertEqual(settings.tableView(settings.tableView, titleForHeaderInSection: 3), "Experimental")
        XCTAssertFalse(toggle.isOn)
        toggle.isOn = true; toggle.sendActions(for: .valueChanged)
        XCTAssertTrue(stored.mixedTypingEnabled)
        XCTAssertEqual(stored.hapticStrength, 0.8)
        let reopened = MainSettingsViewController(loadPreferences: { stored }, savePreferences: { stored = $0 })
        reopened.loadViewIfNeeded()
        reopened.viewWillAppear(false)
        let reopenedCell = reopened.tableView(reopened.tableView, cellForRowAt: IndexPath(row: 0, section: 3))
        let reopenedToggle = try XCTUnwrap(reopenedCell.accessoryView as? UISwitch)
        XCTAssertTrue(reopenedToggle.isOn)
        reopenedToggle.isOn = false; reopenedToggle.sendActions(for: .valueChanged)
        XCTAssertFalse(stored.mixedTypingEnabled)
        XCTAssertEqual(stored.hapticStrength, 0.8)
    }
}
