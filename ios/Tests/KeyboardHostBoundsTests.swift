import XCTest
import UIKit
@testable import vvhisper

/// A controller host, not a remote/system keyboard. Its required frame deliberately
/// wins over the extension's 999-priority height request, as can happen on resize.
@MainActor final class KeyboardHostBoundsTests: XCTestCase {
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
    private func frame(_ view: UIView, _ keyboard: KeyboardViewController) -> CGRect { view.convert(view.bounds, to: keyboard.view) }
    private func keys(_ keyboard: KeyboardViewController) -> [UIView] {
        descendants(keyboard.view).filter { ($0 is KeyControl || $0 is KeyboardSwitcherButton) && !$0.isHidden }
    }
    private func layout(_ keyboard: KeyboardViewController, host: UIView, width: CGFloat, height: CGFloat, landscape: Bool) {
        keyboard.testingLandscape = landscape
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.setNeedsLayout(); host.layoutIfNeeded()
        keyboard.view.setNeedsLayout(); keyboard.view.layoutIfNeeded()
        keyboard.viewDidLayoutSubviews(); keyboard.view.layoutIfNeeded()
    }
    private func assertContained(_ keyboard: KeyboardViewController, file: StaticString = #filePath, line: UInt = #line) {
        let all = keys(keyboard)
        XCTAssertFalse(all.isEmpty, file: file, line: line)
        let rows = Set(all.map { (frame($0, keyboard).minY * 2).rounded() / 2 })
        XCTAssertEqual(rows.count, 4, "All four rows remain present", file: file, line: line)
        for key in all {
            let rect = frame(key, keyboard)
            XCTAssertTrue(keyboard.view.bounds.insetBy(dx: -0.5, dy: -0.5).contains(rect),
                          "\(key.accessibilityIdentifier ?? "key") \(rect) outside granted \(keyboard.view.bounds)", file: file, line: line)
            XCTAssertGreaterThan(rect.height, 30, file: file, line: line)
            if ["keyboard.key.space", "keyboard.key.return", "keyboard.key.123", "keyboard.key.language", "keyboard.key.globe"].contains(key.accessibilityIdentifier ?? "") {
                let hit = keyboard.view.hitTest(CGPoint(x: rect.midX, y: rect.midY), with: nil)
                XCTAssertTrue(hit === key || hit?.isDescendant(of: key) == true,
                              "Bottom control remains reachable: \(key.accessibilityIdentifier ?? "")", file: file, line: line)
            }
            if let key = key as? KeyControl, key.value.count == 1, key.value.first?.isLetter == true {
                let natural = KeyboardMetrics(width: keyboard.view.bounds.width, landscape: keyboard.testingLandscape == true)
                XCTAssertEqual(key.label.font.pointSize, natural.fontSize, "No smaller text workaround", file: file, line: line)
                XCTAssertGreaterThanOrEqual(rect.height, key.label.font.lineHeight, file: file, line: line)
            }
        }
    }
    private func assertHistoricalSpacing(_ keyboard: KeyboardViewController, file: StaticString = #filePath, line: UInt = #line) {
        let natural = KeyboardMetrics(width: keyboard.view.bounds.width, landscape: keyboard.testingLandscape == true)
        let rects = keys(keyboard).map { frame($0, keyboard) }.sorted { $0.minY < $1.minY }
        var rows: [CGRect] = []
        for rect in rects where rows.last.map({ abs($0.minY - rect.minY) > 0.5 }) ?? true { rows.append(rect) }
        XCTAssertEqual(rows.count, 4, file: file, line: line)
        for rect in rows { XCTAssertEqual(rect.height, natural.keyHeight, accuracy: 0.01, file: file, line: line) }
        for (upper, lower) in zip(rows, rows.dropFirst()) {
            XCTAssertEqual(lower.minY - upper.maxY, natural.rowGap, accuracy: 0.01,
                           "Restore the historical gap, not just four visible rows", file: file, line: line)
        }
    }
    private func withHost(constrainHeight: Bool = true, _ body: (KeyboardViewController, TextViewProxy, UIView) async throws -> Void) async throws {
        let oldMode = UserDefaults.standard.object(forKey: KeyboardLayoutMode.preferenceKey)
        let oldLanguage = UserDefaults.standard.object(forKey: KeyboardLanguage.preferenceKey)
        KeyboardLayoutMode.full.save(); KeyboardLanguage.chinese.save()
        await withCheckedContinuation { c in PinyinEngine.shared.perform(.clear) { _ in c.resume() } }
        let keyboard = KeyboardViewController(), proxy = TextViewProxy("", selection: NSRange(location: 0, length: 0))
        keyboard.testingDocumentProxy = proxy; keyboard.testingTablet = false; keyboard.testingLandscape = false
        keyboard.loadViewIfNeeded()
        let host = UIView(); host.clipsToBounds = true
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.addSubview(host); window.isHidden = false
        host.addSubview(keyboard.view)
        keyboard.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            keyboard.view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            keyboard.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            keyboard.view.topAnchor.constraint(equalTo: host.topAnchor)
        ])
        if constrainHeight { keyboard.view.bottomAnchor.constraint(equalTo: host.bottomAnchor).isActive = true }
        defer {
            keyboard.viewWillDisappear(false); keyboard.view.removeFromSuperview()
            window.isHidden = true; host.removeFromSuperview()
            UserDefaults.standard.set(oldMode, forKey: KeyboardLayoutMode.preferenceKey)
            UserDefaults.standard.set(oldLanguage, forKey: KeyboardLanguage.preferenceKey)
        }
        await withCheckedContinuation { c in PinyinEngine.shared.perform(.prepare) { _ in c.resume() } }
        try await body(keyboard, proxy, host)
    }
    func testGrantedHostHeightContainsAllFourRowsAfterUnfoldAndRotate() async throws {
        try await withHost { keyboard, _, host in
            // 655/802 are historical extension-width fixtures; 669/951 are inner
            // display points from the Duo reference (2007x2853 at 3x). 937 allows
            // the 14pt host-owned side margins observed on the outer display.
            for (width, landscape): (CGFloat, Bool) in [(466, false), (655, false), (669, false), (802, true), (937, true), (951, true), (669, false), (452, false)] {
                let natural = KeyboardMetrics(width: width, landscape: landscape).contentHeight
                for height in [natural, 216, 240, natural] {
                    layout(keyboard, host: host, width: width, height: height, landscape: landscape)
                    assertContained(keyboard)
                    if height == natural { assertHistoricalSpacing(keyboard) }
                    XCTAssertEqual(keyboard.preferredContentSize.height, natural, accuracy: 0.01,
                                   "A short grant must not ratchet down the requested height")
                    XCTAssertEqual(keyboard.inputView?.allowsSelfSizing, true)
                    XCTAssertEqual(keyboard.view.bounds.height, height, accuracy: 0.01)
                }
            }
        }
    }
    func testRegularPhonesAndOuterDisplayKeepFourRowsAtGrantedHeights() async throws {
        try await withHost { keyboard, _, host in
            for width: CGFloat in [375, 402, 440, 466] {
                for landscape in [false, true] {
                    for height in [KeyboardMetrics(width: width, landscape: landscape).contentHeight, 216] {
                        layout(keyboard, host: host, width: width, height: height, landscape: landscape)
                        assertContained(keyboard)
                    }
                }
            }
        }
    }
    func testSelfSizingMeasurementKeepsNaturalRequestUnderRequiredHostConstraints() async throws {
        try await withHost { keyboard, _, host in
            let input = try XCTUnwrap(keyboard.inputView as? KeyboardInputView)
            XCTAssertTrue(input === keyboard.view)
            for width: CGFloat in [375, 402, 440, 466, 669, 951, 669, 466] {
                let landscape = width == 951
                let natural = KeyboardMetrics(width: width, landscape: landscape).contentHeight
                for height in [natural, 216, 240, natural] {
                    layout(keyboard, host: host, width: width, height: height, landscape: landscape)
                    assertContained(keyboard)
                    if height == natural { assertHistoricalSpacing(keyboard) }
                    XCTAssertEqual(input.intrinsicContentSize.width, UIView.noIntrinsicMetric)
                    XCTAssertEqual(input.intrinsicContentSize.height, natural, accuracy: 0.01)
                    let hostHeight = input.heightAnchor.constraint(equalToConstant: height)
                    hostHeight.identifier = "test.host-granted-input-height"
                    hostHeight.isActive = true
                    for target in [UIView.layoutFittingCompressedSize, CGSize(width: width, height: 216), CGSize(width: width, height: natural)] {
                        XCTAssertEqual(input.systemLayoutSizeFitting(target).height, natural, accuracy: 0.01,
                                       "Self-sizing must not measure the current short host grant as the next request")
                    }
                    hostHeight.isActive = false
                    XCTAssertEqual(input.bounds.height, height, accuracy: 0.01, "Measurement must not resize the granted frame")
                }
                keyboard.setMiniMode(true, animated: false)
                let mini = KeyboardMetrics(width: width, landscape: landscape, mini: true).contentHeight
                XCTAssertEqual(input.systemLayoutSizeFitting(.zero).height, mini, accuracy: 0.01)
                XCTAssertEqual(input.intrinsicContentSize.height, mini, accuracy: 0.01)
                keyboard.setMiniMode(false, animated: false)
                XCTAssertEqual(input.systemLayoutSizeFitting(.zero).height, natural, accuracy: 0.01)
            }
        }
    }

    func testUnconstrainedHeightUsesHistoricalMetricsAfterResize() async throws {
        try await withHost(constrainHeight: false) { keyboard, _, host in
            for width: CGFloat in [375, 402, 440, 466, 669, 951, 669, 466] {
                let landscape = width == 951
                let natural = KeyboardMetrics(width: width, landscape: landscape).contentHeight
                layout(keyboard, host: host, width: width, height: natural, landscape: landscape)
                // A width change updates the request during the controller's
                // layout pass. Give its parent the next constraint-layout turn.
                host.setNeedsLayout(); host.layoutIfNeeded()
                keyboard.view.setNeedsLayout(); keyboard.view.layoutIfNeeded()
                XCTAssertEqual(keyboard.view.bounds.height, natural, accuracy: 0.01)
                assertContained(keyboard); assertHistoricalSpacing(keyboard)
            }
        }
    }

    func testInputViewRequestSurvivesWindowReattachment() {
        let input = KeyboardInputView(frame: CGRect(x: 0, y: 0, width: 669, height: 216), inputViewStyle: .keyboard)
        let natural = KeyboardMetrics(width: 669).contentHeight
        input.requestHeight(natural)
        let first = UIWindow(frame: CGRect(x: 0, y: 0, width: 669, height: 216))
        let second = UIWindow(frame: first.frame)
        for window in [first, second] {
            input.removeFromSuperview(); window.addSubview(input)
            XCTAssertEqual(input.intrinsicContentSize.height, natural, accuracy: 0.01)
            XCTAssertEqual(input.systemLayoutSizeFitting(.zero).height, natural, accuracy: 0.01)
        }
        input.removeFromSuperview()
    }

    /// Synthetic full-frame evidence only: the backing fill is not system glass.
    /// Run unchanged on the baseline and the repair to distinguish negotiation
    /// from geometry at identical, explicitly granted heights.
    func testFullFrameSizingEvidence() async throws {
        try await withHost { keyboard, proxy, host in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            keyboard.snippetStore = SnippetStore(directory: directory)
            let snippet = try keyboard.snippetStore.save(abbreviation: "reply", content: "Synthetic fixture — 谢谢！")
            var measurements: [[String: Any]] = []
            for width: CGFloat in [375, 402, 440, 466, 669, 951] {
                let landscape = width == 951
                let natural = KeyboardMetrics(width: width, landscape: landscape).contentHeight
                for (pose, height) in [("natural", natural), ("constrained", CGFloat(216))] {
                    layout(keyboard, host: host, width: width, height: height, landscape: landscape)
                    assertContained(keyboard)
                    let measured = keyboard.view.systemLayoutSizeFitting(CGSize(width: width, height: 216))
                    let compressed = keyboard.view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
                    // Model a host-owned height constraint installed directly on
                    // the input view, not just the enclosing controller edges.
                    let hostHeight = keyboard.view.heightAnchor.constraint(equalToConstant: height)
                    hostHeight.identifier = "test.host-granted-input-height"
                    hostHeight.isActive = true
                    let requiredFit = keyboard.view.systemLayoutSizeFitting(CGSize(width: width, height: 216))
                    hostHeight.isActive = false
                    let rowFrames = keys(keyboard).map { frame($0, keyboard) }.sorted { $0.minY < $1.minY }
                    var rowTops: [CGFloat] = [], rowHeights: [CGFloat] = []
                    for rect in rowFrames where rowTops.last.map({ abs($0 - rect.minY) > 0.5 }) ?? true {
                        rowTops.append(rect.minY); rowHeights.append(rect.height)
                    }
                    measurements.append(["width": width, "pose": pose, "grantedHeight": height,
                                         "requestedHeight": keyboard.preferredContentSize.height,
                                         "measuredHeight": measured.height, "compressedFitHeight": compressed.height,
                                         "requiredHeightConstraintFit": requiredFit.height,
                                         "intrinsicHeight": keyboard.view.intrinsicContentSize.height,
                                         "rowTops": rowTops, "rowHeights": rowHeights])
                    print("Sizing evidence width=\(width) pose=\(pose) granted=\(height) request=\(natural) measured=\(measured.height) compressed=\(compressed.height) requiredFit=\(requiredFit.height) rows=\(rowTops)")
                    let name = "sizing-\(Int(width))-\(pose)"
                    try capture(keyboard, host: host, name: "\(name)-idle")
                    try tap("k", keyboard)
                    try await wait { self.descendants(keyboard.view).contains { $0.accessibilityIdentifier == "candidate.0" } }
                    keyboard.view.layoutIfNeeded(); assertContained(keyboard)
                    try capture(keyboard, host: host, name: "\(name)-candidates")
                    try tap("space", keyboard)
                    try await wait { proxy.editor.markedTextRange == nil }
                    keyboard.openSnippets()
                    try await wait { keyboard.snippetStrip.records.first?.id == snippet.id }
                    try await wait {
                        keyboard.view.layoutIfNeeded(); keyboard.snippetStrip.layoutIfNeeded()
                        keyboard.snippetStrip.collection.layoutIfNeeded()
                        return !keyboard.snippetStrip.collection.visibleCells.isEmpty
                    }
                    assertContained(keyboard)
                    try capture(keyboard, host: host, name: "\(name)-snippets")
                    keyboard.closeSnippets()
                }
            }
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let url = root.appendingPathComponent(".airbuild/artifacts/phone-layout/sizing-measurements.json")
            try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        }
    }

    private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
    private func tap(_ value: String, _ keyboard: KeyboardViewController) throws {
        let key = try XCTUnwrap(keys(keyboard).compactMap { $0 as? KeyControl }.first { $0.value == value })
        XCTAssertTrue(key.accessibilityActivate())
    }
    private func capture(_ keyboard: KeyboardViewController, host: UIView, name: String) throws {
        // Full granted extension frame, including header and all edges. Neutral
        // backdrop is a stand-in, NOT evidence of the actual system material.
        host.backgroundColor = UIColor(white: 0.16, alpha: 1)
        host.overrideUserInterfaceStyle = .dark
        host.layoutIfNeeded()
        for view in descendants(host) { view.layoutIfNeeded() }
        let format = UIGraphicsImageRendererFormat(); format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: host.bounds, format: format).image { ctx in host.layer.render(in: ctx.cgContext) }
        let png = try XCTUnwrap(image.pngData())
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent(".airbuild/artifacts/phone-layout")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
    func testCandidateAndSnippetHeadersStayInsideFullExtensionFrame() async throws {
        try await withHost { keyboard, proxy, host in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            keyboard.snippetStore = SnippetStore(directory: directory)
            let snippet = try keyboard.snippetStore.save(abbreviation: "reply", content: "Synthetic fixture — 谢谢！")
            for (width, landscape): (CGFloat, Bool) in [(669, false), (951, true)] {
                layout(keyboard, host: host, width: width, height: 216, landscape: landscape)
                assertContained(keyboard)
                try capture(keyboard, host: host, name: "duo-host-\(Int(width))-216-idle")
                try tap("k", keyboard)
                try await wait { self.descendants(keyboard.view).contains { $0.accessibilityIdentifier == "candidate.0" } }
                keyboard.view.layoutIfNeeded(); assertContained(keyboard)
                try capture(keyboard, host: host, name: "duo-host-\(Int(width))-216-candidates")
                let panel = try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? CandidatePanel }.first)
                panel.setExpanded(true); keyboard.view.layoutIfNeeded()
                let bottom = try XCTUnwrap(keys(keyboard).first { $0.accessibilityIdentifier == "keyboard.key.return" })
                XCTAssertLessThanOrEqual(panel.frame.maxY, frame(bottom, keyboard).minY)
                try tap("space", keyboard)
                try await wait { proxy.editor.markedTextRange == nil }
                keyboard.openSnippets()
                try await wait { keyboard.snippetStrip.records.first?.id == snippet.id }
                keyboard.view.layoutIfNeeded(); assertContained(keyboard)
                try await wait {
                    keyboard.snippetStrip.layoutIfNeeded(); keyboard.snippetStrip.collection.layoutIfNeeded()
                    return !keyboard.snippetStrip.collection.visibleCells.isEmpty
                }
                XCTAssertEqual(keyboard.snippetStrip.collection.adjustedContentInset, .zero, "A window safe area must not be applied again inside the allocated keyboard header")
                XCTAssertFalse(keyboard.snippetStrip.collection.visibleCells.isEmpty,
                               "Snippet evidence at \(width): bounds=\(keyboard.snippetStrip.collection.bounds), items=\(keyboard.snippetStrip.collection.numberOfItems(inSection: 0)), content=\(keyboard.snippetStrip.collection.contentSize)")
                XCTAssertTrue(keyboard.view.bounds.contains(keyboard.snippetStrip.frame))
                try capture(keyboard, host: host, name: "duo-host-\(Int(width))-216-snippets")
                let before = proxy.editor.text ?? ""
                // A second pose is not a double-tap: respect the existing safety debounce.
                try await Task.sleep(for: .milliseconds(450))
                keyboard.selectSnippet(snippet)
                try await wait { proxy.editor.text == before + snippet.content }
                XCTAssertEqual(proxy.backspaces, 0)
                keyboard.closeSnippets()
            }
        }
    }
}
