import XCTest
import AppKit
import RemoteAudioProtocol
@testable import VibeRemote

final class CaretNavigationTests: XCTestCase {
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
    func testShakeEntryLeavesOnlyGlassMechanicalClickAsEnter() {
        XCTAssertEqual(RemoteButtonMapping.action(button: "select", generation: .glassTouchSurface,
                                                  siriAction: .rightOpt), .enterKey)
        XCTAssertEqual(RemoteButtonMapping.action(button: "select", generation: .aluminumClickpad,
                                                  siriAction: .rightOpt), .none)
        XCTAssertFalse(ButtonAction.positionCaret.isAssignableToSiriButton)
        XCTAssertNil(AdvancedMenuInputState.action(button: "playPause", generation: .aluminumClickpad))
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
    func testDragPreviewMovesBetweenCharactersAndRowsBeforeRelease() {
        let editor = CGRect(x: 100, y: 100, width: 200, height: 100)
        let aim = CGPoint(x: 115.6, y: 126.3)
        let free = CaretNavigation.preview(at: aim, height: 16, editor: editor)
        XCTAssertEqual(free.minX, aim.x)
        XCTAssertEqual(free.midY, aim.y)
        let stops = [0: CGRect(x: 110, y: 100, width: 2, height: 16),
                     1: CGRect(x: 120, y: 124, width: 2, height: 16)]
        XCTAssertFalse(stops.values.contains(free), "Contact preview must not jump between character stops")
        XCTAssertEqual(CaretNavigation.nearest(to: aim, positions: stops, current: 0), 1)
        let edge = CaretNavigation.preview(at: CGPoint(x: 90, y: 205), height: 16, editor: editor)
        XCTAssertEqual(edge.minX, editor.minX)
        XCTAssertEqual(edge.maxY, editor.maxY)
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

    func testOneFastOutAndBackActivatesBothRemoteGenerations() {
        let origin = Date(timeIntervalSince1970: 100)
        func frame(_ time: TimeInterval, x: Int = 0, y: Int = 0, count: Int = 1,
                   generation: RemoteGeneration) -> RemoteTextTouchFrame {
            .init(sender: 8, time: origin.addingTimeInterval(time), generation: generation,
                  count: count, x: x, y: y)
        }
        for generation in [RemoteGeneration.glassTouchSurface, .aluminumClickpad] {
            var gate = RemoteCaretShakeGate(strokeDistance: 240)
            XCTAssertFalse(gate.observe(frame(0.00, x: 0, generation: generation)))
            XCTAssertFalse(gate.observe(frame(0.12, x: 250, generation: generation)), "First stroke establishes direction")
            XCTAssertTrue(gate.observe(frame(0.27, x: -10, generation: generation)), "One return stroke enters caret mode")
            XCTAssertEqual(gate.latest?.generation, generation)
        }
    }

    func testShakeRejectsOrdinaryDragSlowMotionAndLift() {
        let origin = Date(timeIntervalSince1970: 100)
        func frame(_ time: TimeInterval, x: Int, count: Int = 1) -> RemoteTextTouchFrame {
            .init(sender: 8, time: origin.addingTimeInterval(time), generation: .glassTouchSurface,
                  count: count, x: x, y: 0)
        }
        var drag = RemoteCaretShakeGate(strokeDistance: 240)
        XCTAssertFalse(drag.observe(frame(0, x: 0)))
        XCTAssertFalse(drag.observe(frame(0.1, x: 250)))
        XCTAssertFalse(drag.observe(frame(0.2, x: 520)))
        XCTAssertFalse(drag.observe(frame(0.3, x: 790)), "One-way dragging cannot enter")

        var slow = RemoteCaretShakeGate(strokeDistance: 240, maximumDuration: 0.9)
        XCTAssertFalse(slow.observe(frame(0, x: 0)))
        XCTAssertFalse(slow.observe(frame(0.1, x: 250)))
        XCTAssertFalse(slow.observe(frame(0.3, x: 300)))
        XCTAssertFalse(slow.observe(frame(0.5, x: 350)))
        XCTAssertFalse(slow.observe(frame(0.7, x: 400)))
        XCTAssertFalse(slow.observe(frame(0.9, x: 450)))
        XCTAssertFalse(slow.observe(frame(1.05, x: -10)), "Slow return exceeds the gesture window")

        var lifted = RemoteCaretShakeGate(strokeDistance: 240)
        XCTAssertFalse(lifted.observe(frame(0, x: 0)))
        XCTAssertFalse(lifted.observe(frame(0.1, x: 250)))
        XCTAssertFalse(lifted.observe(frame(0.2, x: 250, count: 0)))
        XCTAssertFalse(lifted.isTracking)
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
            XCTAssertFalse(gate.isTracking)
        }
        var aluminum = RemoteTouchSwipeGate()
        XCTAssertNil(aluminum.observe(frame(0, x: 0, y: 0, generation: .aluminumClickpad)))
        XCTAssertNil(aluminum.observe(frame(0.2, x: 300, y: 0, count: 0, generation: .aluminumClickpad)))
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
