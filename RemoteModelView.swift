import AppKit
import SceneKit
import SwiftUI

/// Meshes tessellated from the supplied STEP assemblies. Conversion preserves every
/// solid and face color; only the display coordinate system and uniform scale change.
@MainActor
enum RemoteModelScene {
    // Keep the CAD comfortably inside the viewport at every supported drag angle.
    static let previewHeight: CGFloat = 280
    static let previewWidth: CGFloat = 144
    static let cameraHalfHeight: Double = 240
    static func guideY(_ referenceY: CGFloat) -> CGFloat {
        previewHeight / 2 + (referenceY - 199) * previewHeight / CGFloat(cameraHalfHeight * 2)
    }

    static let restingAngles = SCNVector3(0.025, -0.24, 0)

    static func make(generation: RemoteGeneration, bundle: Bundle = SettingsAssets.bundle) throws -> SCNScene {
        let scene = SCNScene()
        // A tiny generated studio environment gives metal/glass soft reflections.
        // It is created once per model, with no files, networking or animation loop.
        scene.lightingEnvironment.contents = NSImage(size: NSSize(width: 512, height: 256), flipped: false) { rect in
            NSGradient(colorsAndLocations: (NSColor(white: 0.22, alpha: 1), 0),
                (NSColor(white: 0.85, alpha: 1), 0.18),
                (NSColor(white: 0.28, alpha: 1), 0.38),
                (NSColor(white: 0.55, alpha: 1), 0.7),
                (NSColor(white: 0.22, alpha: 1), 1))?.draw(in: rect, angle: 0)
            return true
        }
        scene.lightingEnvironment.intensity = 0.7
        let old = generation == .glassTouchSurface
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
                material.metalness.contents = metal ? 0.75 : 0.05
                material.roughness.contents = glossy ? 0.22 : (metal ? 0.34 : 0.62)
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
        camera.camera?.exposureOffset = -0.5
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
        light(.ambient, intensity: 450, position: SCNVector3Zero)
        light(.directional, intensity: 950, position: SCNVector3(-200, 300, 400))
        light(.directional, intensity: 650, position: SCNVector3(200, 0, 100))
        return scene
    }

    enum ModelError: Error { case missingAsset(String), missingRoot(String) }
}

@MainActor
struct RemoteModelView: NSViewRepresentable {
    let generation: RemoteGeneration
    func makeNSView(context: Context) -> RemoteModelNSView { RemoteModelNSView() }
    func updateNSView(_ view: RemoteModelNSView, context: Context) { view.configure(generation: generation) }
    static func dismantleNSView(_ view: RemoteModelNSView, coordinator: ()) { view.scene = nil }
}

@MainActor
final class RemoteModelNSView: SCNView {
    override var isOpaque: Bool { false }
    private var generation: RemoteGeneration?
    private var dragOrigin: NSPoint?
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
    override func mouseDown(with event: NSEvent) {
        remote?.removeAllAnimations()
        dragOrigin = convert(event.locationInWindow, from: nil)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let remote else { return }
        let point = convert(event.locationInWindow, from: nil)
        remote.eulerAngles = SCNVector3(
            CGFloat(RemoteModelScene.restingAngles.x) - min(0.35, max(-0.35, (point.y - origin.y) / 300)),
            CGFloat(RemoteModelScene.restingAngles.y) + min(1.25, max(-1.25, (point.x - origin.x) / 110)), 0)
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
    @objc private func cancelDrag() { restorePose(animated: false) }
    private func restorePose(animated: Bool = true) {
        dragOrigin = nil
        SCNTransaction.begin()
        SCNTransaction.animationDuration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.3 : 0
        remote?.eulerAngles = RemoteModelScene.restingAngles
        SCNTransaction.commit()
        needsDisplay = true
    }
}
