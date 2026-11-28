import XCTest
import UIKit
import Darwin
@testable import vvhisper

final class KeyboardDimensionTests: XCTestCase {
    private func store() throws -> KeyboardDimensionStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return KeyboardDimensionStore(directory: directory.appendingPathComponent("store", isDirectory: true),
                                      exportDirectory: directory.appendingPathComponent("KeyboardDimensionsExport", isDirectory: true))
    }
    private func sample(_ height: Double = 280) -> KeyboardDimensionSample {
        .init(rootBounds: [0, 0, 452, height], windowBounds: [0, 0, 452, height],
              rootSafeArea: [0, 0, 0, 0], windowSafeArea: [0, 0, 0, 0], requestedHeight: 280,
              headerFrame: [0, 1, 452, 44], keysFrame: [0, 48, 452, 224],
              rowHeights: [50, 50, 50, 50], rowGaps: [8, 8, 8], keyGap: 6,
              orientation: 1, mini: 0, appVersion: [0, 1, 0], buildVersion: [8])
    }
    func testOffByDefaultPermissionGateAndUnavailable() throws {
        let store = try store()
        let initial = try store.load()
        XCTAssertFalse(initial.enabled); XCTAssertTrue(initial.samples.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(store.directory).path))
        try store.append(sample(), generation: initial.generation, fullAccess: true)
        XCTAssertTrue(try store.load().samples.isEmpty)
        try store.setEnabled(true)
        let consent = try store.load()
        XCTAssertThrowsError(try store.append(sample(), generation: consent.generation, fullAccess: false))
        XCTAssertTrue(try store.load().samples.isEmpty)
        XCTAssertThrowsError(try KeyboardDimensionStore(directory: nil).load())
        XCTAssertThrowsError(try KeyboardDimensionStore(directory: nil).exportJSON())
        XCTAssertTrue(KeyboardDimensionCopy.permission.contains("不可用"))
        XCTAssertTrue(KeyboardDimensionCopy.permission.contains("主 App 无法直接确认"))
    }
    func testBoundedDedupAndClearInvalidatesPendingSamples() throws {
        let store = try store(); try store.setEnabled(true)
        let token = try store.load().generation
        for height in 100...120 {
            try store.append(sample(Double(height)), generation: token, fullAccess: true)
        }
        let saved = try store.load().samples
        XCTAssertEqual(saved.count, 8)
        XCTAssertEqual(saved.first?.rootBounds[3], 113)
        for value in saved { try store.append(value, generation: token, fullAccess: true) }
        XCTAssertEqual(try store.load().samples, saved)
        try store.clear()
        try store.append(sample(), generation: token, fullAccess: true)
        XCTAssertFalse(try store.load().enabled)
        XCTAssertTrue(try store.load().samples.isEmpty)
        try store.setEnabled(true)
        try store.append(sample(), generation: token, fullAccess: true)
        XCTAssertTrue(try store.load().samples.isEmpty)
        let current = try store.load().generation
        try store.append(sample(), generation: current, fullAccess: true)
        try store.setEnabled(false)
        try store.append(sample(300), generation: current, fullAccess: true)
        XCTAssertEqual(try store.load().samples, [sample()])
    }
    func testNumericSchemaOnlyAndUnknownDiskFieldsNeverExport() throws {
        let store = try store(); try store.setEnabled(true)
        try store.append(sample(), generation: store.load().generation, fullAccess: true)
        let file = try XCTUnwrap(store.directory).appendingPathComponent("samples.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["untrustedExtra"] = "DO_NOT_EXPORT"
        var samples = try XCTUnwrap(object["samples"] as? [[String: Any]])
        samples[0]["text"] = "DO_NOT_EXPORT"; object["samples"] = samples
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        let data = try store.exportJSON()
        let exported = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(exported.keys), ["schema", "samples"])
        func numericLeaves(_ value: Any) -> Bool {
            if value is NSNumber { return true }
            if let list = value as? [Any] { return list.allSatisfy(numericLeaves) }
            if let map = value as? [String: Any] { return map.values.allSatisfy(numericLeaves) }
            return false
        }
        XCTAssertTrue(numericLeaves(exported))
        let record = try XCTUnwrap((exported["samples"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(record.keys), ["rootBounds", "windowBounds", "rootSafeArea", "windowSafeArea", "requestedHeight", "headerFrame", "keysFrame", "rowHeights", "rowGaps", "keyGap", "orientation", "mini", "appVersion", "buildVersion"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("DO_NOT_EXPORT"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("generation"))
    }
    func testValidationAndReadByteBounds() throws {
        XCTAssertTrue(sample().isValid)
        var invalid = sample(); invalid.rootBounds[0] = .nan; XCTAssertFalse(invalid.isValid)
        invalid = sample(); invalid.requestedHeight = .infinity; XCTAssertFalse(invalid.isValid)
        invalid = sample(); invalid.rowHeights = Array(repeating: 40, count: 6); XCTAssertFalse(invalid.isValid)
        invalid = sample(); invalid.windowSafeArea = [0]; XCTAssertFalse(invalid.isValid)
        invalid = sample(); invalid.mini = 2; XCTAssertFalse(invalid.isValid)
        invalid = sample(); invalid.orientation = 5; XCTAssertFalse(invalid.isValid)
        invalid = sample(); invalid.keyGap = 20_000; XCTAssertFalse(invalid.isValid)
        XCTAssertEqual(KeyboardDimensionSample.numericVersion("0.1.0"), [0, 1, 0])
        for value in ["private-text", "1..2", "1.2.3.4.5", "1000000", "-1"] {
            XCTAssertEqual(KeyboardDimensionSample.numericVersion(value), [0])
        }
        let store = try store(); try store.setEnabled(true)
        let file = try XCTUnwrap(store.directory).appendingPathComponent("samples.json")
        try Data(repeating: 32, count: KeyboardDimensionStore.byteLimit + 1).write(to: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.exportJSON())
        try store.clear() // Explicit recovery from a malformed file, not a silent reset.
        XCTAssertTrue(try store.load().samples.isEmpty)
    }
    func testProtectionAndCrossInstanceConsent() throws {
        let store = try store(); try store.setEnabled(true)
        let second = KeyboardDimensionStore(directory: store.directory, exportDirectory: store.exportDirectory)
        let consent = try second.load()
        try store.clear()
        try second.append(sample(), generation: consent.generation, fullAccess: true)
        XCTAssertTrue(try store.load().samples.isEmpty)
        let directory = try XCTUnwrap(store.directory)
        for url in [directory, directory.appendingPathComponent("samples.json"), directory.appendingPathComponent("store.lock")] {
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.posixPermissions] as? Int, url == directory ? 0o700 : 0o600)
        }
        XCTAssertEqual(KeyboardDimensionStore.protectionAttributes(directory: false)[.protectionKey] as? FileProtectionType, .complete)
    }

    func testRejectsSymlinkAndMalformedSchema() throws {
        let store = try store(); try store.setEnabled(true)
        let directory = try XCTUnwrap(store.directory)
        let file = directory.appendingPathComponent("samples.json")
        var state = try store.load()
        state.schema = 2
        try JSONEncoder().encode(state).write(to: file)
        XCTAssertThrowsError(try store.load())
        state.schema = 1; state.samples = Array(repeating: sample(), count: 9)
        try JSONEncoder().encode(state).write(to: file)
        XCTAssertThrowsError(try store.exportJSON())
        try FileManager.default.removeItem(at: file)
        let unrelated = directory.appendingPathComponent("unrelated.json")
        try Data("DO_NOT_READ".utf8).write(to: unrelated)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: unrelated)
        XCTAssertThrowsError(try store.load())
        try store.clear()
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "DO_NOT_READ")
        XCTAssertTrue(try store.load().samples.isEmpty)
    }

    func testInterruptedExportAndWriteRelaunchRecoveryThenClear() throws {
        let original = try store(); try original.setEnabled(true)
        try original.append(sample(), generation: original.load().generation, fullAccess: true)
        let directory = try XCTUnwrap(original.directory)
        let writeOrphan = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        let staged = original.exportDirectory.appendingPathComponent("KeyboardDimensions.json")
        let unrelated = directory.deletingLastPathComponent().appendingPathComponent("input.json")
        let unrelatedTemporary = directory.appendingPathComponent("unrelated.tmp")
        try Data("UNRELATED".utf8).write(to: unrelated)
        try Data("UNRELATED".utf8).write(to: unrelatedTemporary)
        func interruptedFiles() throws {
            // A killed process leaves files but no flock ownership. Seed exactly that state.
            try original.exportJSON().write(to: writeOrphan)
            try FileManager.default.createDirectory(at: original.exportDirectory, withIntermediateDirectories: true)
            try original.exportJSON().write(to: staged)
        }
        try interruptedFiles()
        let relaunched = KeyboardDimensionStore(directory: directory, exportDirectory: original.exportDirectory)
        try relaunched.recover()
        XCTAssertFalse(FileManager.default.fileExists(atPath: writeOrphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(try relaunched.load().samples, [sample()]) // Recovery doesn't erase consent/samples.
        try relaunched.clear()
        XCTAssertFalse(try relaunched.load().enabled)
        XCTAssertTrue(try relaunched.load().samples.isEmpty)
        // Explicit clear must also work without a preceding successful recovery.
        try interruptedFiles()
        try relaunched.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: writeOrphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.exportDirectory.path))
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "UNRELATED")
        XCTAssertEqual(try String(contentsOf: unrelatedTemporary, encoding: .utf8), "UNRELATED")
    }

    func testActiveExportLeaseSurvivesRecoveryAndBlocksClearOrSecondExport() throws {
        let store = try store(); try store.setEnabled(true)
        try store.append(sample(), generation: store.load().generation, fullAccess: true)
        let export = try store.beginExport()
        let second = KeyboardDimensionStore(directory: store.directory, exportDirectory: store.exportDirectory)
        let before = try Data(contentsOf: export.file)
        try second.recover()
        XCTAssertEqual(try Data(contentsOf: export.file), before)
        XCTAssertThrowsError(try second.clear()) { error in
            guard case KeyboardDimensionError.exportInProgress = error else { return XCTFail("Expected active export") }
        }
        XCTAssertThrowsError(try second.beginExport())
        XCTAssertEqual(try Data(contentsOf: export.file), before)
        XCTAssertEqual(try second.load().samples, [sample()])
        try export.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.file.path))
        let next = try second.beginExport()
        try export.finish() // Old callbacks must never remove a new export's file.
        XCTAssertTrue(FileManager.default.fileExists(atPath: next.file.path))
        try next.finish()
        try second.clear()
        XCTAssertTrue(try second.load().samples.isEmpty)
    }

    func testRecoveryWaitsForActiveStoreWriter() async throws {
        let store = try store(); try store.setEnabled(true)
        let directory = try XCTUnwrap(store.directory)
        let fd = open(directory.appendingPathComponent("store.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        let staging = directory.appendingPathComponent(UUID().uuidString + ".tmp")
        try store.exportJSON().write(to: staging)
        let started = expectation(description: "recovery scheduled")
        let recovered = Task.detached {
            started.fulfill()
            try store.recover()
        }
        await fulfillment(of: [started], timeout: 2)
        // A live writer's temporary must remain until it releases store.lock.
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        try await recovered.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    @MainActor
    func testSettingsControlsAndOffscreenEvidence() async throws {
        let store = try store()
        let page = KeyboardDimensionsViewController(store: store)
        let navigation = UINavigationController(rootViewController: page)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = navigation; window.isHidden = false
        defer { window.isHidden = true }
        page.loadViewIfNeeded(); page.viewWillAppear(false)
        // Wait for the bounded background read, not a real keyboard or simulator interaction.
        var toggle: UISwitch?
        for _ in 0..<100 {
            toggle = page.tableView(page.tableView, cellForRowAt: IndexPath(row: 0, section: 0)).accessoryView as? UISwitch
            if toggle?.isEnabled == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(toggle?.isOn, false); XCTAssertEqual(toggle?.isEnabled, true)
        XCTAssertFalse(page.tableView(page.tableView, cellForRowAt: IndexPath(row: 0, section: 1)).isUserInteractionEnabled)
        XCTAssertEqual(page.tableView(page.tableView, cellForRowAt: IndexPath(row: 1, section: 1)).accessibilityIdentifier, "dimensions.clear")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".airbuild/artifacts/phone-layout")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for style in [UIUserInterfaceStyle.light, .dark] {
            window.overrideUserInterfaceStyle = style; window.layoutIfNeeded(); page.tableView.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let name = style == .light ? "dimensions-settings-light" : "dimensions-settings-dark"
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        }
    }
}
