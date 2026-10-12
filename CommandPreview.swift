import AppKit

/// A single private, short-lived frame. Never sent to a model or retained after its task.
struct CommandPreviewFrame: Codable {
    let id: UUID
    let image: Data
    let app: String
    let cursorX: Double?
    let cursorY: Double?

    static func make(response: [String: Any], cursor: [String: Any]?) -> CommandPreviewFrame? {
        guard let result = response["result"] as? [String: Any], result["isError"] as? Bool != true,
              let state = result["structuredContent"] as? [String: Any], state["screenshot_frame_valid"] as? Bool == true,
              let blocks = result["content"] as? [[String: Any]],
              let encoded = blocks.first(where: { $0["type"] as? String == "image" })?["data"] as? String,
              encoded.count <= 8_000_000, let image = Data(base64Encoded: encoded),
              let bounds = state["window_bounds"] as? [String: Any],
              let x = (bounds["x"] as? NSNumber)?.doubleValue, let y = (bounds["y"] as? NSNumber)?.doubleValue,
              let w = (bounds["width"] as? NSNumber)?.doubleValue, let h = (bounds["height"] as? NSNumber)?.doubleValue,
              [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else { return nil }
        let position = cursor?["position"] as? [String: Any]
        let px = (position?["x"] as? NSNumber)?.doubleValue
        let py = (position?["y"] as? NSNumber)?.doubleValue
        let nx = px.map { ($0 - x) / w }, ny = py.map { ($0 - y) / h }
        let valid = nx.map { $0.isFinite && (0...1).contains($0) } == true && ny.map { $0.isFinite && (0...1).contains($0) } == true
        return .init(id: UUID(), image: image, app: state["app_name"] as? String ?? "Agent",
                     cursorX: valid ? nx : nil, cursorY: valid ? ny : nil)
    }
}

private final class CommandPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class CommandPreviewImage: NSView {
    override var isFlipped: Bool { true }
    var image: NSImage?
    var point: NSPoint?
    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2, width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        guard let point else { return }
        let p = NSPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        CommandPointerArtwork.draw(at: p, scale: 1)
    }
}

@MainActor
final class CommandPreviewController {
    private let panel = CommandPreviewPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 214),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private let picture = CommandPreviewImage(frame: NSRect(x: 8, y: 8, width: 264, height: 174))
    private let title = NSTextField(labelWithString: "Agent · 最近画面")
    init() {
        panel.title = "Agent 操作预览"; panel.identifier = .init("VibeRemote.Command.Preview")
        panel.isReleasedWhenClosed = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.level = .floating; panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: panel.frame.size))
        glass.style = .regular; glass.cornerRadius = 16
        let content = NSView(frame: glass.bounds); glass.contentView = content
        title.frame = NSRect(x: 12, y: 186, width: 256, height: 18)
        title.font = .systemFont(ofSize: 11, weight: .medium); title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        picture.wantsLayer = true; picture.layer?.cornerRadius = 10; picture.layer?.masksToBounds = true
        content.addSubview(picture); content.addSubview(title); panel.contentView = glass
    }
    func update(_ frame: CommandPreviewFrame?, on screen: NSScreen?) {
        guard let frame, let image = NSImage(data: frame.image) else { hide(); return }
        picture.image = image
        picture.point = frame.cursorX.flatMap { x in frame.cursorY.map { NSPoint(x: x, y: $0) } }
        picture.needsDisplay = true
        title.stringValue = "\(frame.app) · Agent 最近画面"
        panel.setAccessibilityLabel("\(frame.app) Agent 操作预览，不接收输入")
        let visible = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let x = visible.maxX - panel.frame.width - 16
        let y = visible.maxY - panel.frame.height - 16
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless() // Nonactivating, never key/main, mouse events pass through.
    }
    func hide() { panel.orderOut(nil); picture.image = nil; picture.point = nil }
}

/// One visual identity from the command's speaking pointer to the preview's action pointer.
enum CommandPointerArtwork {
    static func draw(at origin: NSPoint, scale: CGFloat) {
        let path = NSBezierPath()
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: origin.x + x * scale, y: origin.y + y * scale)
        }
        // Compact, rounded Agent pointer: no desktop-arrow stem.
        path.move(to: point(1.5, 0.5))
        path.curve(to: point(0.5, 2.5), controlPoint1: point(0, -0.2), controlPoint2: point(0, 0.6))
        path.line(to: point(5.7, 24))
        path.curve(to: point(8.6, 24.6), controlPoint1: point(6.2, 26), controlPoint2: point(7.6, 26.2))
        path.line(to: point(13.3, 17))
        path.curve(to: point(15.2, 15.5), controlPoint1: point(13.8, 16.2), controlPoint2: point(14.3, 15.8))
        path.line(to: point(23.7, 12.7))
        path.curve(to: point(24, 9.8), controlPoint1: point(25.5, 12.1), controlPoint2: point(25.8, 10.7))
        path.line(to: point(1.5, 0.5)); path.close()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 5; shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor.black.setFill(); path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke(); path.lineWidth = 1.3; path.lineJoinStyle = .round; path.stroke()
    }
}
