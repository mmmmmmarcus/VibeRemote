import AppKit
import ApplicationServices
import SwiftUI

// Computer Use lives on the Dock: while its callout is open, or a command runs, VibeRemote
// keeps a Dock icon (the app is otherwise menu-bar only) and recolors it through NSDockTile,
// macOS's live-tile API — blue while composing, green while the agent works. The callout pops
// up from that icon the way a Dock stack or menu does.

/// Which Dock edge the icon sits on, and so which side of the callout carries the arrow.
enum DockEdge: Equatable, Sendable { case bottom, left, right }

/// Where the callout goes for a given icon frame. Pure geometry in AppKit screen coordinates
/// (bottom-left origin), so it is testable without a Dock.
struct DockCalloutPlacement: Equatable, Sendable {
    static let gap: CGFloat = 4
    static let margin: CGFloat = 8
    static let arrowLength: CGFloat = 10
    static let arrowWidth: CGFloat = 22
    static let cornerRadius: CGFloat = 20

    var origin: CGPoint
    /// nil when the Dock icon could not be located: the callout then floats arrowless above
    /// the bottom of the screen instead of pointing at a guessed position.
    var edge: DockEdge?
    /// The arrow's center, measured from the callout's left edge (bottom Dock) or bottom
    /// edge (side Docks).
    var arrowOffset: CGFloat

    static func edge(of icon: CGRect, in screen: CGRect) -> DockEdge {
        let distances: [(DockEdge, CGFloat)] = [
            (.bottom, icon.minY - screen.minY),
            (.left, icon.minX - screen.minX),
            (.right, screen.maxX - icon.maxX),
        ]
        return distances.min { $0.1 < $1.1 }!.0
    }

    /// `size` is the whole callout including the arrow; `visible` is the screen's visible frame.
    static func place(size: CGSize, icon: CGRect?, screen: CGRect, visible: CGRect) -> DockCalloutPlacement {
        guard let icon else {
            return DockCalloutPlacement(
                origin: CGPoint(x: visible.midX - size.width / 2, y: visible.minY + 3 * margin),
                edge: nil, arrowOffset: 0)
        }
        let inset = cornerRadius + arrowWidth / 2
        switch edge(of: icon, in: screen) {
        case .bottom:
            let x = clamp(icon.midX - size.width / 2, visible.minX + margin, visible.maxX - margin - size.width)
            return DockCalloutPlacement(
                origin: CGPoint(x: x, y: icon.maxY + gap), edge: .bottom,
                arrowOffset: clamp(icon.midX - x, inset, size.width - inset))
        case .left, .right:
            let side = edge(of: icon, in: screen)
            let y = clamp(icon.midY - size.height / 2, visible.minY + margin, visible.maxY - margin - size.height)
            let x = side == .left ? icon.maxX + gap : icon.minX - gap - size.width
            return DockCalloutPlacement(
                origin: CGPoint(x: x, y: y), edge: side,
                arrowOffset: clamp(icon.midY - y, inset, size.height - inset))
        }
    }

    /// When the range is empty (a one-line bar is shorter than two corner insets beside a side
    /// Dock) the middle is the only place an arrow still clears both rounded corners.
    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        high < low ? (low + high) / 2 : min(max(value, low), high)
    }
}

/// Finds VibeRemote's own Dock icon through the Dock's accessibility tree. There is no public
/// API for a Dock icon's position; the Dock exposes each item as an AXDockItem with a frame,
/// and VibeRemote already holds the Accessibility grant the remote's key events need.
enum DockIconLocator {
    /// The icon's frame in AppKit screen coordinates, or nil when the Dock, the grant or the
    /// item is unavailable (for example while the icon is still sliding in).
    @MainActor
    static func iconFrame() -> CGRect? {
        guard AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.1)
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? ProcessInfo.processInfo.processName
        for list in children(app) where string(list, kAXRoleAttribute) == kAXListRole {
            for item in children(list) {
                let url = (attribute(item, kAXURLAttribute) as? URL)?.standardizedFileURL
                guard url == bundleURL || (url == nil && string(item, kAXTitleAttribute) == name),
                      let frame = frame(of: item) else { continue }
                return appKitRect(fromAX: frame, primaryScreenHeight: NSScreen.screens.first?.frame.height ?? 0)
            }
        }
        return nil
    }

    /// AX frames use a top-left origin on the primary display; AppKit uses bottom-left.
    static func appKitRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &extent),
              extent.width > 0, extent.height > 0 else { return nil }
        return CGRect(origin: point, size: extent)
    }
}

/// The app icon recolored through NSDockTile. The Icon Composer icon is a light remote on a
/// dark tile; screening a colored squircle over it turns the dark tile into that color while
/// the light remote stays light, so it still reads as VibeRemote's own icon.
@MainActor
final class AgentDockTile {
    enum Style: Equatable { case normal, composing, working }

    private(set) var style: Style = .normal
    private var cache: [Style: NSImage] = [:]

    func apply(_ style: Style, badge: String? = nil) {
        let tile = NSApp.dockTile
        if style != self.style {
            self.style = style
            if let image = image(for: style) {
                let view = NSImageView(image: image)
                view.imageScaling = .scaleProportionallyUpOrDown
                tile.contentView = view
            } else {
                tile.contentView = nil
            }
        }
        tile.badgeLabel = badge
        tile.display()
    }

    private func image(for style: Style) -> NSImage? {
        let colors: [NSColor]
        switch style {
        case .normal: return nil
        case .composing: colors = [NSColor(srgbRed: 0.20, green: 0.56, blue: 1.0, alpha: 1), NSColor(srgbRed: 0.0, green: 0.36, blue: 0.92, alpha: 1)]
        case .working: colors = [NSColor(srgbRed: 0.26, green: 0.84, blue: 0.42, alpha: 1), NSColor(srgbRed: 0.08, green: 0.62, blue: 0.28, alpha: 1)]
        }
        if let cached = cache[style] { return cached }
        let icon = NSApp.applicationIconImage ?? NSImage()
        let size = NSSize(width: 256, height: 256)
        let rect = NSRect(origin: .zero, size: size)
        // The tint takes the icon's own silhouette, so the Dock's squircle shape is kept.
        let tint = NSImage(size: size, flipped: false) { bounds in
            NSGradient(colors: colors)?.draw(in: bounds, angle: -90)
            icon.draw(in: bounds, from: .zero, operation: .destinationIn, fraction: 1)
            return true
        }
        let image = NSImage(size: size, flipped: false) { _ in
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            tint.draw(in: rect, from: .zero, operation: .screen, fraction: 1)
            return true
        }
        cache[style] = image
        return image
    }
}

/// A rounded callout with one arrow pointing back at the Dock icon, used as the glass shape.
struct DockCalloutShape: Shape {
    var edge: DockEdge?
    var arrowOffset: CGFloat

    func path(in rect: CGRect) -> Path {
        let length = DockCalloutPlacement.arrowLength, half = DockCalloutPlacement.arrowWidth / 2
        var body = rect
        var arrow = Path()
        switch edge {
        case nil:
            break
        case .bottom:
            body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - length)
            arrow.move(to: CGPoint(x: arrowOffset - half, y: body.maxY - 1))
            arrow.addLine(to: CGPoint(x: arrowOffset, y: rect.maxY))
            arrow.addLine(to: CGPoint(x: arrowOffset + half, y: body.maxY - 1))
        case .left, .right:
            // SwiftUI's y grows downward; the placement measures from the bottom edge.
            let y = rect.maxY - arrowOffset
            if edge == .left {
                body = CGRect(x: rect.minX + length, y: rect.minY, width: rect.width - length, height: rect.height)
                arrow.move(to: CGPoint(x: body.minX + 1, y: y - half))
                arrow.addLine(to: CGPoint(x: rect.minX, y: y))
                arrow.addLine(to: CGPoint(x: body.minX + 1, y: y + half))
            } else {
                body = CGRect(x: rect.minX, y: rect.minY, width: rect.width - length, height: rect.height)
                arrow.move(to: CGPoint(x: body.maxX - 1, y: y - half))
                arrow.addLine(to: CGPoint(x: rect.maxX, y: y))
                arrow.addLine(to: CGPoint(x: body.maxX - 1, y: y + half))
            }
        }
        arrow.closeSubpath()
        let rounded = Path(roundedRect: body, cornerRadius: DockCalloutPlacement.cornerRadius, style: .continuous)
        return edge == nil ? rounded : rounded.union(arrow)
    }
}
