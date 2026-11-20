import AppKit
import ApplicationServices

/// A read-only description of this hold's draft. AX handles are only read on the geometry queue.
struct DictationDraftSnapshot: @unchecked Sendable {
    let pid: pid_t
    let element: AXUIElement
    let anchor: Int
    let text: String
}

enum DictationDraftGeometry {
    /// Never underline an earlier sentence or another occurrence of the same words. A read
    /// can lag live typing, so a verified prefix of the growing draft remains drawable.
    static func range(value: String, selection: CFRange, anchor: Int, draft: String) -> NSRange? {
        let length = draft.utf16.count
        let stops = CaretNavigation.boundaries(value)
        guard !draft.isEmpty, anchor >= 0, selection.length == 0, selection.location >= length,
              stops.contains(selection.location) else { return nil }
        func matches(_ start: Int) -> NSRange? {
            guard start >= anchor, start <= selection.location - length,
                  stops.contains(start), stops.contains(start + length) else { return nil }
            let range = NSRange(location: start, length: length)
            return (value as NSString).substring(with: range) == draft ? range : nil
        }
        // Prefer the original range. Chromium sometimes counts earlier paragraph breaks
        // differently; only re-anchor when this exact draft is immediately before the caret.
        return matches(anchor) ?? matches(selection.location - length)
    }

    static func strokes(_ rectangles: [CGRect], editor: CGRect) -> [CGRect] {
        rectangles.compactMap { rect in
            guard rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
                  rect.width > 0, rect.height > 0 else { return nil }
            // AX uses top-left screen coordinates. Draw just below the glyphs, inside the field.
            let line = CGRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1)
            let clipped = line.intersection(editor)
            return clipped.isNull || clipped.isEmpty ? nil : clipped
        }
    }

    /// Chromium may expose text frames but no per-range geometry. Match the complete leaf
    /// text to the editor before laying out only the draft's intersections. Visual feedback
    /// only: these estimates are never used to select, replace or format the user's text.
    static func estimatedRects(value: String, range: NSRange,
                               leaves: [CaretInsertionPoint.TextLeaf]) -> [CGRect]? {
        let source = value as NSString
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= source.length else { return nil }
        var offset = 0
        var matched: [(text: String, range: NSRange, frame: CGRect)] = []
        for leaf in leaves {
            var text = leaf.text
            while text.last?.isNewline == true { text.removeLast() }
            guard !text.isEmpty else { continue }
            let found = source.range(of: text, range: NSRange(location: offset, length: source.length - offset))
            guard found.location != NSNotFound,
                  source.substring(with: NSRange(location: offset, length: found.location - offset)).allSatisfy(\.isNewline),
                  leaf.frame.minX.isFinite, leaf.frame.minY.isFinite,
                  leaf.frame.width.isFinite, leaf.frame.height.isFinite,
                  leaf.frame.width > 0, leaf.frame.height >= 8 else { return nil }
            matched.append((text, found, leaf.frame))
            offset = NSMaxRange(found)
        }
        guard source.substring(from: offset).allSatisfy(\.isNewline) else { return nil }
        var result: [CGRect] = []
        for leaf in matched {
            let intersection = NSIntersectionRange(range, leaf.range)
            guard intersection.length > 0 else { continue }
            let singleLine = leaf.frame.height <= 30 && !leaf.text.contains(where: \.isNewline)
            let size = singleLine ? CaretInsertionPoint.fontSize(paragraph: leaf.text, renderedWidth: leaf.frame.width) : nil
            let storage = NSTextStorage(string: leaf.text, attributes: [.font: NSFont.systemFont(ofSize: size ?? 16)])
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: singleLine ? 100_000 : leaf.frame.width + 1,
                                                          height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container); storage.addLayoutManager(layout)
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            guard used.width > 0, used.height > 0 else { return nil }
            let local = NSRange(location: intersection.location - leaf.range.location, length: intersection.length)
            let glyphs = layout.glyphRange(forCharacterRange: local, actualCharacterRange: nil)
            let xScale = singleLine ? leaf.frame.width / used.width : 1
            let yScale = leaf.frame.height / used.height
            layout.enumerateEnclosingRects(forGlyphRange: glyphs,
                                           withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in
                result.append(CGRect(x: leaf.frame.minX + rect.minX * xScale,
                                     y: leaf.frame.minY + rect.minY * yScale,
                                     width: min(rect.width * xScale, leaf.frame.width - rect.minX * xScale),
                                     height: rect.height * yScale))
            }
        }
        return result.isEmpty ? nil : result
    }
}

/// Separate from document formatting: plain-text fields and rich-text editors get the same
/// pending-draft affordance, and final text never inherits an underline attribute.
@MainActor
final class DictationDraftUnderline {
    final class Canvas: NSView {
        var strokes: [CGRect] = []
        override var isOpaque: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.clear.setFill(); dirtyRect.fill(using: .copy)
            NSColor.systemOrange.withAlphaComponent(0.85).setFill()
            for stroke in strokes { stroke.fill() }
        }
    }

    typealias Read = @MainActor (DictationDraftSnapshot, @escaping @MainActor @Sendable ([CGRect]?) -> Void) -> Void
    private let read: Read
    private let isFrontmost: (pid_t) -> Bool
    private let present: Bool
    private(set) var panel: CaretOverlay.Panel?
    private var canvas: Canvas?
    private var draft: DictationDraftSnapshot?
    private var timer: Timer?
    private var inFlight = false
    private var generation = 0

    init(read: Read? = nil, present: Bool = true, isFrontmost: @escaping (pid_t) -> Bool = {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == $0
    }) {
        let reader = DictationDraftGeometryReader()
        self.read = read ?? { draft, completion in reader.read(draft, completion: completion) }
        self.isFrontmost = isFrontmost
        self.present = present
    }

    func update(_ draft: DictationDraftSnapshot) {
        self.draft = draft
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    func hide() {
        generation += 1
        draft = nil
        timer?.invalidate(); timer = nil
        panel?.close()
        panel = nil; canvas = nil
    }

    private func refresh() {
        guard let draft else { return }
        guard isFrontmost(draft.pid) else {
            panel?.orderOut(nil)
            return
        }
        guard !inFlight else { return }
        inFlight = true
        let token = generation
        read(draft) { [weak self] strokes in
            guard let self else { return }
            self.inFlight = false
            guard self.generation == token, self.draft != nil else { return }
            guard self.isFrontmost(draft.pid),
                  let strokes, !strokes.isEmpty else { self.panel?.orderOut(nil); return }
            self.show(strokes)
        }
    }

    private func show(_ strokes: [CGRect]) {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let rects = strokes.map { CGRect(x: $0.minX, y: top - $0.maxY, width: $0.width, height: $0.height) }
        let frame = rects.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -1, dy: -1)
        if panel == nil {
            let window = CaretOverlay.Panel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                            backing: .buffered, defer: false)
            window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = false
            window.ignoresMouseEvents = true; window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            let view = Canvas()
            view.setAccessibilityElement(false)
            window.contentView = view
            panel = window; canvas = view
        }
        guard let panel, let canvas else { return }
        panel.setFrame(frame, display: false)
        canvas.frame = CGRect(origin: .zero, size: panel.frame.size)
        canvas.strokes = rects.map { $0.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY) }
        canvas.needsDisplay = true
        if present { panel.orderFrontRegardless() }
    }
}
