import Foundation
import simd

/// A rig instance's bones, folded into the matrices a vertex shader can use.
///
/// ## The fold
///
/// `Mesh.skinnedVertices` wraps each bone transform in two per-sprite affines:
/// `B` maps a bind vertex into the space the inverse-bind matrices expect, and
/// `A` maps the blended result back. Both are affine and the bone's own matrix
/// depends only on the bone, so
///
///     N = A · (world · inverseBind) · B
///
/// is one matrix per sprite per bone, and the shader is then the textbook
/// four-weight sum. Thirty matrices instead of 8 320, and the per-vertex work
/// moves to hardware built for it.
///
/// Measured in `Editor/verify_scene_gpu_skinning.py`: the CPU path does 16 640
/// UUID-keyed dictionary lookups and 8 320 matrix products per frame for one
/// eight-sprite rig, to arrive at about thirty distinct matrices.
///
/// ## The condition, which is the whole of this type
///
/// **The fold is only correct if the weights sum to one.** Pushing an affine
/// inside a weighted sum adds its translation once per influence instead of
/// once. The data does not guarantee normalised weights — the weight brush
/// normalises, auto-weighting caps at four without renormalising, and
/// `skinnedVertices` divides by the total defensively, so nothing upstream
/// ever complains. Measured: 700 units out of place on a 400×600 sprite, which
/// reads as a rigging mistake rather than a renderer one.
///
/// So `SkinnedVertex` normalises, here, on the way to the GPU. Nothing else
/// may skip it.
struct SceneSkinPalette {

    /// At most four bones move a vertex, which is what `autoWeightMesh`,
    /// `skinImageToSkeleton` and the weight brush all already cap at.
    static let maximumInfluences = 4

    /// SLOT ZERO IS THE IDENTITY, always.
    ///
    /// A vertex with no influences must come out at its bind position. The CPU
    /// says so with a branch on the weight total; a shader that branches per
    /// vertex on a weight sum has a divergent branch in its hottest loop. So
    /// the palette reserves slot zero for `A · B` — which is the identity,
    /// because A is B's inverse — and an unweighted vertex is written as one
    /// influence of weight 1 on slot zero. No branch, same answer.
    ///
    /// Building the palette straight from the bone list instead puts the first
    /// bone in slot zero, and then every unweighted vertex rides that bone.
    static let identitySlot: UInt16 = 0

    /// Folded matrices, slot 0 the identity and the rest in bone order.
    private(set) var matrices: [simd_float4x4] = []
    /// Where each bone landed. Built in the skeleton's own order, never from a
    /// Set: `CLAUDE.md` records that Swift seeds a Set's hashing per process,
    /// so a slot taken from one would move between launches.
    private(set) var slots: [UUID: UInt16] = [:]

    /// Fold a sprite's bones, and everything that happens to the result.
    ///
    /// A rig instance's vertex does not stop at the sprite. `drawRigSprites`
    /// skins it, then `ToolUtilities.transformedVertices` applies the sprite's
    /// POSED transform, and then the layer's mapper lifts the result out of the
    /// card's plane into scene world. Every one of those is affine and every
    /// one is constant for the sprite in this frame, so they fold in with the
    /// bone:
    ///
    ///     N = rigToWorld · spriteToRig · A · (world · inverseBind) · B
    ///
    /// and the shader goes from a bind vertex straight to a scene-world
    /// position with nothing in between. Verified exact to 1e-13 in
    /// `verify_scene_gpu_skinning.py`.
    ///
    /// `rigToWorld` LIFTS INTO THREE DIMENSIONS — `SceneLayer.liftToWorld`
    /// takes a plane point to a world one — so what the shader writes is a 3D
    /// point. Flattening it to z = 0 puts a rig 652 units out of place as soon
    /// as the camera leaves the front view.
    init(mesh: Mesh,
         boneOrder: [UUID],
         worldMatrices: [UUID: simd_float4x4],
         bindToWorld: simd_float4x4,
         worldToBind: simd_float4x4,
         spriteToRig: simd_float4x4,
         rigToWorld: simd_float4x4) {
        // Everything that happens AFTER the weighted sum, in one matrix. It is
        // pushed inside the sum, which is what makes normalised weights a
        // requirement rather than a nicety: each of these carries a
        // translation, and inside the sum each is counted once per influence.
        // With three of them the error compounds — measured at 1 343 units
        // against 700 for the sprite's affine alone.
        let after = rigToWorld * spriteToRig * worldToBind

        // A · I · B, which is the identity when the two are inverses — and is
        // written as the product rather than as `matrix_identity_float4x4` so
        // that a sprite whose bind pose is not exactly invertible degrades the
        // same way its bound vertices do, instead of snapping to the origin.
        matrices.append(after * bindToWorld)
        matrices.reserveCapacity(boneOrder.count + 1)

        for boneID in boneOrder {
            guard let world = worldMatrices[boneID],
                  let inverseBind = mesh.boneInverseBindMatrices[boneID]?.matrix
            else { continue }
            slots[boneID] = UInt16(matrices.count)
            matrices.append(after * (world * inverseBind) * bindToWorld)
        }
    }

    /// How many vertices had to give up an influence, over the whole sprite.
    ///
    /// COUNTED AND REPORTED, not swallowed. `Mesh.skinnedVertices` uses EVERY
    /// influence a vertex has; a vertex shader takes four. Every tool in the
    /// app already caps at four — `autoWeightMesh`, `skinImageToSkeleton`,
    /// `bindBoneToImage` and the weight brush all pass `maxInfluences: 4` — so
    /// this should be zero on anything painted here, and a mesh that arrives
    /// from somewhere else will not render identically to the CPU path.
    ///
    /// Measured in `verify_scene_gpu_skinning.py`: a fifth influence carrying
    /// 16% of a vertex's weight moves it 22.7 units on a 400×600 sprite. Small,
    /// bounded by the weight dropped, and not nothing — and staying quiet
    /// about it is what makes a renderer look broken rather than limited.
    private(set) var truncatedVertices = 0

    /// One vertex's influences, capped, normalised and padded to four.
    ///
    /// CAPPED BEFORE NORMALISING. The four that survive are renormalised
    /// between themselves, so they sum to one and the fold stays exact.
    /// Normalising first and then dropping the tail leaves the vertex short of
    /// its full weight, which pulls it towards its bind position — a slump
    /// exactly where a mesh is most finely painted. Measured at 38.3 units
    /// between the two orders on the same data.
    mutating func influences(for weights: [VertexBoneWeight]) -> SkinnedInfluences {
        var picked: [(slot: UInt16, weight: Float)] = []
        picked.reserveCapacity(Self.maximumInfluences)
        for influence in weights where influence.weight > 0 && influence.weight.isFinite {
            guard let slot = slots[influence.boneID] else { continue }
            picked.append((slot, influence.weight))
        }
        if picked.count > Self.maximumInfluences {
            truncatedVertices += 1
            // Largest first, and ties broken by SLOT rather than left to the
            // sort. Swift's sort is not stable, and the weights arrive from a
            // dictionary walk upstream, so equal weights could otherwise pick
            // different bones between runs of the same project.
            picked.sort { $0.weight == $1.weight ? $0.slot < $1.slot : $0.weight > $1.weight }
            picked = Array(picked.prefix(Self.maximumInfluences))
        }

        let total = picked.reduce(Float(0)) { $0 + $1.weight }
        guard total > 0.000001 else {
            return SkinnedInfluences(slots: SIMD4<UInt16>(repeating: Self.identitySlot),
                                     weights: SIMD4<Float>(1, 0, 0, 0))
        }
        var slotsOut = SIMD4<UInt16>(repeating: Self.identitySlot)
        var weightsOut = SIMD4<Float>(repeating: 0)
        for (index, entry) in picked.enumerated() {
            slotsOut[index] = entry.slot
            weightsOut[index] = entry.weight / total
        }
        return SkinnedInfluences(slots: slotsOut, weights: weightsOut)
    }
}

/// Four slots and four weights, summing to one.
struct SkinnedInfluences {
    var slots: SIMD4<UInt16>
    var weights: SIMD4<Float>
}
