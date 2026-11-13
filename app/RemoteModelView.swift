import AppKit
import SceneKit
import SwiftUI

/// Meshes tessellated from the supplied STEP assemblies. Conversion preserves every
/// solid and face color; only the display coordinate system and uniform scale change.
@MainActor
enum RemoteModelScene {
    // Keep the CAD comfortably inside the viewport at every supported drag angle.
    // The camera's orthographic scale is fixed in world units, so the CAD renders at a
    // size proportional to `previewHeight`: changing it alone rescales the whole preview,
    // and `guideY` keeps the callouts on their buttons.
    /// Tall enough that every button's pill fits on its own row beside the remote: the
    /// aluminum layout's closest rows (volume up/down, ring/Back) sit about 24 points apart.
    static let previewHeight: CGFloat = 320
    /// A pill column beside the CAD, wide enough for the longest one-line function name.
    /// Text does not scale with the preview, so this stays fixed. The whole preview
    /// (2 × 166 + 128 = 460) must fit the 720-point window's Form section, about 470 points
    /// wide; anything wider overflows and clips the sidebar and the pane's right edge.
    static let calloutColumnWidth: CGFloat = 166
    /// The gutter the CAD renders into, between the two callout columns. It scales with
    /// the preview so the callouts keep the same clearance from the remote at any size.
    static var previewBodyGutter: CGFloat { previewHeight * 0.4 }
    /// The preview's full width: the CAD's gutter plus a callout column on each side.
    static var previewWidth: CGFloat { calloutColumnWidth * 2 + previewBodyGutter }
    static let cameraHalfHeight: Double = 240
    static func guideY(_ referenceY: CGFloat) -> CGFloat {
        previewHeight / 2 + (referenceY - 199) * previewHeight / CGFloat(cameraHalfHeight * 2)
    }

    // Logarithmic resistance has no hard stop: longer drags always turn farther.
    static func dragAngle(_ distance: CGFloat) -> CGFloat { 1.2 * asinh(distance / 160) }

    static let restingAngles = SCNVector3(0.025, -0.24, 0)

    static func make(generation: RemoteGeneration, bundle: Bundle = SettingsAssets.bundle) throws -> SCNScene {
        let scene = SCNScene()
        let old = generation == .glassTouchSurface
        // A tiny generated studio environment gives metal/glass soft reflections.
        // It is created once per model, with no files, networking or animation loop.
        scene.lightingEnvironment.contents = NSImage(size: NSSize(width: 512, height: 256), flipped: false) { rect in
            // Broad light/dark studio bands give the curved metal edges a sheen.
            // A nearly uniform environment makes even fully metallic surfaces flat.
            NSGradient(colorsAndLocations: (NSColor(white: old ? 0.22 : 0.28, alpha: 1), 0),
                (NSColor(white: 0.85, alpha: 1), 0.18),
                (NSColor(white: old ? 0.28 : 0.34, alpha: 1), 0.38),
                (NSColor(white: old ? 0.55 : 0.70, alpha: 1), 0.7),
                (NSColor(white: old ? 0.22 : 0.28, alpha: 1), 1))?.draw(in: rect, angle: 0)
            return true
        }
        scene.lightingEnvironment.intensity = old ? 1.2 : 0.65
        let resource = old ? "SiriRemoteFirstGeneration" : "SiriRemoteAluminum"
        guard let url = bundle.url(forResource: resource, withExtension: "dae", subdirectory: "RemoteModels") else {
            throw ModelError.missingAsset(resource)
        }
        let imported = try SCNScene(url: url, options: [.checkConsistency: true])
        guard let remote = imported.rootNode.childNode(withName: "cad", recursively: true) else {
            throw ModelError.missingRoot(resource)
        }
        remote.removeFromParentNode()
        remote.name = "remote"
        scene.rootNode.addChildNode(remote)
        remote.enumerateChildNodes { node, _ in
            for material in node.geometry?.materials ?? [] {
                // Keep the STEP's face colors. Only finish/lighting are presentation:
                // xdr is the aluminum author's metal; glyphs remain their CAD solids.
                let name = material.name ?? ""
                let metal = name.contains("Aluminum") || name.contains("Steel") || name.contains("鋼") || name.contains("真鍮") || name == "xdr"
                let glossy = name.contains("Glossy") || name.contains("光沢") || name.contains("つや出し")
                material.lightingModel = .physicallyBased
                material.metalness.contents = metal ? 1.0 : 0.0
                material.roughness.contents = glossy ? 0.22 : (metal ? 0.34 : 0.62)
                if name == "xdr" {
                    // Satin anodized aluminum retains broad reflections and edge
                    // highlights without the sharp finish of polished chrome.
                    material.diffuse.contents = NSColor(calibratedWhite: 0.90, alpha: 1)
                    material.roughness.contents = 0.48
                }
            }
        }
        func glyph(_ symbol: String, x: CGFloat, top: CGFloat, size: CGFloat = 12, z: CGFloat, text: Bool = false) {
            let image = NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
                if symbol == "tv" {
                    NSColor.white.setStroke()
                    let screen = NSBezierPath(roundedRect: NSRect(x: 17, y: 37, width: 94, height: 65), xRadius: 5, yRadius: 5)
                    screen.lineWidth = 6
                    screen.stroke()
                    let stand = NSBezierPath()
                    stand.move(to: NSPoint(x: 46, y: 24))
                    stand.line(to: NSPoint(x: 82, y: 24))
                    stand.lineWidth = 6
                    stand.stroke()
                } else if text {
                    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 34, weight: .medium), .foregroundColor: NSColor.white]
                    let label = NSAttributedString(string: symbol, attributes: attrs)
                    let size = label.size()
                    label.draw(at: NSPoint(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2))
                } else if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 80, weight: .regular))?
                    .withSymbolConfiguration(.init(paletteColors: [.white])) {
                    let ratio = icon.size.width / icon.size.height
                    let box = ratio > 1 ? NSSize(width: 100, height: 100 / ratio) : NSSize(width: 100 * ratio, height: 100)
                    icon.draw(in: NSRect(x: (128 - box.width) / 2, y: (128 - box.height) / 2, width: box.width, height: box.height))
                }
                return true
            }
            let geometry = SCNPlane(width: size, height: size)
            let ink = SCNMaterial()
            ink.lightingModel = .constant
            ink.diffuse.contents = image
            ink.isDoubleSided = false
            geometry.materials = [ink]
            let node = SCNNode(geometry: geometry)
            node.position = SCNVector3(x, 199 - top, z)
            remote.addChildNode(node)
        }
        // The older CAD contains the actual buttons but no printed legends.
        // Add only ink above their imported faces; never replace their geometry.
        if old {
            func buttonFace(_ name: String) throws -> (x: CGFloat, top: CGFloat, z: CGFloat) {
                guard let node = remote.childNode(withName: name, recursively: true) else { throw ModelError.missingRoot(name) }
                let (low, high) = node.boundingBox
                return (CGFloat((low.x + high.x) / 2), 199 - CGFloat((low.y + high.y) / 2), CGFloat(high.z) + 0.12)
            }
            for (name, symbol) in [("back", "MENU"), ("tv", "tv"), ("siri", "mic"), ("playPause", "playpause.fill")] {
                let face = try buttonFace(name)
                glyph(symbol, x: face.x, top: face.top, size: name == "back" ? 34 : 18, z: face.z, text: name == "back")
            }
            let volume = try buttonFace("volume")
            glyph("plus", x: volume.x, top: try buttonFace("siri").top, size: 18, z: volume.z)
            glyph("minus", x: volume.x, top: try buttonFace("playPause").top, size: 18, z: volume.z)
        }
        remote.eulerAngles = restingAngles

        let camera = SCNNode()
        camera.name = "camera"
        camera.camera = SCNCamera()
        camera.camera?.usesOrthographicProjection = true
        camera.camera?.orthographicScale = cameraHalfHeight
        camera.camera?.wantsHDR = true
        // Keep the studio lighting stable; eye adaptation otherwise brightens
        // this isolated model over the first few seconds after opening Settings.
        camera.camera?.wantsExposureAdaptation = false
        camera.camera?.exposureOffset = old ? -0.5 : 0.85
        camera.camera?.zNear = 1
        camera.camera?.zFar = 2000
        camera.position = SCNVector3(0, 0, 800)
        scene.rootNode.addChildNode(camera)
        func light(_ type: SCNLight.LightType, intensity: CGFloat, position: SCNVector3) {
            let node = SCNNode()
            node.light = SCNLight()
            node.light?.type = type
            node.light?.intensity = intensity
            node.position = position
            node.look(at: SCNVector3Zero)
            scene.rootNode.addChildNode(node)
        }
        light(.ambient, intensity: old ? 120 : 80, position: SCNVector3Zero)
        light(.directional, intensity: old ? 700 : 200, position: SCNVector3(-200, 300, 400))
        light(.directional, intensity: old ? 350 : 180, position: SCNVector3(200, 0, 100))
        return scene
    }

    enum ModelError: Error { case missingAsset(String), missingRoot(String) }
}

@MainActor
struct RemoteModelView: NSViewRepresentable {
    let generation: RemoteGeneration
    /// A control lit from outside the model, e.g. while the pointer is over its pill.
    var highlighted: String? = nil
    var onHover: (String?) -> Void = { _ in }
    var onDragging: (Bool) -> Void = { _ in }
    func makeNSView(context: Context) -> RemoteModelNSView { RemoteModelNSView() }
    func updateNSView(_ view: RemoteModelNSView, context: Context) {
        view.onHover = onHover
        view.onDragging = onDragging
        view.configure(generation: generation)
        view.setExternalHighlight(highlighted)
    }
    static func dismantleNSView(_ view: RemoteModelNSView, coordinator: ()) { view.scene = nil }
}

@MainActor
final class RemoteModelNSView: SCNView {
    override var isOpaque: Bool { false }
    var onHover: (String?) -> Void = { _ in }
    var onDragging: (Bool) -> Void = { _ in }
    private var hoveredControl: String?
    private var externalHighlight: String?
    private var hoverTracking: NSTrackingArea?
    private var generation: RemoteGeneration?
    private var dragOrigin: NSPoint?
    private var dragAngles = RemoteModelScene.restingAngles
    /// The lit control's geometries with their own materials, restored on the next change.
    private var highlighted: [(geometry: SCNGeometry, materials: [SCNMaterial])] = []
    private var remote: SCNNode? { scene?.rootNode.childNode(withName: "remote", recursively: false) }

    init() {
        super.init(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
        backgroundColor = .clear
        antialiasingMode = .multisampling4X
        rendersContinuously = false
        isPlaying = false
        allowsCameraControl = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityHelp("3D remote preview. Drag to turn; release to restore the control guide.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(generation: RemoteGeneration) {
        guard self.generation != generation else { return }
        self.generation = generation
        publishHover(nil)
        dragOrigin = nil
        do { scene = try RemoteModelScene.make(generation: generation) }
        catch {
            scene = nil
            rmDebug("Settings CAD model could not load: \(error)")
            setAccessibilityHelp("3D remote model unavailable.")
        }
        pointOfView = scene?.rootNode.childNode(withName: "camera", recursively: false)
        setAccessibilityLabel(generation.displayName)
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    private func publishHover(_ key: String?) {
        guard hoveredControl != key else { return }
        hoveredControl = key
        applyHighlight(externalHighlight ?? key)
        onHover(key)
    }

    func setExternalHighlight(_ key: String?) {
        guard externalHighlight != key else { return }
        externalHighlight = key
        // Pills point at the resting pose; while dragging nothing is lit.
        if dragOrigin == nil { applyHighlight(key ?? hoveredControl) }
    }

    func applyHighlight(_ key: String?) {
        for entry in highlighted { entry.geometry.materials = entry.materials }
        highlighted = []
        guard let key, let remote else { needsDisplay = true; return }
        let name: String
        switch key {
        case "volumeUp", "volumeDown": name = "volume"
        case "select": name = generation == .glassTouchSurface ? "glass-face" : "clickpad-center"
        case "touch.edit": name = "clickpad-ring"
        default: name = key
        }
        for geometry in Self.highlightParts(name, in: remote).compactMap(\.geometry)
        where !highlighted.contains(where: { $0.geometry === geometry }) {
            highlighted.append((geometry, geometry.materials))
            // Copy materials so shared CAD finishes on other buttons remain unchanged. Dark
            // surfaces (the button, and the fills inside its TV and play symbols) turn blue; the
            // symbol's light strokes turn white, since blue-tinted strokes all but vanished.
            geometry.materials = geometry.materials.map { original in
                let material = original.copy() as! SCNMaterial
                let base = original.diffuse.contents as? NSColor ?? .darkGray
                let stroke = (base.usingColorSpace(.deviceRGB)?.brightnessComponent ?? 0) > 0.5
                material.diffuse.contents = stroke ? NSColor.white : base.blended(withFraction: 0.65, of: .systemBlue)
                material.emission.contents = stroke ? NSColor.white : NSColor.systemBlue
                material.emission.intensity = stroke ? 0.5 : 0.35
                return material
            }
        }
        needsDisplay = true
    }

    /// The named controls a printed symbol can sit on.
    private static let symbolHosts = ["siri", "power", "back", "tv", "playPause", "mute", "volume",
                                      "clickpad-center", "clickpad-ring"]

    /// Every node a control's highlight colours: its named CAD solid plus the unnamed solids
    /// lying on its face. The aluminum remote's symbols are CAD solids of their own, so TV turned
    /// blue around a dark, unlit symbol (2026-11-13). Each unnamed part belongs to the smallest
    /// named control whose face contains it, so the clickpad ring never takes the center's
    /// parts. Ink planes added for the 1st-gen remote are not CAD parts and keep their image.
    static func highlightParts(_ name: String, in remote: SCNNode) -> [SCNNode] {
        guard let control = remote.childNode(withName: name, recursively: true) else { return [] }
        guard symbolHosts.contains(name) else { return [control] }
        func extent(_ node: SCNNode) -> (low: SCNVector3, high: SCNVector3) {
            let (lo, hi) = node.boundingBox
            var low = SCNVector3(CGFloat.infinity, .infinity, .infinity)
            var high = SCNVector3(-CGFloat.infinity, -.infinity, -.infinity)
            for x in [lo.x, hi.x] { for y in [lo.y, hi.y] { for z in [lo.z, hi.z] {
                let p = node.convertPosition(SCNVector3(x, y, z), to: remote)
                low = SCNVector3(min(low.x, p.x), min(low.y, p.y), min(low.z, p.z))
                high = SCNVector3(max(high.x, p.x), max(high.y, p.y), max(high.z, p.z))
            } } }
            return (low, high)
        }
        let hosts = symbolHosts.compactMap { key in remote.childNode(withName: key, recursively: true).map { (key, extent($0)) } }
        func area(_ e: (low: SCNVector3, high: SCNVector3)) -> CGFloat { (e.high.x - e.low.x) * (e.high.y - e.low.y) }
        var parts = [control]
        remote.enumerateChildNodes { node, _ in
            guard node.geometry != nil, node.name?.hasPrefix("cad-part-") == true else { return }
            let part = extent(node)
            let owner = hosts.filter { _, face in
                part.low.x >= face.low.x - 0.5 && part.high.x <= face.high.x + 0.5
                    && part.low.y >= face.low.y - 0.5 && part.high.y <= face.high.y + 0.5
                    && part.low.z >= face.low.z - 0.5
            }.min { area($0.1) < area($1.1) }
            if owner?.0 == name { parts.append(node) }
        }
        return parts
    }

    override func mouseMoved(with event: NSEvent) {
        guard dragOrigin == nil, let remote else { publishHover(nil); return }
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue]).first else {
            publishHover(nil); return
        }
        let local = remote.convertPosition(hit.worldCoordinates, from: nil)
        publishHover(Self.control(at: local, hitNode: hit.node, remote: remote, generation: generation ?? .unknown))
    }

    // Test the imported control bounds so CAD glyph solids and ink planes resolve
    // to their underlying button as well. A hit on the shell is otherwise inert.
    static func control(at point: SCNVector3, hitNode: SCNNode, remote: SCNNode, generation: RemoteGeneration) -> String? {
        for key in ["siri", "power", "back", "tv", "playPause", "mute", "volume", "clickpad-center", "clickpad-ring"] {
            guard let node = remote.childNode(withName: key, recursively: true) else { continue }
            let p = node.convertPosition(point, from: remote)
            let (low, high) = node.boundingBox
            guard p.x >= low.x - 1, p.x <= high.x + 1,
                  p.y >= low.y - 1, p.y <= high.y + 1,
                  p.z >= low.z - 1, p.z <= high.z + 2 else { continue }
            if key == "volume" { return p.y > (low.y + high.y) / 2 ? "volumeUp" : "volumeDown" }
            if key == "clickpad-center" { return "select" }
            if key == "clickpad-ring" { return "touch.edit" }
            return key
        }
        if generation == .glassTouchSurface, hitNode.name == "glass-face", point.y > 90 { return "select" }
        return nil
    }

    override func mouseExited(with event: NSEvent) { publishHover(nil) }

    override func mouseDown(with event: NSEvent) {
        publishHover(nil)
        if let remote {
            dragAngles = remote.presentation.eulerAngles
            remote.removeAllAnimations()
            remote.eulerAngles = dragAngles
        }
        dragOrigin = convert(event.locationInWindow, from: nil)
        onDragging(true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let remote else { return }
        let point = convert(event.locationInWindow, from: nil)
        remote.eulerAngles = SCNVector3(
            CGFloat(dragAngles.x) - RemoteModelScene.dragAngle(point.y - origin.y),
            CGFloat(dragAngles.y) + RemoteModelScene.dragAngle(point.x - origin.x), CGFloat(dragAngles.z))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { restorePose() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(cancelDrag), name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(cancelDrag), name: NSWindow.willCloseNotification, object: window)
        }
        restorePose(animated: false)
    }
    @objc private func cancelDrag() { publishHover(nil); restorePose(animated: false) }
    private func restorePose(animated: Bool = true) {
        if dragOrigin != nil { onDragging(false) }
        dragOrigin = nil
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.3 : 0
        remote?.eulerAngles = RemoteModelScene.restingAngles
        SCNTransaction.commit()
        needsDisplay = true
    }
}
