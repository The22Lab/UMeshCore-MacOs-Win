import Foundation
import simd

final class RotateTool: Tool {
    let type: ActiveTool = .rotate

    private var activeID: UUID?
    private var activeBoneID: UUID?
    /// Every selected bone, parents first — see `selectedBonesInChainOrder`.
    private var boneDragOrder: [UUID] = []
    /// Where each of them started, so the drag is relative. One start value for
    /// the lot would snap every bone onto the active one's angle.
    private var boneStartRotations: [UUID: Float] = [:]
    private var startRotation: Float = 0
    private var startAngle: Float = 0
    private var boneStart: SIMD2<Float> = .zero
    private var boneLength: Float = 0
    private var settleTarget: Float?
    private var settleID: UUID?
    private var mouseDownPosition: SIMD2<Float>?
    private var didDrag = false

    private let settleFactor: Float = 0.22
    private let snapStepDegrees: Float = 15
    private let dragThreshold: Float = 4

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
        guard input.activeHandle == .rotateRing else { return }
        scene.beginInteraction()
        mouseDownPosition = input.position
        didDrag = false
        if let boneID = scene.selectedBoneID,
           let segment = scene.skeleton.lineSegment(for: boneID) {
            activeBoneID = boneID
            boneStart = segment.start
            boneLength = max(simd_distance(segment.start, segment.end), 12)
            let vector = input.startPosition - segment.start
            startAngle = atan2(vector.y, vector.x)
            startRotation = scene.skeleton.worldRotation(for: boneID) ?? 0
            // The whole selection turns, not only the bone the ring is drawn
            // on. Depth order because `setBoneRotation` converts a world angle
            // against the parent's CURRENT world rotation: a child written
            // before its parent is measured against the old angle and then
            // inherits the parent's turn on top, so it turns twice.
            boneDragOrder = scene.selectedBonesInDepthOrder
            boneStartRotations = Dictionary(uniqueKeysWithValues: boneDragOrder.compactMap { id in
                scene.skeleton.worldRotation(for: id).map { (id, $0) }
            })
            return
        }
        let hit = scene.selectedImageID ?? ToolUtilities.hitTestScreen(
            screenPoint: input.screenPosition,
            viewSize: input.viewSize,
            scene: scene,
            assets: assets,
            camera: input.camera
        )
        guard let id = hit, let image = scene.image(for: id) else { return }
        scene.selectedImageID = id
        activeID = id
        startRotation = image.rotation
        if simd_length(image.rotation3D) > 0.0001 {
            scene.updateImage(id: id) { image in
                image.rotation3D = .zero
            }
        }
        settleTarget = nil
        settleID = nil
        let vector = input.startPosition - image.position
        startAngle = atan2(vector.y, vector.x)
    }

    func onMouseDrag(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        guard ensureDragStarted(currentPosition: input.position) else { return }
        if let boneID = activeBoneID {
            let vector = input.position - boneStart
            let angle = atan2(vector.y, vector.x)
            let delta = angle - startAngle
            var rotation = startRotation + delta
            if input.isShiftPressed {
                rotation = ToolUtilities.snapAngle(rotation, stepDegrees: snapStepDegrees)
            }
            // Taken from the ACTIVE bone after snapping, so Shift snaps that
            // bone to the grid and the rest of the selection follows rigidly.
            // Snapping each bone on its own would pull the group apart at every
            // step boundary.
            let appliedDelta = rotation - startRotation
            guard !boneDragOrder.isEmpty else {
                scene.setBoneRotation(id: boneID, worldAngle: rotation)
                return
            }
            for id in boneDragOrder {
                guard let start = boneStartRotations[id] else { continue }
                scene.setBoneRotation(id: id, worldAngle: start + appliedDelta)
            }
            return
        }
        guard let id = activeID, let image = scene.image(for: id) else { return }
        let vector = input.position - image.position
        let angle = atan2(vector.y, vector.x)
        let delta = angle - startAngle
        var rotation = startRotation + delta
        if input.isShiftPressed {
            rotation = ToolUtilities.snapAngle(rotation, stepDegrees: snapStepDegrees)
        }
        scene.setImageRotation(id: id, rotation: rotation)
    }

    func onMouseUp(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        scene.endInteraction()
        defer {
            activeBoneID = nil
            boneDragOrder = []
            boneStartRotations = [:]
            activeID = nil
            mouseDownPosition = nil
            didDrag = false
        }
        guard didDrag else { return }
        if let boneID = activeBoneID {
            // A key for each bone that moved. Committing only the active one
            // recorded a pose in which the rest of the selection had turned on
            // screen and nowhere in the animation.
            for id in (boneDragOrder.isEmpty ? [boneID] : boneDragOrder) {
                scene.commitKeyframe(for: id, property: .rotate)
            }
            return
        }
        guard let id = activeID, let image = scene.image(for: id) else { return }
        let raw = image.rotation
        let target = input.isShiftPressed ? ToolUtilities.snapAngle(raw, stepDegrees: snapStepDegrees) : raw
        settleTarget = target
        settleID = id
        scene.commitKeyframe(for: id, property: .rotate)
    }

    func update(scene: SceneManager, assets: AssetManager) {
        guard let id = settleID, let target = settleTarget, let image = scene.image(for: id) else { return }
        let current = image.rotation
        let next = current + (target - current) * settleFactor
        scene.setImageRotation(id: id, rotation: next)
        if abs(next - target) < 0.001 {
            scene.setImageRotation(id: id, rotation: target)
            settleTarget = nil
            settleID = nil
        }
    }
}
