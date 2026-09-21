import Foundation
import simd

final class ScaleTool: Tool {
    let type: ActiveTool = .scale

    private var activeID: UUID?
    private var activeBoneID: UUID?
    /// Every selected bone, parents first — the same order the other two
    /// transforms need, and for the same reason.
    private var boneDragOrder: [UUID] = []
    private var boneStartScales: [UUID: SIMD2<Float>] = [:]
    private var boneStartLengths: [UUID: Float] = [:]
    private var activeHandle: GizmoHandle?
    private var startScale: SIMD2<Float> = SIMD2<Float>(repeating: 1)
    private var startDistance: Float = 1
    private var startVector: SIMD2<Float> = .zero
    private var boneStart: SIMD2<Float> = .zero
    private var startBoneLength: Float = 0
    private var startBoneScale: SIMD2<Float> = SIMD2<Float>(1, 1)
    private var settleTarget: SIMD2<Float>?
    private var settleID: UUID?
    private var mouseDownPosition: SIMD2<Float>?
    private var didDrag = false

    private let settleFactor: Float = 0.22
    private let snapStep: Float = 0.1
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
        guard case .scaleCorner = input.activeHandle else { return }
        scene.beginInteraction()
        mouseDownPosition = input.position
        didDrag = false
        if let boneID = scene.selectedBoneID,
           let segment = scene.skeleton.lineSegment(for: boneID) {
            activeBoneID = boneID
            activeHandle = input.activeHandle
            boneStart = segment.start
            startBoneLength = max(simd_distance(segment.start, segment.end), 12)
            if let bone = scene.skeleton.bones[boneID] {
                startBoneScale = SIMD2<Float>(bone.localTransform.scale.x, bone.localTransform.scale.y)
            } else {
                startBoneScale = SIMD2<Float>(1, 1)
            }
            startVector = input.startPosition - segment.start
            startDistance = max(1, simd_length(startVector))
            boneDragOrder = scene.selectedBonesInDepthOrder
            boneStartScales = Dictionary(uniqueKeysWithValues: boneDragOrder.compactMap { id in
                scene.skeleton.bones[id].map {
                    (id, SIMD2<Float>($0.localTransform.scale.x, $0.localTransform.scale.y))
                }
            })
            boneStartLengths = Dictionary(uniqueKeysWithValues: boneDragOrder.compactMap { id in
                scene.skeleton.bones[id].map { (id, $0.length) }
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
        activeHandle = input.activeHandle
        startScale = image.scale
        settleTarget = nil
        settleID = nil
        startVector = SIMD2<Float>(
            input.startPosition.x - image.position.x,
            input.startPosition.y - image.position.y
        )
        startDistance = max(1, simd_length(startVector))
    }

    func onMouseDrag(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        guard ensureDragStarted(currentPosition: input.position) else { return }
        if let boneID = activeBoneID {
            let vector = input.position - boneStart
            let distance = max(1, simd_length(vector))
            let scaled = boneDragOrder.isEmpty ? [boneID] : boneDragOrder
            if scene.isAnimationEditingEnabled {
                var scale = SIMD2<Float>(
                    max(startBoneScale.x * max(distance / startDistance, 0.001), 0.001),
                    startBoneScale.y)
                if input.isShiftPressed {
                    scale = ToolUtilities.snapScale(scale, step: snapStep)
                }
                // The factor is read back off the ACTIVE bone after snapping,
                // so Shift snaps that bone and the group keeps its proportions
                // instead of each bone landing on its own step.
                let appliedFactor = scale.x / max(startBoneScale.x, 0.001)
                for id in scaled {
                    let start = boneStartScales[id] ?? startBoneScale
                    scene.setBoneScale(id: id,
                                       scale: SIMD2<Float>(max(start.x * appliedFactor, 0.001), start.y))
                }
            } else {
                var length = startBoneLength * (distance / startDistance)
                if input.isShiftPressed {
                    length = ToolUtilities.snapScale(length, step: snapStep)
                }
                let appliedFactor = length / max(startBoneLength, 0.001)
                for id in scaled {
                    let start = boneStartLengths[id] ?? startBoneLength
                    scene.setBoneLength(id: id, length: start * appliedFactor)
                }
            }
            return
        }
        guard let id = activeID,
              let image = scene.image(for: id),
              let activeHandle else { return }
        let vector = SIMD2<Float>(
            input.position.x - image.position.x,
            input.position.y - image.position.y
        )
        var scale = startScale
        switch activeHandle {
        case .scaleCorner(0):
            let factor = max(0.05, abs(vector.x) / max(1, abs(startVector.x)))
            scale.x = max(0.05, startScale.x * factor)
        case .scaleCorner(1):
            let factor = max(0.05, abs(vector.y) / max(1, abs(startVector.y)))
            scale.y = max(0.05, startScale.y * factor)
        default:
            let distance = max(1, simd_length(vector))
            let factor = distance / startDistance
            scale = simd_max(SIMD2<Float>(repeating: 0.05), startScale * factor)
        }
        if input.isShiftPressed {
            scale = ToolUtilities.snapScale(scale, step: snapStep)
        }
        scene.setImageScale(id: id, scale: scale)
    }

    func onMouseUp(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        scene.endInteraction()
        defer {
            activeBoneID = nil
            boneDragOrder = []
            boneStartScales = [:]
            boneStartLengths = [:]
            activeID = nil
            activeHandle = nil
            mouseDownPosition = nil
            didDrag = false
        }
        guard didDrag else { return }
        if let boneID = activeBoneID {
            if scene.isAnimationEditingEnabled {
                for id in (boneDragOrder.isEmpty ? [boneID] : boneDragOrder) {
                    guard let bone = scene.skeleton.bones[id] else { continue }
                    let scale = SIMD2<Float>(bone.localTransform.scale.x, bone.localTransform.scale.y)
                    scene.commitKeyframe(for: id, property: .scale, value: .scale(scale))
                }
            }
            return
        }
        guard let id = activeID, let image = scene.image(for: id) else { return }
        let raw = image.scale
        let target = input.isShiftPressed ? ToolUtilities.snapScale(raw, step: snapStep) : raw
        settleTarget = target
        settleID = id
        scene.commitKeyframe(for: id, property: .scale, value: .scale(target))
    }

    func update(scene: SceneManager, assets: AssetManager) {
        guard let id = settleID, let target = settleTarget, let image = scene.image(for: id) else { return }
        let current = image.scale
        let next = current + (target - current) * settleFactor
        scene.setImageScale(id: id, scale: next)
        if simd_length(next - target) < 0.001 {
            scene.setImageScale(id: id, scale: target)
            settleTarget = nil
            settleID = nil
        }
    }
}
