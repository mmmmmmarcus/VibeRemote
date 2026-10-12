import AppKit
import SceneKit
import CryptoKit
import XCTest
@testable import VibeRemote

final class RemoteModelTests: XCTestCase {
    @MainActor
    func testBothModelsHaveDepthDistinctControlsAndIdleRenderer() throws {
        let view = RemoteModelNSView()
        view.frame = NSRect(x: 0, y: 0, width: 144, height: 398)
        XCTAssertFalse(view.rendersContinuously)
        XCTAssertFalse(view.isPlaying)
        for generation in [RemoteGeneration.glassTouchSurface, .aluminumClickpad] {
            view.configure(generation: generation)
            let scene = try XCTUnwrap(view.scene)
            let root = try XCTUnwrap(scene.rootNode.childNode(withName: "remote", recursively: false))
            let body = try XCTUnwrap(root.childNode(withName: "body", recursively: false))
            let geometry = try XCTUnwrap(body.geometry)
            XCTAssertFalse(geometry is SCNShape, "Use the tessellated STEP rather than approximating the body")
            let (low, high) = root.boundingBox
            XCTAssertEqual(high.y - low.y, 394, accuracy: 0.1)
            XCTAssertGreaterThan(high.z - low.z, 20)
            let resource = generation == .glassTouchSurface ? "SiriRemoteFirstGeneration" : "SiriRemoteAluminum"
            let metadata = try XCTUnwrap(SettingsAssets.bundle.url(forResource: resource, withExtension: "json", subdirectory: "RemoteModels"))
            let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Design/RemoteModels").appendingPathComponent(try XCTUnwrap(manifest["source"] as? String))
            XCTAssertEqual(SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined(), manifest["sha256"] as? String)
            let solids = try XCTUnwrap(manifest["solids"] as? [[String: Any]])
            XCTAssertEqual(solids.count, generation == .glassTouchSurface ? 9 : 45)
            let meshes = root.childNodes.compactMap(\.geometry).filter { !($0 is SCNPlane) }
            XCTAssertEqual(meshes.count, solids.count)
            XCTAssertEqual(meshes.flatMap(\.elements).reduce(0) { $0 + $1.primitiveCount }, manifest["triangles"] as? Int)
            for part in solids {
                let name = try XCTUnwrap(part["name"] as? String)
                if ["back", "tv", "siri", "playPause", "mute", "power"].contains(name) {
                    let layout = RemoteSettingsLayout(generation: generation)
                    let guide = try XCTUnwrap((layout.left + layout.right).first { $0.key == name })
                    XCTAssertEqual(guide.centerY, try XCTUnwrap(part["top"] as? Double), accuracy: 0.1)
                }
            }
            XCTAssertNotNil(root.childNode(withName: "siri", recursively: false))
            XCTAssertEqual(root.childNode(withName: "power", recursively: false) != nil, generation == .aluminumClickpad)
            XCTAssertEqual(root.childNode(withName: "mute", recursively: false) != nil, generation == .aluminumClickpad)
            func event(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            view.mouseDown(with: try event(.leftMouseDown, x: 60, y: 100))
            view.mouseDragged(with: try event(.leftMouseDragged, x: 500, y: 200))
            XCTAssertGreaterThan(abs(root.eulerAngles.y - RemoteModelScene.restingAngles.y), 0.5)
            XCTAssertLessThanOrEqual(abs(root.eulerAngles.y - RemoteModelScene.restingAngles.y), 1.251)
            view.mouseUp(with: try event(.leftMouseUp, x: 500, y: 200))
            XCTAssertEqual(root.eulerAngles.y, RemoteModelScene.restingAngles.y, accuracy: 0.001)
            XCTAssertFalse(view.rendersContinuously)
            let before = scene
            view.configure(generation: generation)
            XCTAssertTrue(view.scene === before, "Battery and mapping updates must not rebuild GPU resources")
            if let output = ProcessInfo.processInfo.environment["VIBEREMOTE_MODEL_RENDER"] {
                let renderer = SCNRenderer(device: nil, options: nil)
                let renderScene = try RemoteModelScene.make(generation: generation)
                renderer.scene = renderScene
                renderer.pointOfView = renderScene.rootNode.childNode(withName: "camera", recursively: false)
                let renderRoot = try XCTUnwrap(renderScene.rootNode.childNode(withName: "remote", recursively: false))
                for (pose, angles) in [("front", RemoteModelScene.restingAngles), ("side", SCNVector3(0.1, -0.9, 0))] {
                    SCNTransaction.begin()
                    SCNTransaction.disableActions = true
                    renderRoot.eulerAngles = angles
                    SCNTransaction.commit()
                    let image = renderer.snapshot(atTime: 0, with: NSSize(width: 432, height: 1194), antialiasingMode: .multisampling4X)
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "\(output)-\(generation == .glassTouchSurface ? "first" : "new")-\(pose).png"))
                }
            }
        }
    }
}
