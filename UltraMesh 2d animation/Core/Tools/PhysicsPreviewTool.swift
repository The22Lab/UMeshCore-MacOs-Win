import Foundation
import simd

/// Physics Preview Tool. Lets the animator interactively drag bones while the
/// physics simulation is running, producing immediate secondary-motion feedback.
///
/// Dragging a bone temporarily overrides its world position via a pose override
/// stored in SceneManager, which `baseWorldMatrices()` reads to feed correct
/// "rest" targets into the physics solver. On mouse-up the override is cleared
/// and the simulation continues from the disturbed state.
final class PhysicsPreviewTool: Tool {
    let type: ActiveTool = .physicsPreview

    private var draggingBoneID: UUID?
    private var dragOffset: SIMD2<Float> = .zero

    func onMouseDown(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        _ = assets
        // Hit-test bones
        let segments = scene.skeleton.worldLineSegments()
        guard !segments.isEmpty else { return }
        let viewSize = input.viewSize
        let screenPt = input.screenPosition
        let jointR: Float = 14

        var closest: (id: UUID, dist: Float)?
        for (bone, start, end) in segments {
            let sScreen = input.camera?.worldToScreen(start, viewSize: viewSize) ?? start
            let eScreen = input.camera?.worldToScreen(end, viewSize: viewSize) ?? end
            let dS = simd_distance(screenPt, sScreen)
            let dE = simd_distance(screenPt, eScreen)
            let best = min(dS, dE)
            if best <= jointR, closest.map({ best < $0.dist }) ?? true {
                closest = (bone.id, best)
            }
        }

        guard let hit = closest else {
            draggingBoneID = nil
            return
        }
        draggingBoneID = hit.id
        scene.setPhysicsPreviewBoneOverride(hit.id, worldPosition: input.position)
    }

    func onMouseDrag(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        _ = assets
        guard let boneID = draggingBoneID else { return }
        scene.setPhysicsPreviewBoneOverride(boneID, worldPosition: input.position)
    }

    func onMouseUp(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        _ = assets
        if let boneID = draggingBoneID {
            scene.clearPhysicsPreviewBoneOverride(boneID)
        }
        draggingBoneID = nil
    }
}
