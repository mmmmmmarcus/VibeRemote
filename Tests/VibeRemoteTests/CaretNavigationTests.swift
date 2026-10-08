import XCTest
import AppKit
import RemoteAudioProtocol
@testable import VibeRemote

final class CaretNavigationTests: XCTestCase {
    func testCodexTextEndIsReachableRegardlessOfInitialSelection() throws {
        struct Marker { let offset: Int; let isTextLeaf: Bool }
        let text = "放假卡死地方还是了解开会发神经地方回家"
        let ns = text as NSString
        let stops = CaretNavigation.boundaries(text)
        // Reproduce the reported asymmetry: container endpoints give no caret
        // geometry; only the real selection initially supplies a working leaf.
        for selection in [0, 5, ns.length - 2, ns.length] {
            var navigator = CaretMarkerNavigator(text: text, markers: [
                0: Marker(offset: 0, isTextLeaf: false),
                ns.length: Marker(offset: ns.length, isTextLeaf: false)])
            navigator.markers[selection] = Marker(offset: selection, isTextLeaf: true)
            XCTAssertEqual(navigator.seedLeaf(prefix: "", content: text, suffix: "",
                start: Marker(offset: 0, isTextLeaf: true), end: Marker(offset: ns.length, isTextLeaf: true),
                usable: { $0.isTextLeaf }), 2)
            var positions: [Int: CGRect] = [:]
            for offset in CaretNavigation.samplingOrder(text, near: selection) {
                let marker = try XCTUnwrap(navigator.marker(at: offset) { current, forward in
                    guard current.isTextLeaf, let index = stops.firstIndex(of: current.offset) else { return nil }
                    let next = index + (forward ? 1 : -1)
                    guard stops.indices.contains(next) else { return nil }
                    let target = stops[next]
                    return (Marker(offset: target, isTextLeaf: true), ns.substring(with: NSRange(
                        location: min(current.offset, target), length: abs(current.offset - target))))
                })
                XCTAssertTrue(marker.isTextLeaf)
                positions[offset] = CGRect(x: 10 + offset * 14, y: 10, width: 0, height: 18)
            }
            XCTAssertEqual(CaretNavigation.lineSnappedTarget(to: CGPoint(x: 1000, y: 19), positions: positions, current: selection), ns.length,
                           "Reach after 回家 even when entry was before 回家")
            XCTAssertEqual(CaretNavigation.lineSnappedTarget(to: CGPoint(x: 0, y: 19), positions: positions, current: selection), 0)
            XCTAssertEqual(Set(positions.keys), Set(stops))
        }
    }

    func testTextLeafAnchorsRequireExactEditorSpanAndValidGeometry() {
        let text = "a👨‍👩‍👧‍👦中\n回家"
        var navigator = CaretMarkerNavigator(text: text, markers: [0: "real-selection"])
        XCTAssertEqual(navigator.seedLeaf(prefix: "a", content: "👨‍👩‍👧‍👦中", suffix: "\n回家",
            start: "leaf-start", end: "leaf-end", usable: { _ in true }), 2)
        XCTAssertEqual(navigator.markers[1], "leaf-start")
        XCTAssertEqual(navigator.markers[13], "leaf-end")
        let before = navigator.markers
        for (prefix, content, suffix) in [("", "回家", ""), ("a", "wrong", "\n回家"), (text, "", "")] {
            XCTAssertEqual(navigator.seedLeaf(prefix: prefix, content: content, suffix: suffix,
                start: "wrong", end: "wrong", usable: { _ in true }), 0)
        }
        XCTAssertEqual(navigator.seedLeaf(prefix: "", content: text, suffix: "",
            start: "container", end: "container", usable: { _ in false }), 0)
        XCTAssertEqual(navigator.markers, before, "Bad leaves cannot replace a real selection anchor")
    }

    func testEditorSizedCollapsedBoundsAreNotCaretGeometry() {
        // Actual Codex diagnostic: a collapsed marker returned the editor's box
        // instead of the neighboring 0 x 18 insertion rectangles.
        XCTAssertFalse(CaretRangeGeometry.isInsertionRect(CGRect(x: 916, y: 1111, width: 713, height: 44)))
        XCTAssertTrue(CaretRangeGeometry.isInsertionRect(CGRect(x: 945, y: 1112, width: 0, height: 18)))
        XCTAssertTrue(CaretRangeGeometry.isInsertionRect(CGRect(x: 945, y: 1112, width: 2, height: 18)))
        XCTAssertFalse(CaretRangeGeometry.isInsertionRect(.zero))
        XCTAssertFalse(CaretRangeGeometry.isInsertionRect(.null))
    }

    func testContainerMarkersAreReanchoredWithoutChangingTextOffset() {
        struct Marker: Equatable { let offset: Int; let container: Bool }
        for text in ["a", "中", "abc", "你好世界", "👨‍👩‍👧‍👦e\u{301}", "אבג", "a\n"] {
            let stops = CaretNavigation.boundaries(text)
            let value = text as NSString
            let navigator = CaretMarkerNavigator(text: text, markers: [
                0: Marker(offset: 0, container: true),
                value.length: Marker(offset: value.length, container: true)])
            for target in [0, value.length] {
                var visits: [Bool] = []
                let result = navigator.reanchoredMarker(at: target) { marker, forward in
                    visits.append(forward)
                    guard let i = stops.firstIndex(of: marker.offset) else { return nil }
                    let next = i + (forward ? 1 : -1)
                    guard stops.indices.contains(next) else { return nil }
                    let offset = stops[next]
                    return (Marker(offset: offset, container: false), value.substring(with: NSRange(
                        location: min(marker.offset, offset), length: abs(marker.offset - offset))))
                }
                XCTAssertEqual(result, Marker(offset: target, container: false))
                XCTAssertEqual(visits, target == 0 ? [true, false] : [false, true])
                XCTAssertEqual(navigator.markers[target]?.container, true, "Only cache after validating the new insertion rectangle")
            }
        }
    }

    func testReanchoringRejectsWrongTextEmptyTransitionsAndUnbalancedRoundTrips() {
        let navigator = CaretMarkerNavigator(text: "abc", markers: [0: 0, 3: 3])
        XCTAssertNil(navigator.reanchoredMarker(at: 0) { _, _ in (1, "wrong") })
        XCTAssertNil(navigator.reanchoredMarker(at: 0) { _, _ in (1, "") })
        XCTAssertNil(navigator.reanchoredMarker(at: 0) { _, forward in (forward ? 1 : 0, forward ? "a" : "b") })
        XCTAssertNil(navigator.reanchoredMarker(at: 3) { _, _ in (2, "abcd") })
        XCTAssertNil(navigator.reanchoredMarker(at: -1) { _, _ in XCTFail("Invalid offset"); return nil })
    }

    func testSamplingAlwaysIncludesBothEndpointsFirstWithoutSplittingGraphemes() {
        for text in ["", "abc", "你好👨‍👩‍👧‍👦e\u{301}", String(repeating: "x", count: 400)] {
            let order = CaretNavigation.samplingOrder(text, near: text.utf16.count / 2)
            XCTAssertEqual(order.first, 0)
            if !text.isEmpty { XCTAssertEqual(order[1], text.utf16.count) }
            XCTAssertEqual(Set(order), Set(CaretNavigation.boundaries(text)))
            XCTAssertEqual(order.count, Set(order).count)
        }
    }

    private func navigationFrame(_ time: Double, count: Int = 1, sender: UInt64 = 7,
                                 generation: RemoteGeneration = .aluminumClickpad) -> RemoteTextTouchFrame {
        .init(sender: sender, time: Date(timeIntervalSince1970: time), generation: generation, count: count, x: 100, y: 100)
    }

    func testDirectionClickOwnsContactThroughButtonReleaseUntilLift() {
        var gate = CaretNavigationTouchGate()
        XCTAssertFalse(gate.suppress(navigationFrame(10)))
        XCTAssertTrue(gate.button("navDown", down: true, device: "a", generation: .aluminumClickpad, now: Date(timeIntervalSince1970: 10.01)))
        XCTAssertTrue(gate.suppress(navigationFrame(10.02)))
        _ = gate.button("navDown", down: false, device: "a", generation: .aluminumClickpad, now: Date(timeIntervalSince1970: 10.1))
        XCTAssertTrue(gate.suppress(navigationFrame(11)), "Resting after release must not prepare or accumulate travel")
        XCTAssertTrue(gate.suppress(navigationFrame(11.1, count: 0)))
        XCTAssertTrue(gate.suppress(navigationFrame(11.05)), "A delayed old contact cannot reopen preparation after lift")
        XCTAssertFalse(gate.suppress(navigationFrame(11.12)), "A fresh touch immediately restores preparation")
    }

    func testQuickDirectionClickBeforePassiveTouchArrives() {
        var gate = CaretNavigationTouchGate()
        _ = gate.button("navUp", down: true, device: "a", generation: .aluminumClickpad, now: Date(timeIntervalSince1970: 10))
        _ = gate.button("navUp", down: false, device: "a", generation: .aluminumClickpad, now: Date(timeIntervalSince1970: 10.02))
        XCTAssertTrue(gate.suppress(navigationFrame(10.03)))
        XCTAssertTrue(gate.suppress(navigationFrame(10.04, count: 0)))
        XCTAssertFalse(gate.suppress(navigationFrame(10.05)))
        var noTouch = CaretNavigationTouchGate()
        _ = noTouch.button("navUp", down: true, device: "a", generation: .aluminumClickpad, now: Date(timeIntervalSince1970: 10))
        _ = noTouch.button("navUp", down: false, device: "a", generation: .aluminumClickpad, now: Date(timeIntervalSince1970: 10.02))
        XCTAssertFalse(noTouch.suppress(navigationFrame(11)), "Missing reports must not reserve some unrelated future contact")
    }

    func testLiftBeforeDirectionReleaseAndMultipleHeldDirections() {
        var gate = CaretNavigationTouchGate()
        _ = gate.suppress(navigationFrame(10))
        for button in ["navLeft", "navUp"] {
            _ = gate.button(button, down: true, device: "a", generation: .aluminumClickpad, now: Date(timeIntervalSince1970: 10.01))
        }
        XCTAssertTrue(gate.suppress(navigationFrame(10.02, count: 0)))
        _ = gate.button("navLeft", down: false, device: "a", generation: .aluminumClickpad, now: Date(timeIntervalSince1970: 10.03))
        XCTAssertTrue(gate.suppress(navigationFrame(10.04)), "The second direction is still held")
        XCTAssertTrue(gate.suppress(navigationFrame(10.05, count: 0)))
        _ = gate.button("navUp", down: false, device: "a", generation: .aluminumClickpad, now: Date(timeIntervalSince1970: 10.06))
        XCTAssertFalse(gate.suppress(navigationFrame(10.07)))
    }

    func testNavigationContactDoesNotBlockAnotherSourceOrOldRemote() {
        var gate = CaretNavigationTouchGate()
        _ = gate.suppress(navigationFrame(10))
        _ = gate.button("navRight", down: true, device: "a", generation: .aluminumClickpad, now: Date(timeIntervalSince1970: 10.01))
        XCTAssertFalse(gate.suppress(navigationFrame(10.02, sender: 8)))
        XCTAssertFalse(gate.suppress(navigationFrame(10.03, generation: .glassTouchSurface)))
        _ = gate.button("navRight", down: false, device: "b", generation: .aluminumClickpad, now: Date(timeIntervalSince1970: 10.04))
        XCTAssertTrue(gate.suppress(navigationFrame(10.05)))
        for button in ["select", "siri", "power", "volumeUp"] {
            XCTAssertFalse(gate.button(button, down: true, device: "a", generation: .aluminumClickpad, now: Date(timeIntervalSince1970: 11)))
        }
        XCTAssertFalse(gate.button("navUp", down: true, device: "old", generation: .glassTouchSurface, now: Date(timeIntervalSince1970: 11)))
        gate = .init()
        XCTAssertFalse(gate.suppress(navigationFrame(12)), "Source reset removes a lost button/lift lock")
    }

    @MainActor
    func testCaretControllerNeverConsumesDirectionButtonEdges() {
        let controller = RemoteCaretController()
        for button in ["navUp", "navDown", "navLeft", "navRight"] {
            for pressed in [true, false] {
                XCTAssertFalse(controller.button(button, pressed: pressed, device: "a", generation: .aluminumClickpad))
                XCTAssertFalse(controller.isActive)
            }
        }
        controller.stop()
    }

    @MainActor
    func testCaptureMonitorDeliversFreshGlassTouchFromFile() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        try Data().write(to: path)
        let monitor = PacketLoggerButtonMonitor(labelProvider: { ["Siri Remote"] })
        var frames: [RemoteTextTouchFrame] = []
        monitor.onTouch = { frames.append($0) }
        monitor.start(path: path.path)
        defer { monitor.stop() }
        monitor.pollNow()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd HH:mm:ss.SSS"
        // Live PacketLogger records on this Mac led wall time by 80–93 ms.
        let captured = Date().addingTimeInterval(0.09)
        let line = "\(formatter.string(from: captured))  Siri Remote        0x004B  RECV  4B 20 14 00 10 00 04 00 1B 23 00 01 00 32 2A 4F 01 E4 3C D5 74 81 20 83  \n"
        let writer = try FileHandle(forWritingTo: path)
        defer { try? writer.close() }
        try writer.write(contentsOf: Data(line.utf8))
        monitor.pollNow()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.generation, .glassTouchSurface)
    }

    func testCapturedGlassTouchPassesByteRoutingAndParsing() throws {
        let line = "Sep 25 01:37:55.303  Siri Remote        0x004B  RECV  4B 20 14 00 10 00 04 00 1B 23 00 01 00 32 2A 4F 01 E4 3C D5 74 81 20 83  "
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let now = try XCTUnwrap(formatter.date(from: "2026-09-25 01:37:55.330"))
        let data = Data(line.utf8)
        XCTAssertEqual(PacketLoggerLineRoute.classify(data[...]), .touch)
        let frame = try XCTUnwrap(PacketLoggerButtonParser().touch(line: line, allowedLabels: ["Siri Remote"], now: now))
        XCTAssertEqual(frame.generation, .glassTouchSurface)
        XCTAssertEqual(frame.count, 1)
        let ahead = now.addingTimeInterval(-0.12)
        XCTAssertNotNil(PacketLoggerButtonParser().touch(line: line, allowedLabels: ["Siri Remote"], now: ahead))
        XCTAssertNil(PacketLoggerButtonParser().touch(line: line, allowedLabels: ["Siri Remote"], now: now.addingTimeInterval(-1)))
        XCTAssertNil(PacketLoggerButtonParser().touch(line: line, allowedLabels: ["Siri Remote"], now: now.addingTimeInterval(0.2)))
    }

    func testTouchClockTolerancePreservesBothGenerationsAndFrameTiming() throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let now = try XCTUnwrap(formatter.date(from: "2026-09-25 01:37:55.210"))
        let reports: [(String, RemoteGeneration)] = [
            ("14 00 10 00 04 00 1B 23 00 01 00 32 2A 4F 01 E4 3C D5 74 81 20 83", .glassTouchSurface),
            ("12 00 0E 00 04 00 1B 3D 00 32 00 00 00 F5 01 C8 04 03 28 00", .aluminumClickpad)
        ]
        let parser = PacketLoggerButtonParser()
        for (report, generation) in reports {
            let line = "Sep 25 01:37:55.303  Siri Remote  0x004B  RECV  4B 20 \(report)"
            let next = line.replacingOccurrences(of: "55.303", with: "55.314")
            let first = try XCTUnwrap(parser.touch(line: line, allowedLabels: ["Siri Remote"], now: now))
            let second = try XCTUnwrap(parser.touch(line: next, allowedLabels: ["Siri Remote"], now: now))
            XCTAssertEqual(first.generation, generation)
            XCTAssertEqual(first.count, 1)
            XCTAssertEqual(second.time.timeIntervalSince(first.time), 0.011, accuracy: 0.0001)
            XCTAssertEqual(parser.touch(line: line, allowedLabels: ["Siri Remote"], now: now.addingTimeInterval(0.12)), first)
            XCTAssertNil(parser.touch(line: line, allowedLabels: ["Keyboard"], now: now))
            XCTAssertNil(parser.touch(line: line, allowedLabels: ["Siri Remote"], now: now.addingTimeInterval(-0.2)))
            XCTAssertNil(parser.touch(line: line, allowedLabels: ["Siri Remote"], now: now.addingTimeInterval(0.4)))
        }
    }

    func testTextMarkersUseVerifiedLocalUTF16SegmentsInBothDirections() {
        let text = "a中👨‍👩‍👧‍👦e\u{301}"
        let stops = CaretNavigation.boundaries(text)
        let ns = text as NSString
        var navigator = CaretMarkerNavigator(text: text, markers: [2: 2])
        func step(_ offset: Int, _ forward: Bool) -> (Int, String)? {
            guard let i = stops.firstIndex(of: offset) else { return nil }
            let nextIndex = i + (forward ? 1 : -1)
            guard stops.indices.contains(nextIndex) else { return nil }
            let next = stops[nextIndex]
            return (next, ns.substring(with: NSRange(location: min(offset, next), length: abs(offset - next))))
        }
        XCTAssertEqual(navigator.marker(at: ns.length, step: step), ns.length)
        XCTAssertEqual(navigator.marker(at: 0, step: step), 0)
        XCTAssertNil(navigator.marker(at: 3, step: step), "Never land inside an emoji")
        XCTAssertNil(navigator.marker(at: ns.length + 1, step: step))
    }
    func testTextMarkersRejectDifferentEditorContentAndBoundTraversal() {
        var wrong = CaretMarkerNavigator(text: "abc", markers: [0: 0])
        XCTAssertNil(wrong.marker(at: 1) { _, _ in (1, "z") })
        XCTAssertNil(wrong.marker(at: 1) { _, _ in (1, "") })
        var long = CaretMarkerNavigator(text: String(repeating: "a", count: 100), markers: [0: 0])
        var calls = 0
        XCTAssertNil(long.marker(at: 100) { old, _ in calls += 1; return (old + 1, "a") })
        XCTAssertEqual(calls, 64)
        XCTAssertEqual(long.marker(at: 100) { old, _ in (old + 1, "a") }, 100)
    }
    @MainActor
    func testFinalAppBundleCanDecodeCaretArtwork() throws {
        guard let path = ProcessInfo.processInfo.environment["VIBEREMOTE_VERIFY_APP"] else {
            throw XCTSkip("Set VIBEREMOTE_VERIFY_APP to verify the actual packaged app")
        }
        let app = try XCTUnwrap(Bundle(url: URL(fileURLWithPath: path)))
        let resources = try XCTUnwrap(SettingsAssets.bundledResources(in: app))
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let image = try XCTUnwrap(CaretBubbleArtwork.image(appearance: appearance, bundle: resources))
        XCTAssertEqual(image.width, 96)
        XCTAssertEqual(image.height, 128)
    }
    func testCancelledVoiceHoldCannotResumeFromTail() {
        var gate = VoiceSessionGate()
        gate.started(blocked: true)
        XCTAssertFalse(gate.allowsPackets)
        gate.update(blocked: false)
        XCTAssertFalse(gate.allowsPackets)
        gate.started(blocked: false)
        XCTAssertTrue(gate.allowsPackets)
        gate.update(blocked: true)
        gate.update(blocked: false)
        XCTAssertFalse(gate.allowsPackets)
    }
    func testTravelEntryKeepsInactiveGlassClickAsEnter() {
        XCTAssertEqual(RemoteButtonMapping.action(button: "select", generation: .glassTouchSurface,
                                                  siriAction: .rightOpt), .enterKey)
        XCTAssertEqual(RemoteButtonMapping.action(button: "select", generation: .aluminumClickpad,
                                                  siriAction: .rightOpt), .none)
        XCTAssertFalse(ButtonAction.positionCaret.isAssignableToSiriButton)
        XCTAssertEqual(AdvancedMenuInputState.action(button: "playPause", generation: .aluminumClickpad), .stopTask)
    }
    func testGraphemeStopsNeverSplitEmojiOrCombiningMarks() {
        let text = "a中👨‍👩‍👧‍👦e\u{301}"
        XCTAssertEqual(CaretNavigation.boundaries(text), [0, 1, 2, 13, 15])
        XCTAssertEqual(CaretNavigation.boundaries(""), [0])
    }
    func testReleaseChoosesClosestStopWithoutDraggingHysteresis() {
        let map = [0: CGRect(x: 0, y: 0, width: 2, height: 20), 1: CGRect(x: 10, y: 0, width: 2, height: 20)]
        XCTAssertEqual(CaretNavigation.nearest(to: CGPoint(x: 5.5, y: 10), positions: map, current: 0), 1)
        XCTAssertEqual(CaretNavigation.nearest(to: CGPoint(x: 4.5, y: 10), positions: map, current: 1), 0)
        XCTAssertEqual(CaretNavigation.nearest(to: CGPoint(x: 6.1, y: 10), positions: map, current: 0), 1)
        XCTAssertEqual(CaretNavigation.nearest(to: CGPoint(x: 3.9, y: 10), positions: map, current: 1), 0)
        XCTAssertEqual(CaretNavigation.nearest(to: CGPoint(x: 5, y: 10), positions: map, current: 1), 1)
        XCTAssertEqual(CaretNavigation.nearest(to: CGPoint(x: 8, y: 10), positions: map, current: 0), 1)
        XCTAssertEqual(CaretNavigation.nearest(to: CGPoint(x: 10000, y: 10), positions: map, current: 0), 1)
    }
    func testCaretIdleExpiresOnceThreeSecondsAfterEntryOrMovement() {
        var idle = CaretIdleDeadline()
        XCTAssertFalse(idle.takeExpired(at: 100), "Preparation has no auto-commit deadline")
        idle.moved(at: 100)
        XCTAssertFalse(idle.takeExpired(at: 104))
        idle.start(at: 200)
        XCTAssertFalse(idle.takeExpired(at: 202.999))
        idle.moved(at: 202.5)
        XCTAssertFalse(idle.takeExpired(at: 203), "Movement restarts the three-second interval")
        XCTAssertFalse(idle.takeExpired(at: 205.499))
        XCTAssertTrue(idle.takeExpired(at: 205.5))
        XCTAssertFalse(idle.takeExpired(at: 206), "Expiry is consumed exactly once")
        idle.moved(at: 207)
        XCTAssertFalse(idle.takeExpired(at: 211), "Expired sessions cannot restart from movement alone")
    }

    func testCaretIdleCancellationAndNewSessionDoNotShareDeadlines() {
        var idle = CaretIdleDeadline()
        idle.start(at: 10)
        idle.reset()
        XCTAssertFalse(idle.takeExpired(at: 20), "Focus loss, typing or manual commit cancels pending expiry")
        idle.start(at: 30)
        XCTAssertFalse(idle.takeExpired(at: 32.999))
        XCTAssertTrue(idle.takeExpired(at: 33))
    }

    func testStationaryTouchAndFilteredJitterDoNotKeepCaretAlive() {
        var idle = CaretIdleDeadline()
        var motion = CaretMotionFilter()
        idle.start(at: 0)
        for i in 0..<180 {
            let movement = motion.movement(dx: i % 3 == 0 ? 0 : (i % 3 == 1 ? 5 : -5), dy: 0)
            if movement != .zero { idle.moved(at: Double(i) / 60) }
        }
        XCTAssertTrue(idle.takeExpired(at: 3), "Stationary report traffic and tiny reversible jitter must not postpone expiry")
    }

    func testTouchFilterAbsorbsClickJitterButAccumulatesSlowMotion() {
        var filter = CaretMotionFilter()
        for _ in 0..<20 {
            XCTAssertEqual(filter.movement(dx: 10, dy: -8), .zero)
            XCTAssertEqual(filter.movement(dx: -10, dy: 8), .zero)
        }
        var total = CGPoint.zero
        for _ in 0..<30 {
            let delta = filter.movement(dx: 2, dy: 0)
            total.x += delta.x; total.y += delta.y
        }
        XCTAssertEqual(total.x, 2.95, accuracy: 0.001)
        XCTAssertEqual(total.y, 0)
        filter.reset()
        XCTAssertEqual(filter.movement(dx: 0, dy: 10), .zero)
        XCTAssertLessThan(filter.movement(dx: 0, dy: 30).y, 0, "Remote up must remain screen up")
    }
    func testDragPreviewMovesHorizontallyButRemainsOnItsTextRow() {
        let editor = CGRect(x: 100, y: 100, width: 200, height: 100)
        let aim = CGPoint(x: 115.6, y: 126.3)
        let line = CGRect(x: 120, y: 124, width: 2, height: 16)
        let free = CaretNavigation.preview(at: aim, line: line, editor: editor)
        XCTAssertEqual(free.minX, aim.x)
        XCTAssertEqual(free.midY, line.midY)
        XCTAssertNotEqual(free.midY, aim.y, "The visible caret never floats between rows")
        let edge = CaretNavigation.preview(at: CGPoint(x: 90, y: 205), line: line, editor: editor)
        XCTAssertEqual(edge.minX, editor.minX)
        XCTAssertEqual(edge.minY, line.minY)
        // Partly visible rows retain their actual insertion geometry; the view clips them.
        let partial = line.offsetBy(dx: 0, dy: -30)
        XCTAssertEqual(CaretNavigation.preview(at: aim, line: partial, editor: editor).minY, partial.minY)
    }

    func testVerticalLineSnapResistsBoundaryFlutterInBothDirections() {
        let rows = [0: CGRect(x: 10, y: 0, width: 2, height: 20),
                    1: CGRect(x: 10, y: 20, width: 2, height: 20)]
        func target(_ y: CGFloat, from row: Int) -> Int? {
            CaretNavigation.lineSnappedTarget(to: CGPoint(x: 10, y: y), positions: rows, current: row)
        }
        XCTAssertEqual(target(22, from: 0), 0, "Passing the midpoint alone must not switch")
        XCTAssertEqual(target(23, from: 0), 1)
        for y: CGFloat in [23, 22, 20, 18] { XCTAssertEqual(target(y, from: 1), 1) }
        XCTAssertEqual(target(17, from: 1), 0)
        XCTAssertEqual(target(18, from: 0), 0)
    }

    func testHorizontalMovementCannotJumpToALongerAdjacentLine() {
        let rows = [0: CGRect(x: 0, y: 0, width: 2, height: 20),
                    1: CGRect(x: 40, y: 0, width: 2, height: 20),
                    2: CGRect(x: 200, y: 20, width: 2, height: 20)]
        XCTAssertEqual(CaretNavigation.lineSnappedTarget(to: CGPoint(x: 200, y: 10), positions: rows, current: 0), 1)
        XCTAssertEqual(CaretNavigation.lineSnappedTarget(to: CGPoint(x: 20.1, y: 10), positions: rows, current: 0), 1)
        XCTAssertEqual(CaretNavigation.lineSnappedTarget(to: CGPoint(x: 19.9, y: 10), positions: rows, current: 1), 0)
        XCTAssertEqual(CaretNavigation.lineSnappedTarget(to: CGPoint(x: 200, y: 23), positions: rows, current: 1), 2)
    }

    func testLineSnapUsesActualSpacingAndStopsAtFirstAndLastLine() {
        let rows = [0: CGRect(x: 0, y: 0, width: 2, height: 20),
                    1: CGRect(x: 0, y: 40, width: 2, height: 20),
                    2: CGRect(x: 0, y: 100, width: 2, height: 20)]
        func target(_ y: CGFloat, from row: Int) -> Int? {
            CaretNavigation.lineSnappedTarget(to: CGPoint(x: 0, y: y), positions: rows, current: row)
        }
        XCTAssertEqual(target(35, from: 0), 0)
        XCTAssertEqual(target(36, from: 0), 1)
        XCTAssertEqual(target(88, from: 1), 1)
        XCTAssertEqual(target(89, from: 1), 2)
        XCTAssertEqual(target(-200, from: 0), 0)
        XCTAssertEqual(target(400, from: 2), 2)
        XCTAssertEqual(target(110, from: 0), 2, "Deliberate long travel can cross multiple rows")
        XCTAssertNil(CaretNavigation.lineSnappedTarget(to: .zero, positions: [:], current: 0))
    }
    func testOverlayAnchorStaysAtInsertionPointIncludingEditorEdges() {
        let editor = CGRect(x: -800, y: 300, width: 400, height: 80)
        for caret in [CGRect(x: -800, y: 300, width: 0, height: 20),
                      CGRect(x: -400, y: 360, width: 0, height: 20),
                      CGRect(x: -650, y: 320, width: 0, height: 20)] {
            let position = CaretOverlayGeometry.position(caret: caret, editor: editor)
            XCTAssertEqual(position.x + editor.minX, caret.minX)
            XCTAssertEqual(position.y + editor.minY, caret.midY)
        }
    }
    @MainActor
    func testScreenCaretConvertsThroughActualWindowAndLayer() throws {
        final class FlippedCanvas: NSView { override var isFlipped: Bool { true } }
        for flipped in [false, true] {
            let window = NSWindow(contentRect: CGRect(x: 200, y: 300, width: 400, height: 160),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let canvas: NSView = flipped ? FlippedCanvas() : NSView()
            canvas.wantsLayer = true
            window.contentView = canvas
            for layerFlipped in [false, true] {
                canvas.layer?.isGeometryFlipped = layerFlipped
                // Include two text lines and a window move; local AX subtraction alone
                // is not sufficient when AppKit adjusts the actual window origin.
                for y: CGFloat in [40, 70] {
                    let screen = window.convertPoint(toScreen: CGPoint(x: 100, y: y))
                    let caret = CGRect(x: screen.x, y: 1080 - screen.y - 10, width: 0, height: 20)
                    let point = try XCTUnwrap(CaretOverlayGeometry.layerPosition(caret: caret, primaryScreenTop: 1080, in: canvas))
                    let rendered = window.convertPoint(toScreen: canvas.convert(canvas.convertFromLayer(point), to: nil))
                    XCTAssertEqual(rendered.x, screen.x, accuracy: 0.01)
                    XCTAssertEqual(rendered.y, screen.y, accuracy: 0.01)
                }
                window.setFrameOrigin(CGPoint(x: -300, y: 200))
            }
            window.close()
        }
    }
    func testGeometryChangeInvalidatesStaleCommit() {
        let caret = CGRect(x: 120, y: 50, width: 0, height: 20)
        XCTAssertTrue(CaretOverlayGeometry.aligned(caret, caret))
        XCTAssertFalse(CaretOverlayGeometry.aligned(caret, caret.offsetBy(dx: 3, dy: 0)))
        XCTAssertFalse(CaretOverlayGeometry.aligned(caret, caret.offsetBy(dx: 0, dy: 20)))
    }
    @MainActor
    func testNativeTextInsertionRectMatchesDrawnCaretOnEveryLine() throws {
        let window = NSWindow(contentRect: CGRect(x: 200, y: 300, width: 400, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let text = NSTextView(frame: CGRect(x: 20, y: 20, width: 360, height: 160))
        text.string = "First line\nSecond line\nThird line"
        text.font = .systemFont(ofSize: 16)
        window.contentView?.addSubview(text)
        window.makeFirstResponder(text)
        let container = try XCTUnwrap(text.textContainer)
        text.layoutManager?.ensureLayout(for: container)
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let editorScreen = window.convertToScreen(text.convert(text.bounds, to: nil))
        let editor = CGRect(x: editorScreen.minX, y: top - editorScreen.maxY,
                            width: editorScreen.width, height: editorScreen.height)
        let overlay = CaretOverlay()
        defer { overlay.panel?.close() }
        for offset in [0, 5, 10, 11, 16, 22, 23, 33] {
            let range = NSRange(location: offset, length: 0)
            text.setSelectedRange(range)
            // Independent AppKit text-input geometry, not a layer round trip.
            let native = text.firstRect(forCharacterRange: range, actualRange: nil)
            XCTAssertGreaterThan(native.height, 0)
            func axBounds(_ requested: NSRange) -> CGRect? {
                let r = text.accessibilityFrame(for: requested)
                guard r.height > 0 else { return nil }
                return CGRect(x: r.minX, y: top - r.maxY, width: r.width, height: r.height)
            }
            let correction = try XCTUnwrap(CaretRangeGeometry.correction(text: text.string, near: offset, bounds: axBounds))
            let raw = try XCTUnwrap(axBounds(range))
            let caret = correction.apply(to: raw)
            XCTAssertEqual(caret.minY, top - native.maxY, accuracy: 0.5)
            overlay.show(caret: caret, editor: editor, progress: 1, present: false)
            let panel = try XCTUnwrap(overlay.panel)
            let canvas = try XCTUnwrap(overlay.canvas)
            let rendered = panel.convertToScreen(canvas.convert(canvas.stemRect, to: nil))
            XCTAssertEqual(rendered.midX, native.minX, accuracy: 0.01)
            XCTAssertEqual(rendered.minY, native.minY, accuracy: 0.01)
            XCTAssertEqual(rendered.height, native.height, accuracy: 0.01)
            XCTAssertEqual(rendered.width, 2)
            XCTAssertNotNil(canvas.artwork)
            canvas.opacity = 1; canvas.expansion = 1; canvas.symbolOpacity = 1
            let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            if let path = ProcessInfo.processInfo.environment["VIBEREMOTE_CARET_PREVIEW"] {
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }
    func testCorrectAXProvidersAreNotShiftedAndMissingGeometryIsRejected() throws {
        let native = CGRect(x: 100, y: 300, width: 0, height: 18)
        let correction = try XCTUnwrap(CaretRangeGeometry.correction(text: "ab", near: 0) { range in
            CGRect(x: 100, y: 300, width: range.length == 0 ? 0 : 8, height: 18)
        })
        XCTAssertEqual(correction.apply(to: native), native)
        XCTAssertNil(CaretRangeGeometry.correction(text: "", near: 0) { _ in native })
        XCTAssertNil(CaretRangeGeometry.correction(text: "ab", near: 0) { _ in nil })
    }
    func testVerticalMovementChoosesCharacterOnNextLine() {
        let map = [0: CGRect(x: 10, y: 0, width: 2, height: 20), 1: CGRect(x: 10, y: 25, width: 2, height: 20)]
        XCTAssertEqual(CaretNavigation.nearest(to: CGPoint(x: 10, y: 35), positions: map, current: 0), 1)
    }
    func testCenterDoesNotEnterCaretThroughButtonGate() {
        var gate = CaretButtonGate()
        XCTAssertEqual(gate.handle(button: "select", down: true, device: "a", active: false), .pass)
        XCTAssertEqual(gate.handle(button: "select", down: false, device: "a", active: true), .pass)
    }
    func testSiriAndPowerExitAndOwnReleaseAfterModeEnds() {
        for key in ["siri", "power"] {
            var gate = CaretButtonGate()
            XCTAssertEqual(gate.handle(button: key, down: true, device: "a", active: true), key == "siri" ? .exitVoice : .exit)
            XCTAssertEqual(gate.handle(button: key, down: true, device: "a", active: false), .consume)
            XCTAssertEqual(gate.handle(button: key, down: false, device: "a", active: false), .consume)
            XCTAssertEqual(gate.handle(button: key, down: true, device: "a", active: false), .pass)
        }
    }
    func testAnotherRemoteCannotReleaseOwnedButton() {
        var gate = CaretButtonGate()
        _ = gate.handle(button: "siri", down: true, device: "a", active: true)
        XCTAssertEqual(gate.handle(button: "siri", down: false, device: "b", active: true), .pass)
        XCTAssertEqual(gate.handle(button: "siri", down: true, device: "a", active: true), .consume)
    }
    func testPassiveTouchDecoderRetainsContactAndLift() {
        let payload: [UInt8] = [0x32, 0x34, 0x73, 1, 0x46, 0xcf, 0xdc, 0x72, 0x72, 0xf, 0x6c]
        let frame = RemoteTextTouchFrame.decode(payload, sender: 1, time: Date())
        XCTAssertEqual(frame?.generation, .aluminumClickpad)
        XCTAssertEqual(frame?.count, 1); XCTAssertEqual(frame?.x, -186); XCTAssertEqual(frame?.y, -564)
        var hover = payload; hover[10] |= 2
        XCTAssertEqual(RemoteTextTouchFrame.decode(hover, sender: 1, time: Date())?.count, 0)
        XCTAssertNil(RemoteTextTouchFrame.decode([0x32], sender: 1, time: Date()))
    }

    func testGlassTouchDecoderRejectsVoiceAndPreservesLift() {
        let contact: [UInt8] = [1, 0, 0x32, 0, 0, 9, 245, 1, 200, 4, 3, 40, 0]
        let frame = RemoteTextTouchFrame.decodeGlass(contact, sender: 4, time: Date())
        XCTAssertEqual(frame?.generation, .glassTouchSurface)
        XCTAssertEqual(frame?.count, 1)
        XCTAssertEqual(frame?.x, 270)
        XCTAssertEqual(frame?.y, 180)
        // Physical capture keeps the advertised finger count at one while the
        // contact ellipse and pressure become zero on the final two reports.
        var lift = contact; lift[9] = 0; lift[10] = 0; lift[11] = 0
        XCTAssertEqual(lift[0], 1)
        XCTAssertEqual(RemoteTextTouchFrame.decodeGlass(lift, sender: 4, time: Date())?.count, 0)
        XCTAssertNil(RemoteTextTouchFrame.decodeGlass(Array(repeating: 0, count: 99), sender: 4, time: Date()))
        var wrongMarker = contact; wrongMarker[2] = 0xfa
        XCTAssertNil(RemoteTextTouchFrame.decodeGlass(wrongMarker, sender: 4, time: Date()))
    }

    private func travelFrame(_ time: TimeInterval, x: Int = 0, y: Int = 0, count: Int = 1,
                             sender: UInt64 = 8, generation: RemoteGeneration = .aluminumClickpad) -> RemoteTextTouchFrame {
        .init(sender: sender, time: Date(timeIntervalSince1970: 100 + time), generation: generation,
              count: count, x: x, y: y)
    }

    func testPreparationFollowsContactAndReversesBeforeActivation() throws {
        for generation in [RemoteGeneration.aluminumClickpad, .glassTouchSurface] {
            var gate = RemoteCaretTravelGate()
            XCTAssertFalse(gate.observe(travelFrame(0, generation: generation)))
            let first = try XCTUnwrap(gate.contactID)
            XCTAssertEqual(gate.progress, 0)
            XCTAssertEqual(gate.preparationLean, 0)
            XCTAssertFalse(gate.observe(travelFrame(0.05, x: 90, generation: generation)))
            XCTAssertEqual(gate.contactID, first)
            XCTAssertLessThan(gate.preparationLean, 0, "Unflipped balloon leans right with a rightward finger")
            XCTAssertFalse(gate.observe(travelFrame(0.10, x: -90, generation: generation)))
            XCTAssertGreaterThan(gate.preparationLean, 0)
            XCTAssertEqual(gate.progress, 270.0 / 1000, accuracy: 0.001)
            XCTAssertLessThanOrEqual(abs(gate.preparationLean), 0.32)
            XCTAssertFalse(gate.observe(travelFrame(0.15, x: 120, generation: generation)), "The previous 480-unit threshold now stays in preparation")
            XCTAssertFalse(gate.observe(travelFrame(0.18, x: 360, generation: generation)), "720 units still previews")
            XCTAssertTrue(gate.observe(travelFrame(0.19, x: 640, generation: generation)))
            XCTAssertEqual(gate.progress, 1)
            XCTAssertFalse(gate.observe(travelFrame(0.2, count: 0, generation: generation)))
            XCTAssertNil(gate.contactID)
            XCTAssertEqual(gate.progress, 0)
            XCTAssertEqual(gate.preparationLean, 0)
            XCTAssertFalse(gate.observe(travelFrame(0.25, x: 120, generation: generation)))
            XCTAssertNotEqual(gate.contactID, first)
            XCTAssertEqual(gate.preparationLean, 0, "A fresh contact must not inherit a stale finger origin")
        }
    }

    func testPreparationRestartsOnDiscontinuityWithoutCountingItAsTravel() throws {
        let interruptions = [travelFrame(0.2, sender: 9), travelFrame(0.2, generation: .glassTouchSurface),
                             travelFrame(0.6), travelFrame(0.05), travelFrame(0.2, x: 1500)]
        for frame in interruptions {
            var gate = RemoteCaretTravelGate()
            _ = gate.observe(travelFrame(0))
            _ = gate.observe(travelFrame(0.1, x: 200))
            let original = try XCTUnwrap(gate.contactID)
            XCTAssertFalse(gate.observe(frame))
            XCTAssertNotEqual(gate.contactID, original)
            XCTAssertEqual(gate.progress, 0)
            XCTAssertEqual(gate.preparationLean, 0)
        }
    }

    func testBalloonSpringReversesContinuouslyAndSettlesAfterExtraction() {
        var lean = CaretBubbleSpring()
        for _ in 0..<5 { lean.advance(to: 0.32, elapsed: 1.0 / 60, response: 0.23, damping: 0.72) }
        let before = lean.value
        lean.advance(to: -0.32, elapsed: 0, response: 0.23, damping: 0.72)
        XCTAssertEqual(lean.value, before, "Retargeting must not teleport the rendered balloon")
        for _ in 0..<120 {
            lean.advance(to: -0.32, elapsed: 1.0 / 60, response: 0.23, damping: 0.72)
            XCTAssertLessThan(abs(lean.value), 0.4)
        }
        XCTAssertTrue(lean.isSettled(at: -0.32))
        var scale = CaretBubbleSpring(value: 0.78, velocity: 0.3)
        var maximum: CGFloat = 0
        for _ in 0..<120 {
            scale.advance(to: 1, elapsed: 1.0 / 60, response: 0.26, damping: 0.76)
            maximum = max(maximum, scale.value)
        }
        XCTAssertGreaterThan(maximum, 1, "Crossing the threshold gives a small extraction overshoot")
        XCTAssertLessThan(maximum, 1.04)
        XCTAssertTrue(scale.isSettled(at: 1))
        scale.advance(to: 0, elapsed: 5, response: 0.26, damping: 0.9)
        XCTAssertGreaterThan(scale.value, 0, "A stalled run loop must not explode the spring")
        for _ in 0..<120 { scale.advance(to: 0, elapsed: 1.0 / 60, response: 0.26, damping: 0.9) }
        XCTAssertTrue(scale.isSettled(at: 0))
    }

    @MainActor
    func testCaretDismissalShrinksBeforeFadingAndCanReverseInFlight() throws {
        let caret = CGRect(x: 300, y: 300, width: 0, height: 18)
        let editor = CGRect(x: 100, y: 280, width: 400, height: 100)
        for progress: CGFloat in [0, 1] {
            let overlay = CaretOverlay()
            defer { overlay.hide(); overlay.panel?.close() }
            overlay.show(caret: caret, editor: editor, progress: progress, present: false)
            for _ in 0..<90 { overlay.advanceAnimation(elapsed: 1.0 / 60, reduceMotion: false) }
            let canvas = try XCTUnwrap(overlay.canvas)
            let initial = canvas.expansion, stem = canvas.stemRect
            overlay.hide()
            for _ in 0..<4 { overlay.advanceAnimation(elapsed: 1.0 / 60, reduceMotion: false) }
            XCTAssertLessThan(canvas.expansion, initial)
            XCTAssertGreaterThan(canvas.expansion, 0.2)
            XCTAssertEqual(canvas.opacity, 1, accuracy: 0.001, "Retraction must stay visible, not disappear before it shrinks")
            XCTAssertEqual(canvas.stemRect, stem)
            let interrupted = canvas.expansion
            overlay.show(caret: caret, editor: editor, progress: 1, present: false)
            XCTAssertEqual(canvas.expansion, interrupted, "Reopening begins at the live animation value")
            for _ in 0..<90 { overlay.advanceAnimation(elapsed: 1.0 / 60, reduceMotion: false) }
            XCTAssertEqual(canvas.expansion, 1)
            XCTAssertEqual(canvas.opacity, 1)
            overlay.hide()
            for _ in 0..<90 { overlay.advanceAnimation(elapsed: 1.0 / 60, reduceMotion: false) }
            XCTAssertEqual(canvas.expansion, 0)
            XCTAssertEqual(canvas.opacity, 0)
            XCTAssertFalse(overlay.advanceAnimation(elapsed: 1.0 / 60, reduceMotion: false))
        }
    }

    @MainActor
    func testCaretDismissalRespectsReduceMotion() throws {
        let overlay = CaretOverlay()
        defer { overlay.panel?.close() }
        overlay.show(caret: CGRect(x: 300, y: 300, width: 0, height: 18),
                     editor: CGRect(x: 100, y: 280, width: 400, height: 100), progress: 1, present: false)
        for _ in 0..<60 { overlay.advanceAnimation(elapsed: 1.0 / 60, reduceMotion: true) }
        overlay.hide()
        overlay.advanceAnimation(elapsed: 1.0 / 60, reduceMotion: true)
        let canvas = try XCTUnwrap(overlay.canvas)
        XCTAssertEqual(canvas.lean, 0)
        XCTAssertLessThan(canvas.opacity, 1, "Reduce Motion fades without waiting for a spring")
        for _ in 0..<60 { overlay.advanceAnimation(elapsed: 1.0 / 60, reduceMotion: true) }
        XCTAssertEqual(canvas.opacity, 0)
    }

    @MainActor
    func testSwayingBalloonKeepsStemFixedAndFitsInsidePanel() throws {
        let overlay = CaretOverlay()
        defer { overlay.hide(); overlay.panel?.close() }
        let caret = CGRect(x: 300.25, y: 300.5, width: 0, height: 18)
        overlay.show(caret: caret, editor: CGRect(x: 100, y: 280, width: 400, height: 100), progress: 0, present: false)
        let canvas = try XCTUnwrap(overlay.canvas)
        let stem = canvas.stemRect
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        canvas.appearance = appearance
        canvas.previewArtwork = NSImage(cgImage: try XCTUnwrap(CaretBubbleArtwork.image(appearance: appearance, includeSymbol: false)), size: CGSize(width: 24, height: 32))
        canvas.artwork = NSImage(cgImage: try XCTUnwrap(CaretBubbleArtwork.image(appearance: appearance)), size: CGSize(width: 24, height: 32))
        let stages: [(CGFloat, CGFloat, CGFloat)] = [(0.65, 0, 0), (0.72, 0.32, 0), (0.78, -0.32, 0), (1.03, 0.08, 1), (1, 0, 1),
                                                  (0.65, -0.38, 0), (0.65, 0.38, 0), (1, -0.38, 1), (1, 0.38, 1)]
        for (index, stage) in stages.enumerated() {
            canvas.opacity = 1; canvas.expansion = stage.0; canvas.lean = stage.1; canvas.symbolOpacity = stage.2
            XCTAssertEqual(canvas.stemRect, stem)
            let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            for x in [0, bitmap.pixelsWide - 1] {
                for y in 0..<bitmap.pixelsHigh { XCTAssertLessThan(bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0, 0.01) }
            }
            for x in 0..<bitmap.pixelsWide {
                XCTAssertLessThan(bitmap.colorAt(x: x, y: 0)?.alphaComponent ?? 0, 0.01, "Balloon must not be cut off above the panel")
            }
            // Check actual ink over a white backdrop, not just a geometrical overlap
            // or the alpha of the pale shadow. Every row through the join needs a
            // solid dark connection, including fractional alignment and spring sway.
            let scale = CGFloat(bitmap.pixelsWide) / canvas.bounds.width
            let joinY = (canvas.bounds.height - stem.maxY) * scale
            let centerX = stem.midX * scale
            for y in Int(joinY - 3 * scale)...Int(joinY + 3 * scale) {
                var darkest: CGFloat = 1
                for x in Int(centerX - 4 * scale)...Int(centerX + 4 * scale) {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                    let lightness = max(color.redComponent, color.greenComponent, color.blueComponent)
                    darkest = min(darkest, lightness * color.alphaComponent + 1 - color.alphaComponent)
                }
                XCTAssertLessThan(darkest, 0.25, "Visible seam at balloon/stem junction, stage \(index), row \(y)")
            }
            if let path = ProcessInfo.processInfo.environment["VIBEREMOTE_CARET_MOTION_PREVIEW"] {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(path)-\(index).png"))
            }
        }
    }

    func testTravelDistanceActivatesInAnyDirectionOnBothGenerations() {
        let paths = [[(0, 0), (500, 0), (1000, 0)], // straight, no reversal
                     [(0, 0), (0, 500), (0, 1000)],
                     [(0, 0), (300, 400), (600, 800)], // diagonal path length
                     [(0, 0), (500, 0), (500, 500)], // right angle
                     [(0, 0), (500, 0), (0, 0)]] // zero net displacement
        for generation in [RemoteGeneration.glassTouchSurface, .aluminumClickpad] {
            for path in paths {
                var gate = RemoteCaretTravelGate()
                for (i, point) in path.enumerated() {
                    XCTAssertEqual(gate.observe(travelFrame(Double(i) * 0.1, x: point.0, y: point.1,
                                                           generation: generation)), i == 2)
                }
                XCTAssertEqual(gate.latest?.generation, generation)
            }
        }
    }

    func testTravelCountsSlowIntentionalMotionWithoutCountingSmallJitter() {
        var gate = RemoteCaretTravelGate()
        for i in 0..<100 {
            XCTAssertFalse(gate.observe(travelFrame(Double(i) * 0.1, x: i % 2 == 0 ? 0 : 5)))
        }
        gate.reset()
        // Each sample is below the noise cutoff, but sustained travel still counts.
        // The 12-unit noise filter first counts past 1000 at 1008 raw units.
        for i in 0...252 {
            XCTAssertEqual(gate.observe(travelFrame(Double(i) * 0.1, x: i * 4)), i == 252)
        }
    }

    func testTravelCannotCombineSeparateContactsSourcesOrDiscontinuousReports() {
        let interruptions = [travelFrame(0.2, x: 240, count: 0),
                             travelFrame(0.2, x: 240, count: 2),
                             travelFrame(0.2, x: 240, sender: 9),
                             travelFrame(0.2, x: 240, generation: .glassTouchSurface),
                             travelFrame(0.6, x: 240), // missed frames
                             travelFrame(0.05, x: 240), // reordered frame
                             travelFrame(0.2, x: 1400)] // coordinate jump
        for frame in interruptions {
            var gate = RemoteCaretTravelGate()
            XCTAssertFalse(gate.observe(travelFrame(0)))
            XCTAssertFalse(gate.observe(travelFrame(0.1, x: 240)))
            XCTAssertFalse(gate.observe(frame))
            XCTAssertFalse(gate.observe(travelFrame(frame.time.timeIntervalSince1970 - 100 + 0.1,
                                                    x: frame.x + 240, sender: frame.sender,
                                                    generation: frame.generation)))
        }
    }

    func testCenterConfirmationOwnsRepeatsAndReleaseWithoutSubmittingEnter() {
        for generation in [RemoteGeneration.glassTouchSurface, .aluminumClickpad] {
            var gate = CaretButtonGate()
            XCTAssertEqual(gate.handle(button: "select", down: true, device: generation.rawValue, active: true), .confirm)
            // Commit ends the mode, but the remainder of this physical click stays consumed.
            XCTAssertEqual(gate.handle(button: "select", down: true, device: generation.rawValue, active: false), .consume)
            XCTAssertEqual(gate.handle(button: "select", down: false, device: "other", active: false), .pass)
            XCTAssertEqual(gate.handle(button: "select", down: false, device: generation.rawValue, active: false), .consume)
            XCTAssertEqual(gate.handle(button: "select", down: true, device: generation.rawValue, active: false), .pass)
        }
    }

    func testGlassSwipeSendsOneDirectionOnLiftAndLeavesAluminumUnchanged() {
        let origin = Date(timeIntervalSince1970: 100)
        func frame(_ time: TimeInterval, x: Int, y: Int, count: Int = 1,
                   generation: RemoteGeneration = .glassTouchSurface) -> RemoteTextTouchFrame {
            .init(sender: 8, time: origin.addingTimeInterval(time), generation: generation,
                  count: count, x: x, y: y)
        }
        let strokes: [(Int, Int, RemoteTouchSwipeDirection)] = [
            (180, 20, .right), (-180, -20, .left), (20, 180, .up), (-20, -180, .down)
        ]
        for (x, y, expected) in strokes {
            var gate = RemoteTouchSwipeGate()
            XCTAssertNil(gate.observe(frame(0, x: 0, y: 0)))
            XCTAssertNil(gate.observe(frame(0.18, x: x, y: y)))
            XCTAssertEqual(gate.observe(frame(0.22, x: 0, y: 0, count: 0)), expected)
            // Physical black-glass lift sends a duplicate zero-pressure report.
            XCTAssertNil(gate.observe(frame(0.231, x: 0, y: 0, count: 0)))
            XCTAssertFalse(gate.isTracking)
        }
        var aluminum = RemoteTouchSwipeGate()
        XCTAssertNil(aluminum.observe(frame(0, x: 0, y: 0, generation: .aluminumClickpad)))
        XCTAssertNil(aluminum.observe(frame(0.2, x: 300, y: 0, count: 0, generation: .aluminumClickpad)))
    }

    func testGlassCaretTravelTakesOwnershipBeforeSwipeLift() {
        let origin = Date(timeIntervalSince1970: 100)
        var travel = RemoteCaretTravelGate()
        var swipe = RemoteTouchSwipeGate()
        var entered = false
        for (index, x) in [0, 250, 500, 750, 1000].enumerated() {
            let frame = RemoteTextTouchFrame(sender: 8, time: origin.addingTimeInterval(Double(index) * 0.08),
                                            generation: .glassTouchSurface, count: 1, x: x, y: 0)
            XCTAssertNil(swipe.observe(frame))
            if travel.observe(frame) { swipe.reset(); entered = true }
        }
        XCTAssertTrue(entered)
        let lift = RemoteTextTouchFrame(sender: 8, time: origin.addingTimeInterval(0.4),
                                       generation: .glassTouchSurface, count: 0, x: 0, y: 0)
        XCTAssertNil(swipe.observe(lift), "A gesture entering caret mode cannot also navigate on lift")
    }

    func testGlassSwipeRejectsTapDiagonalSlowAndOutAndBackMotion() {
        let origin = Date(timeIntervalSince1970: 100)
        func frame(_ time: TimeInterval, x: Int, y: Int, count: Int = 1) -> RemoteTextTouchFrame {
            .init(sender: 8, time: origin.addingTimeInterval(time), generation: .glassTouchSurface,
                  count: count, x: x, y: y)
        }
        func result(_ frames: [RemoteTextTouchFrame]) -> RemoteTouchSwipeDirection? {
            var gate = RemoteTouchSwipeGate()
            var result: RemoteTouchSwipeDirection?
            for frame in frames { result = gate.observe(frame) ?? result }
            return result
        }
        XCTAssertNil(result([frame(0, x: 0, y: 0), frame(0.1, x: 60, y: 5), frame(0.15, x: 0, y: 0, count: 0)]))
        XCTAssertNil(result([frame(0, x: 0, y: 0), frame(0.2, x: 180, y: 160), frame(0.25, x: 0, y: 0, count: 0)]))
        XCTAssertNil(result([frame(0, x: 0, y: 0), frame(0.7, x: 200, y: 0), frame(0.72, x: 0, y: 0, count: 0)]))
        XCTAssertNil(result([frame(0, x: 0, y: 0), frame(0.15, x: 260, y: 0), frame(0.3, x: -10, y: 0), frame(0.34, x: 0, y: 0, count: 0)]))
    }

    func testPacketLoggerDecodesGlassTouchButNotSameHandleVoice() throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let now = try XCTUnwrap(f.date(from: "2026-09-20 15:45:27.400"))
        let report = "01 00 32 00 00 09 F5 01 C8 04 03 28 00"
        let line = "Sep 20 15:45:27.330  Marcus Siri Remot  0x004E  RECV  4E 20 14 00 10 00 04 00 1B 23 00 \(report)"
        var parser = PacketLoggerButtonParser()
        let frame = try XCTUnwrap(parser.touch(line: line, allowedLabels: ["Marcus Siri Remot"], now: now))
        XCTAssertEqual(frame.generation, .glassTouchSurface)
        XCTAssertEqual(frame.count, 1)
        XCTAssertEqual(frame.x, 270)
        XCTAssertNil(parser.touch(line: line.replacingOccurrences(of: "01 00 32", with: "01 00 FA"),
                                  allowedLabels: ["Marcus Siri Remot"], now: now))
        XCTAssertTrue(parser.events(line: line, allowedLabels: ["Marcus Siri Remot"], now: now).isEmpty)
    }
}
