import XCTest
import UIKit
import CoreText
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
        let window = PortraitGapWindow(windowScene: scene)
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
    private func capture(_ keyboard: KeyboardViewController, host: UIView, name: String, style: UIUserInterfaceStyle = .dark) throws {
        // Full granted extension frame, including header and all edges. Neutral
        // backdrop is a stand-in, NOT evidence of the actual system material.
        host.backgroundColor = UIColor(white: style == .dark ? 0.16 : 0.83, alpha: 1)
        host.overrideUserInterfaceStyle = style
        host.layoutIfNeeded()
        for view in descendants(host) { view.layoutIfNeeded() }
        let format = UIGraphicsImageRendererFormat()
        format.scale = name.hasPrefix("portrait-gap-") ? max(1, host.traitCollection.displayScale) : 2
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


    func testInnerPortraitGapPolicyAndLowerHeightBoundary() {
        for width: CGFloat in [655, 669] {
            let metrics = KeyboardMetrics(width: width)
            for scale: CGFloat in [1, 2, 3] {
                let minimumKey = ceil((metrics.letterFont.lineHeight + 4) * scale) / scale
                let minimumHeight = 47 + 4 * minimumKey + 27
                for height in stride(from: minimumHeight, through: metrics.contentHeight, by: 1 / scale) {
                    let fitted = KeyboardMetrics.VerticalLayout(metrics: metrics, availableHeight: height, displayScale: scale)
                    XCTAssertFalse(fitted.isBelowInnerPortraitSpacingMinimum)
                    XCTAssertGreaterThanOrEqual(fitted.rowGap, 9)
                    XCTAssertLessThanOrEqual(fitted.rowGap, 14)
                    XCTAssertGreaterThanOrEqual(floor((fitted.keyHeight + 0.0001) * scale) / scale, minimumKey)
                    XCTAssertEqual(fitted.candidateHeight, 47)
                    XCTAssertEqual(fitted.rowsHeight + fitted.candidateHeight + fitted.bottomInset, height, accuracy: 0.001)
                }
                let short = KeyboardMetrics.VerticalLayout(metrics: metrics, availableHeight: minimumHeight - 1 / scale, displayScale: scale)
                XCTAssertTrue(short.isBelowInnerPortraitSpacingMinimum, "Explicitly outside the approved policy; no new fallback")
                let grant = KeyboardMetrics.VerticalLayout(metrics: metrics, availableHeight: 255, displayScale: scale)
                XCTAssertEqual(grant.rowGap, 14)
                XCTAssertEqual(grant.keyHeight, 41.5)
                XCTAssertEqual(grant.rowsHeight, 208)
                let natural = KeyboardMetrics.VerticalLayout(metrics: metrics, availableHeight: metrics.contentHeight, displayScale: scale)
                XCTAssertEqual(natural.keyHeight, metrics.keyHeight, accuracy: 0.0001)
                XCTAssertEqual(natural.rowGap, metrics.rowGap)
                XCTAssertEqual(natural.bottomInset, metrics.bottomInset)
                print("Portrait policy width=\(width) scale=\(scale) minimumKey=\(minimumKey) minimumRoot=\(minimumHeight)")
            }
        }
        // Pin the unchanged fitter in every other arrangement, including mini.
        for (width, landscape): (CGFloat, Bool) in [(375, false), (402, false), (440, false), (452, false), (466, false), (655, true), (801, true)] {
            for mini in [false, true] {
                let metrics = KeyboardMetrics(width: width, landscape: landscape, mini: mini)
                for height: CGFloat in [216, 240, 255, metrics.contentHeight] {
                    var deficit = max(0, metrics.contentHeight - max(0, min(metrics.contentHeight, height)))
                    let bottom = min(metrics.bottomInset, deficit); deficit -= bottom
                    let top = min(metrics.topInset, deficit); deficit -= top
                    let gaps: CGFloat = mini ? 0 : 3
                    let reduction = gaps > 0 ? min(max(0, metrics.rowGap - 2), deficit / gaps) : 0
                    deficit -= reduction * gaps
                    let fitted = KeyboardMetrics.VerticalLayout(metrics: metrics, availableHeight: height)
                    XCTAssertFalse(fitted.isBelowInnerPortraitSpacingMinimum)
                    XCTAssertEqual(fitted.bottomInset, metrics.bottomInset - bottom)
                    XCTAssertEqual(fitted.topInset, metrics.topInset - top)
                    XCTAssertEqual(fitted.rowGap, metrics.rowGap - reduction)
                    XCTAssertEqual(fitted.keyHeight, max(0, metrics.keyHeight - deficit / (mini ? 1 : 4)))
                }
            }
        }
    }

    func testInnerPortraitHeightOnlyRestorationSafeInsetsAndMini() async throws {
        try await withHost { keyboard, _, host in
            let window = try XCTUnwrap(host.window as? PortraitGapWindow)
            for width: CGFloat in [655, 669] {
                let natural = KeyboardMetrics(width: width)
                var reference: [CGRect] = []
                for safe: CGFloat in [0, 18, 34] {
                    window.testBottomInset = safe
                    keyboard.additionalSafeAreaInsets.bottom = safe
                    window.setNeedsLayout(); window.layoutIfNeeded()
                    layout(keyboard, host: host, width: width, height: 255, landscape: false)
                    XCTAssertEqual(window.safeAreaInsets.bottom, safe)
                    XCTAssertEqual(keyboard.view.safeAreaInsets.bottom, safe)
                    let actual = keys(keyboard).map { frame($0, keyboard) }
                    if reference.isEmpty { reference = actual } else { XCTAssertEqual(actual, reference) }
                    XCTAssertEqual(keyboard.view.bounds.height, 255)
                    XCTAssertEqual(keyboard.preferredContentSize.height, natural.contentHeight)
                    let rows = descendants(keyboard.view).compactMap { $0 as? UIStackView }
                        .first { $0.axis == .vertical && $0.arrangedSubviews.count == 4 }!
                    let pixel = 1 / max(1, keyboard.view.traitCollection.displayScale)
                    let rects = rows.arrangedSubviews.map { frame($0, keyboard) }
                    let heights = rects.map(\.height)
                    let gaps = zip(rects, rects.dropFirst()).map { $1.minY - $0.maxY }
                    XCTAssertLessThanOrEqual(heights.max()! - heights.min()!, pixel + 0.001)
                    XCTAssertLessThanOrEqual(gaps.max()! - gaps.min()!, pixel + 0.001)
                    for rect in rects { XCTAssertEqual(rect.height, 41.5, accuracy: pixel) }
                    for gap in gaps { XCTAssertEqual(gap, 14, accuracy: pixel) }
                    XCTAssertEqual(rects.first!.minY, 47)
                    XCTAssertEqual(rects.last!.maxY, 255, accuracy: pixel)
                    print("Portrait safe width=\(width) requestedSafe=\(safe) rootSafe=\(keyboard.view.safeAreaInsets.bottom) windowSafe=\(window.safeAreaInsets.bottom) rows=\(rects)")
                    // Height-only change must restore all historical values and
                    // leave every horizontal dimension alone.
                    layout(keyboard, host: host, width: width, height: natural.contentHeight, landscape: false)
                    assertHistoricalSpacing(keyboard)
                    for (a, b) in zip(keys(keyboard).map({ frame($0, keyboard) }), actual) {
                        XCTAssertEqual(a.minX, b.minX); XCTAssertEqual(a.width, b.width)
                    }
                    keyboard.setMiniMode(true, animated: false)
                    let mini = KeyboardMetrics(width: width, mini: true)
                    layout(keyboard, host: host, width: width, height: mini.contentHeight, landscape: false)
                    XCTAssertEqual(keys(keyboard).count, 4)
                    XCTAssertEqual(keyboard.preferredContentSize.height, mini.contentHeight)
                    keyboard.setMiniMode(false, animated: false)
                    layout(keyboard, host: host, width: width, height: 255, landscape: false)
                    XCTAssertEqual(keys(keyboard).map { frame($0, keyboard) }, reference)
                }
            }
        }
    }

    /// Identical offscreen fixture on baseline and repair. Not system glass or
    /// remote-host occlusion evidence; never changes the requested frame budget.
    func testInnerPortraitGapEvidence() async throws {
        try await withHost { keyboard, proxy, host in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            keyboard.snippetStore = SnippetStore(directory: directory)
            let snippet = try keyboard.snippetStore.save(abbreviation: "reply", content: "Synthetic fixture — 谢谢！")
            layout(keyboard, host: host, width: 655, height: 255, landscape: false)
            print("Portrait evidence laid out")
            let original = keys(keyboard).map { frame($0, keyboard) }
            try portraitShots(keyboard, host: host, original: original, mode: "idle")
            try tap("k", keyboard)
            try await wait { self.descendants(keyboard.view).contains { $0.accessibilityIdentifier == "candidate.0" } }
            keyboard.view.layoutIfNeeded()
            try portraitShots(keyboard, host: host, original: original, mode: "candidates")
            let panel = try XCTUnwrap(descendants(keyboard.view).compactMap { $0 as? CandidatePanel }.first)
            panel.setExpanded(true); keyboard.view.layoutIfNeeded()
            let candidateList = try XCTUnwrap(descendants(panel).compactMap { $0 as? UICollectionView }.first)
            // Rime pagination arrives asynchronously after willDisplay. Capture
            // the populated browser, not the first strip's transient empty body.
            try await wait {
                keyboard.view.layoutIfNeeded(); panel.layoutIfNeeded(); candidateList.layoutIfNeeded()
                return candidateList.visibleCells.contains { $0.frame.minY >= panel.headerHeight }
            }
            try portraitShots(keyboard, host: host, original: original, mode: "expanded")
            let enter = try XCTUnwrap(keys(keyboard).first { $0.accessibilityIdentifier == "keyboard.key.return" })
            XCTAssertLessThanOrEqual(panel.frame.maxY, frame(enter, keyboard).minY)
            let covered = keys(keyboard).filter { frame($0, keyboard).minY < frame(enter, keyboard).minY }
            for key in covered {
                var ancestor = key.superview
                while ancestor != nil && ancestor?.alpha != 0 { ancestor = ancestor?.superview }
                XCTAssertNotNil(ancestor)
                XCTAssertEqual(ancestor?.accessibilityElementsHidden, true)
                let rect = frame(key, keyboard)
                XCTAssertFalse(keyboard.view.hitTest(CGPoint(x: rect.midX, y: rect.midY), with: nil) === key)
            }
            panel.setExpanded(false); keyboard.view.layoutIfNeeded()
            try tap("space", keyboard)
            try await wait { proxy.editor.markedTextRange == nil }
            keyboard.openSnippets()
            try await wait { keyboard.snippetStrip.records.first?.id == snippet.id }
            try await wait {
                keyboard.view.layoutIfNeeded(); keyboard.snippetStrip.layoutIfNeeded()
                keyboard.snippetStrip.collection.layoutIfNeeded()
                return !keyboard.snippetStrip.collection.visibleCells.isEmpty
            }
            try portraitShots(keyboard, host: host, original: original, mode: "manual-snippets")
            keyboard.closeSnippets()
        }
    }

    /// Production resolves this from the extension's main bundle. The XCTest
    /// host is the app, so load the exact built extension asset explicitly.
    private func loadExtensionArtwork(_ keyboard: KeyboardViewController) throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "appex" })
        let bundle = try XCTUnwrap(Bundle(url: url))
        let image = try XCTUnwrap(UIImage(named: "KeyboardSwitcher", in: bundle, compatibleWith: keyboard.view.traitCollection))
        for key in keys(keyboard).compactMap({ $0 as? KeyboardSwitcherButton }) {
            let icon = try XCTUnwrap(key.subviews.compactMap { $0 as? UIImageView }.first)
            if icon.image == nil { icon.image = image.withRenderingMode(.alwaysTemplate) }
        }
    }

    private func portraitShots(_ keyboard: KeyboardViewController, host: UIView, original: [CGRect], mode: String) throws {
        try loadExtensionArtwork(keyboard)
        let rows = descendants(keyboard.view).compactMap { $0 as? UIStackView }
            .first { $0.axis == .vertical && $0.arrangedSubviews.count == 4 }!
        print("Portrait evidence \(mode) root=\(keyboard.view.bounds) rows=\(rows.arrangedSubviews.map { frame($0, keyboard) })")
        for style: UIUserInterfaceStyle in [.light, .dark] {
            print("Portrait evidence capture \(mode) \(style.rawValue)")
            try capture(keyboard, host: host, name: "portrait-gap-655-255-\(mode)-\(style == .dark ? "dark" : "light")", style: style)
        }
        XCTAssertEqual(keys(keyboard).map { frame($0, keyboard) }, original)
        XCTAssertEqual(keyboard.view.bounds.height, 255)
    }

    /// Inspect every original legend, including transparent image padding. Raster
    /// alpha bounds are measured on an unclipped canvas, not a 42pt image box.
    private func assertOriginalInk(_ keyboard: KeyboardViewController) throws {
        try loadExtensionArtwork(keyboard)
        for key in keys(keyboard) {
            key.layoutIfNeeded()
            let id = key.accessibilityIdentifier ?? "key"
            if let control = key as? KeyControl, !control.label.isHidden,
               let text = control.label.text, !text.isEmpty {
                let label = control.label
                if control.value.count == 1 {
                    let metrics = KeyboardMetrics(width: keyboard.view.bounds.width)
                    XCTAssertEqual(label.font, metrics.letterFont, id)
                    XCTAssertGreaterThanOrEqual(key.bounds.height + 0.001, label.font.lineHeight + 4, id)
                    XCTAssertLessThanOrEqual((text as NSString).size(withAttributes: [.font: label.font!]).width,
                                             label.bounds.width + 0.5, "No width-driven font shrink: \(id)")
                }
                XCTAssertTrue(key.bounds.contains(label.frame), "Original label line box \(id): \(label.frame)")
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: label.font!]))
                let ink = CTLineGetImageBounds(line, nil)
                XCTAssertLessThanOrEqual(ink.height, key.bounds.height - 3, "Unscaled glyph ink: \(id)")
                print("Portrait text \(Int(keyboard.view.bounds.width)) \(id): font=\(label.font.pointSize) line=\(label.font.lineHeight) ink=\(ink)")
            }
            for imageView in descendants(key).compactMap({ $0 as? UIImageView }) where !imageView.isHidden {
                guard let image = imageView.image else { continue }
                let format = UIGraphicsImageRendererFormat(); format.scale = 3; format.opaque = false
                let canvas = CGSize(width: image.size.width + 8, height: image.size.height + 8)
                let raster = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
                    image.withTintColor(.black, renderingMode: .alwaysOriginal).draw(at: CGPoint(x: 4, y: 4))
                }
                let cg = try XCTUnwrap(raster.cgImage)
                var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
                let context = try XCTUnwrap(CGContext(data: &bytes, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                var minX = cg.width, minY = cg.height, maxX = -1, maxY = -1
                for y in 0..<cg.height { for x in 0..<cg.width where bytes[(y * cg.width + x) * 4 + 3] > 1 {
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                } }
                guard maxX >= minX else { continue }
                let ink = CGRect(x: CGFloat(minX) / 3 - 4, y: CGFloat(minY) / 3 - 4,
                                 width: CGFloat(maxX - minX + 1) / 3, height: CGFloat(maxY - minY + 1) / 3)
                let box = imageView.bounds
                let factor: CGFloat = imageView.contentMode == .scaleAspectFit
                    ? min(box.width / image.size.width, box.height / image.size.height) : 1
                let drawn = CGRect(x: (box.width - image.size.width * factor) / 2 + ink.minX * factor,
                                   y: (box.height - image.size.height * factor) / 2 + ink.minY * factor,
                                   width: ink.width * factor, height: ink.height * factor)
                let inKey = imageView.convert(drawn, to: key)
                XCTAssertTrue(key.bounds.contains(inKey), "Visible icon ink \(id): \(inKey), container \(imageView.frame)")
                print("Portrait ink \(Int(keyboard.view.bounds.width)) \(id): visible=\(inKey), container=\(imageView.frame)")
            }
        }
    }

    func testInnerPortraitOriginalLegendsAndHitTargetsAt255() async throws {
        try await withHost { keyboard, _, host in
            for width: CGFloat in [655, 669] {
                layout(keyboard, host: host, width: width, height: 255, landscape: false)
                for languageIndex in 0..<2 {
                    if languageIndex == 1 { try tap("language", keyboard) }
                    for page in 0..<3 {
                        if page == 1 { try tap("123", keyboard) }
                        if page == 2 { try tap("#+=", keyboard) }
                        layout(keyboard, host: host, width: width, height: 255, landscape: false)
                        assertContained(keyboard)
                        try assertOriginalInk(keyboard)
                        let all = keys(keyboard)
                        for (index, key) in all.enumerated() {
                            let rect = frame(key, keyboard)
                            for other in all.dropFirst(index + 1) {
                                XCTAssertFalse(rect.intersects(frame(other, keyboard)), "No overlapping keycaps")
                            }
                            let point = CGPoint(x: rect.midX, y: rect.midY)
                            let hit = keyboard.view.hitTest(point, with: nil)
                            let hitsKey = hit === key || hit?.isDescendant(of: key) == true
                            if (key as? UIControl)?.isEnabled != false {
                                XCTAssertTrue(hitsKey, "Enabled hit target: \(key.accessibilityIdentifier ?? "key")")
                            } else {
                                // The symbols page deliberately contains an empty,
                                // disabled spacer, not an actionable touch target.
                                XCTAssertFalse(hitsKey, "Disabled spacer must not own touches")
                            }
                            // One owner, even though the touch surface allocates gaps.
                            let owners = all.filter { $0.point(inside: keyboard.view.convert(point, to: $0), with: nil) }
                            XCTAssertEqual(owners.count, 1)
                        }
                    }
                    try tap("ABC", keyboard); layout(keyboard, host: host, width: width, height: 255, landscape: false)
                    try tap("shift", keyboard); keyboard.view.layoutIfNeeded()
                    try assertOriginalInk(keyboard)
                    try tap("shift", keyboard)
                }
                try tap("language", keyboard)
                print("Portrait original font width=\(width), lineHeight+4=\(KeyboardMetrics(width: width).letterFont.lineHeight + 4)")
            }
        }
    }

}

@MainActor private final class PortraitGapWindow: UIWindow {
    var testBottomInset: CGFloat = 0
    override var safeAreaInsets: UIEdgeInsets { UIEdgeInsets(top: 0, left: 0, bottom: testBottomInset, right: 0) }
}
