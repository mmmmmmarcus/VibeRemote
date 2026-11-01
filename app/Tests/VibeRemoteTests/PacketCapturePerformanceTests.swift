import XCTest
import Foundation
@testable import VibeRemote

final class PacketCapturePerformanceTests: XCTestCase {
    private func line(mask: UInt16, at date: Date = Date().addingTimeInterval(0.005), label: String = "Siri Remote") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd HH:mm:ss.SSS"
        return "\(formatter.string(from: date))  \(label)  0x004B  RECV  4B 20 09 00 05 00 04 00 1B 39 00 \(String(format: "%02X %02X", mask & 255, mask >> 8))  \n"
    }
    private func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @MainActor
    func testIdleCaptureDoesNotPollAtTouchCadenceAndNotificationsDeliverOrderedEdges() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        let monitor = PacketLoggerButtonMonitor(labelProvider: { ["Siri Remote"] })
        defer { monitor.stop(); try? FileManager.default.removeItem(at: file) }
        monitor.start(path: file.path); monitor.pollNow()
        let initialPolls = monitor.capturePollCount
        try await Task.sleep(nanoseconds: 250_000_000)
        let idlePolls = monitor.capturePollCount - initialPolls
        XCTAssertLessThan(idlePolls, 4, "Idle file must not retain the former 50 Hz timer")

        var edges: [PacketLoggerButtonParser.Edge] = []
        monitor.onEdge = { edges.append($0) }
        let start = ProcessInfo.processInfo.systemUptime
        // Native Mute establishes menu ownership before Play, then Play releases
        // before Mute. A single file notification must preserve every transition.
        let date = Date()
        try append(line(mask: 0x180, at: date) + line(mask: 0, at: date), to: file)
        for _ in 0..<50 where edges.count < 4 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(edges.map(\.button), ["mute", "playPause", "playPause", "mute"])
        XCTAssertEqual(edges.map(\.pressed), [true, true, false, false])
        XCTAssertEqual(Set(edges.map(\.sender)), [76])
        XCTAssertTrue(edges.allSatisfy { abs($0.capturedAt.timeIntervalSince(date)) < 0.002 })
        print("CAPTURE_BENCH idle_seconds=0.25 new_polls=\(idlePolls) old_expected_polls=12.5 notification_delivery_ms=\((ProcessInfo.processInfo.systemUptime-start)*1000)")
    }

    @MainActor
    func testSynchronousFlushIncludesPendingNotificationBeforeMediaResolution() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        let monitor = PacketLoggerButtonMonitor(labelProvider: { ["Siri Remote"] })
        defer { monitor.stop(); try? FileManager.default.removeItem(at: file) }
        var edges: [PacketLoggerButtonParser.Edge] = []
        monitor.onEdge = { edges.append($0) }
        monitor.start(path: file.path); monitor.pollNow()
        try append(line(mask: 0x80), to: file)
        monitor.pollNow()
        XCTAssertEqual(edges.map(\.pressed), [true], "NX must see pending edge before resolving its 160 ms wait")
        try append(line(mask: 0), to: file)
        monitor.pollNow()
        XCTAssertEqual(edges.map(\.pressed), [true, false])
        monitor.pollNow()
        XCTAssertEqual(edges.count, 2, "Queued notification cannot duplicate a synchronous flush")
    }

    @MainActor
    func testReplacementAndTruncationResetParserAndStopDropsOldEvents() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        let monitor = PacketLoggerButtonMonitor(labelProvider: { ["Siri Remote"] })
        defer { monitor.stop(); try? FileManager.default.removeItem(at: file) }
        var downs = 0, resets = 0
        monitor.onEdge = { if $0.pressed { downs += 1 } }
        monitor.onReset = { resets += 1 }
        monitor.start(path: file.path); monitor.pollNow()
        try append(line(mask: 0x80), to: file); monitor.pollNow()
        let previousResets = resets
        try Data(line(mask: 0x80).utf8).write(to: file, options: .atomic)
        monitor.pollNow()
        XCTAssertEqual(downs, 2, "A replacement is a fresh source state even with the same mask")
        XCTAssertGreaterThan(resets, previousResets)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0); try handle.close()
        monitor.pollNow()
        try append(line(mask: 0x80), to: file); monitor.pollNow()
        XCTAssertEqual(downs, 3)
        monitor.stop()
        try append(line(mask: 0x180), to: file)
        monitor.pollNow()
        XCTAssertEqual(downs, 3)
        XCTAssertFalse(monitor.isReadingCapture)
    }

    @MainActor
    func testMissingFileRecoveryAndPartialLineRetainSourceAndReplayFiltering() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let monitor = PacketLoggerButtonMonitor(labelProvider: { ["Siri Remote"] })
        defer { monitor.stop(); try? FileManager.default.removeItem(at: file) }
        var edges: [PacketLoggerButtonParser.Edge] = []
        monitor.onEdge = { edges.append($0) }
        monitor.start(path: file.path); monitor.pollNow()
        XCTAssertFalse(monitor.isReadingCapture)
        try Data().write(to: file)
        for _ in 0..<30 where !monitor.isReadingCapture { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(monitor.isReadingCapture, "Missing/permission handoff retries must not wait for a file event")
        try append(line(mask: 0x80, at: Date().addingTimeInterval(-5)) + line(mask: 0x80, label: "Other Remote"), to: file)
        let live = line(mask: 0x80)
        let split = live.index(live.startIndex, offsetBy: live.count / 2)
        try append(String(live[..<split]), to: file)
        monitor.pollNow(); XCTAssertTrue(edges.isEmpty)
        try append(String(live[split...]), to: file)
        monitor.pollNow(); XCTAssertEqual(edges.count, 1)
    }
    @MainActor
    func testNotificationDeliversBothGenerationsTouchBeforeFreshnessExpires() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        let monitor = PacketLoggerButtonMonitor(labelProvider: { ["Siri Remote"] })
        defer { monitor.stop(); try? FileManager.default.removeItem(at: file) }
        var frames: [RemoteTextTouchFrame] = [], deliveryAges: [TimeInterval] = []
        monitor.onTouch = { frames.append($0); deliveryAges.append(Date().timeIntervalSince($0.time)) }
        monitor.start(path: file.path); monitor.pollNow()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd HH:mm:ss.SSS"
        let captured = Date().addingTimeInterval(0.005)
        let prefix = "\(formatter.string(from: captured))  Siri Remote  0x004B  RECV  4B 20 "
        try append(prefix + "14 00 10 00 04 00 1B 23 00 01 00 32 2A 4F 01 E4 3C D5 74 81 20 83  \n"
                   + prefix + "12 00 0E 00 04 00 1B 3D 00 32 00 00 00 F5 01 C8 04 03 28 00  \n", to: file)
        for _ in 0..<50 where frames.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(frames.map(\.generation), [.glassTouchSurface, .aluminumClickpad])
        XCTAssertEqual(frames.map(\.count), [1, 1])
        XCTAssertTrue(deliveryAges.allSatisfy { $0 >= 0 && $0 < 0.18 }, "Touch must still be fresh when delivered to the main controller")
        print("CAPTURE_TOUCH_BENCH delivery_age_ms=\(deliveryAges.map { $0 * 1000 })")
    }

    @MainActor
    func testCallbackRestartDoesNotDeliverRemainderOfOldBatch() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let replacement = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file); try Data().write(to: replacement)
        let monitor = PacketLoggerButtonMonitor(labelProvider: { ["Siri Remote"] })
        defer {
            monitor.stop()
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: replacement)
        }
        var names: [String] = []
        monitor.onEdge = { edge in
            names.append(edge.button)
            if names.count == 1 {
                monitor.stop(); monitor.start(path: replacement.path)
            }
        }
        monitor.start(path: file.path); monitor.pollNow()
        try append(line(mask: 0x180), to: file)
        monitor.pollNow()
        XCTAssertEqual(names, ["mute"], "Old play edge must not escape into restarted capture")
        try append(line(mask: 0x100), to: replacement)
        monitor.pollNow()
        XCTAssertEqual(names, ["mute", "playPause"])
    }

}
