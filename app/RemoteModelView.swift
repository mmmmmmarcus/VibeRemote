import AppKit
import SceneKit
import SwiftUI

/// Meshes tessellated from the supplied STEP assemblies. Conversion preserves every
/// solid and face color; only the display coordinate system and uniform scale change.
@MainActor
enum RemoteModelScene {
    // Keep the CAD comfortably inside the viewport at every supported drag angle.
    static let previewHeight: CGFloat = 280
    static let previewWidth: CGFloat = 472
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
    var onHover: (String?) -> Void = { _ in }
    func makeNSView(context: Context) -> RemoteModelNSView { RemoteModelNSView() }
    func updateNSView(_ view: RemoteModelNSView, context: Context) { view.onHover = onHover; view.configure(generation: generation) }
    static func dismantleNSView(_ view: RemoteModelNSView, coordinator: ()) { view.scene = nil }
}

@MainActor
final class RemoteModelNSView: SCNView {
    override var isOpaque: Bool { false }
    var onHover: (String?) -> Void = { _ in }
    private var hoveredControl: String?
    private var hoverTracking: NSTrackingArea?
    private var generation: RemoteGeneration?
    private var dragOrigin: NSPoint?
    private var dragAngles = RemoteModelScene.restingAngles
    private var highlightedGeometry: SCNGeometry?
    private var originalMaterials: [SCNMaterial] = []
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
        applyHighlight(key)
        onHover(key)
    }

    func applyHighlight(_ key: String?) {
        highlightedGeometry?.materials = originalMaterials
        highlightedGeometry = nil
        originalMaterials = []
        guard let key, let remote else { needsDisplay = true; return }
        let name: String
        switch key {
        case "volumeUp", "volumeDown": name = "volume"
        case "select": name = generation == .glassTouchSurface ? "glass-face" : "clickpad-center"
        case "touch.edit": name = "clickpad-ring"
        default: name = key
        }
        guard let geometry = remote.childNode(withName: name, recursively: true)?.geometry else { return }
        highlightedGeometry = geometry
        originalMaterials = geometry.materials
        // Copy materials so shared CAD finishes on other buttons remain unchanged.
        geometry.materials = originalMaterials.map { original in
            let material = original.copy() as! SCNMaterial
            let base = original.diffuse.contents as? NSColor ?? .darkGray
            material.diffuse.contents = base.blended(withFraction: 0.65, of: .systemBlue)
            material.emission.contents = NSColor.systemBlue
            material.emission.intensity = 0.35
            return material
        }
        needsDisplay = true
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
        dragOrigin = nil
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.3 : 0
        remote?.eulerAngles = RemoteModelScene.restingAngles
        SCNTransaction.commit()
        needsDisplay = true
    }
}
