import Foundation
import Metal
import simd

final class SkewTool: Tool {
    let type: ActiveTool = .skew

    private var activeID: UUID?
    private var activeBoneID: UUID?
    private var startSkew = SIMD2<Float>(repeating: 0)
    private var activeAxis: ShearAxis?
    private var startAngle: Float = 0
    private var boneCenter = SIMD2<Float>(repeating: 0)
    private let skewState: SkewGizmoState
    private var mouseDownPosition: SIMD2<Float>?
    private var didDrag = false

    private let dragThreshold: Float = 4

    init(skewState: SkewGizmoState) {
        self.skewState = skewState
    }

    private func ensureDragStarted(currentPosition: SIMD2<Float>) -> Bool {
        if didDrag { return true }
        guard let down = mouseDownPosition else { return false }
        if simd_distance(currentPosition, down) >= dragThreshold {
            didDrag = true
            return true
        }
        return false
    }

    func onMouseDown(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        guard case let .skewEdge(index) = input.activeHandle else { return }
        scene.beginInteraction()
        mouseDownPosition = input.position
        didDrag = false
        if let boneID = scene.selectedBoneID,
           let segment = scene.skeleton.lineSegment(for: boneID) {
            activeBoneID = boneID
            startSkew = scene.skeleton.bones[boneID]?.localTransform.skew ?? .zero
            activeAxis = switch index {
            case 0: .shearX
            case 1: .shearY
            default: .shearZ
            }
            boneCenter = (segment.start + segment.end) * 0.5
            startAngle = atan2(input.position.y - boneCenter.y, input.position.x - boneCenter.x)
            return
        }
        let hit = scene.selectedImageID ?? ToolUtilities.hitTestScreen(
            screenPoint: input.screenPosition,
            viewSize: input.viewSize,
            scene: scene,
            assets: assets,
            camera: input.camera
        )
        guard let id = hit,
              let image = scene.image(for: id),
              let camera = input.camera else { return }
        scene.selectedImageID = id
        activeID = id
        startSkew = image.skew
        activeAxis = switch index {
        case 0: .shearX
        case 1: .shearY
        default: .shearZ
        }
        skewState.shearX = image.skew.x
        skewState.shearY = image.skew.y
        let centerScreen = camera.worldToScreen(image.position, viewSize: input.viewSize)
        startAngle = atan2(input.screenPosition.y - centerScreen.y, input.screenPosition.x - centerScreen.x)
        let hitArc = index + 1
        skewState.mouseDown(screenPt: CGPoint(x: CGFloat(input.screenPosition.x), y: CGFloat(input.screenPosition.y)), hitArc: hitArc)
    }

    func onMouseDrag(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        guard ensureDragStarted(currentPosition: input.position) else { return }
        if let boneID = activeBoneID,
           let axis = activeAxis {
            let currentAngle = atan2(input.position.y - boneCenter.y, input.position.x - boneCenter.x)
            var d = (startAngle - currentAngle) * 180 / .pi
            while d > 180 { d -= 360 }
            while d < -180 { d += 360 }
            if input.isShiftPressed {
                d = d.rounded()
            }
            var next = startSkew
            switch axis {
            case .shearX:
                next.x = (startSkew.x + d).clamped(to: -180...180)
            case .shearY:
                next.y = (startSkew.y + d).clamped(to: -180...180)
            case .shearZ:
                next.x = (startSkew.x + d).clamped(to: -180...180)
                next.y = (startSkew.y - d).clamped(to: -180...180)
            }
            scene.setBoneSkew(id: boneID, skew: next)
            return
        }
        guard let id = activeID,
              let axis = activeAxis,
              let image = scene.image(for: id),
              let camera = input.camera else { return }
        let centerScreen = camera.worldToScreen(image.position, viewSize: input.viewSize)
        let currentAngle = atan2(input.screenPosition.y - centerScreen.y, input.screenPosition.x - centerScreen.x)
        var d = (startAngle - currentAngle) * 180 / .pi
        while d > 180 { d -= 360 }
        while d < -180 { d += 360 }
        if input.isShiftPressed {
            d = d.rounded()
        }
        var next = startSkew
        switch axis {
        case .shearX:
            next.x = (startSkew.x + d).clamped(to: -180...180)
        case .shearY:
            next.y = (startSkew.y + d).clamped(to: -180...180)
        case .shearZ:
            next.x = (startSkew.x + d).clamped(to: -180...180)
            next.y = (startSkew.y - d).clamped(to: -180...180)
        }

        scene.setImageSkew(id: id, skew: next)

        skewState.applyDrag(
            deltaDegrees: d,
            axis: axis,
            isSnap: input.isShiftPressed,
            cursor: CGPoint(x: CGFloat(input.screenPosition.x), y: CGFloat(input.screenPosition.y))
        )
    }

    func onMouseUp(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        scene.endInteraction()
        defer {
            activeBoneID = nil
            activeID = nil
            activeAxis = nil
            mouseDownPosition = nil
            didDrag = false
            skewState.mouseUp()
        }
        guard didDrag else { return }
        if let boneID = activeBoneID,
           let bone = scene.skeleton.bones[boneID] {
            scene.commitKeyframe(for: boneID, property: .shear, value: .shear(bone.localTransform.skew))
            return
        }
        if let id = activeID, let image = scene.image(for: id) {
            scene.commitKeyframe(for: id, property: .shear, value: .shear(image.skew))
        }
    }

    func update(scene: SceneManager, assets: AssetManager) {
        guard activeID == nil, activeBoneID == nil else { return }
        guard let selectedID = scene.selectedImageID, let image = scene.image(for: selectedID) else { return }
        if skewState.shearX != image.skew.x || skewState.shearY != image.skew.y {
            skewState.shearX = image.skew.x
            skewState.shearY = image.skew.y
        }
    }
}
