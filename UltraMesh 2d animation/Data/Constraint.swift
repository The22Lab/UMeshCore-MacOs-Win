import Foundation
import simd

/// Generic constraint contract. Every constraint type (IK, Transform, Path, Rotation, …)
/// conforms to this protocol so the skeleton can apply them uniformly.
///
/// Lifecycle:
///   1. Skeleton computes the unconstrained world matrix tree from local transforms.
///   2. For each enabled constraint, sorted by `order` ascending, `apply` mutates the
///      `worldMatrices` dictionary. The constraint is responsible for re-propagating
///      its changes to any descendant bones.
///   3. Downstream consumers (renderer, mesh deformer) read the final world matrices.
///
/// Constraints MUST NOT mutate the skeleton's local bone transforms — they operate
/// only on world-space matrices for the current evaluation pass. This keeps the
/// stored pose authored by the artist untouched, so animation curves and gizmo
/// drags remain the single source of truth.
protocol BoneConstraint {
    var id: UUID { get }
    var name: String { get set }
    var enabled: Bool { get set }
    /// Lower order runs first. Allows chaining (e.g. an IK solving a hand, then a
    /// rotation constraint snapping the wrist).
    var order: Int { get set }
    /// Blend strength 0…1 between unconstrained pose and the constraint's full effect.
    var mix: Float { get set }

    func apply(skeleton: Skeleton, worldMatrices: inout [UUID: simd_float4x4])
}

/// Utility used by every constraint type to recompute world matrices for the
/// descendants of an affected bone after the constraint has rewritten the bone's
/// world matrix. Keeping this in one place guarantees that all constraint types
/// propagate changes the same way.
enum ConstraintPropagation {

    /// Recompute world matrices for every descendant of `boneID` using the bone's
    /// existing local transform composed against the new parent world matrix.
    /// - Parameter skipping: a child subtree to leave alone. A solver that has
    ///   just written a world matrix for one of `boneID`'s children must skip
    ///   it, or this recomposes that child from its LOCAL transform and throws
    ///   the solved result away — which is exactly how two-bone IK ended up
    ///   producing a straight limb with no joint bend.
    static func cascade(
        from boneID: UUID,
        skipping skipID: UUID? = nil,
        skeleton: Skeleton,
        worldMatrices: inout [UUID: simd_float4x4]
    ) {
        // `childrenOf` scans every bone in the skeleton, and the recursion below
        // used to call it once per descendant — quadratic in bone count, for
        // every cascade, of every constraint, on every frame. One index built
        // here serves the whole walk.
        cascade(from: boneID, skipping: skipID, skeleton: skeleton,
                childrenByParent: skeleton.childrenIndexForPropagation(),
                worldMatrices: &worldMatrices)
    }

    /// Cascade against a children index the caller already built. A solver
    /// running several cascades in a row should build one and reuse it.
    static func cascade(
        from boneID: UUID,
        skipping skipID: UUID? = nil,
        skeleton: Skeleton,
        childrenByParent: [UUID: [UUID]],
        worldMatrices: inout [UUID: simd_float4x4]
    ) {
        guard let parentWorld = worldMatrices[boneID] else { return }
        guard let children = childrenByParent[boneID] else { return }
        for childID in children where childID != skipID {
            recompose(childID: childID, parentWorld: parentWorld, skeleton: skeleton,
                      childrenByParent: childrenByParent, worldMatrices: &worldMatrices)
        }
    }

    private static func recompose(
        childID: UUID,
        parentWorld: simd_float4x4,
        skeleton: Skeleton,
        childrenByParent: [UUID: [UUID]],
        worldMatrices: inout [UUID: simd_float4x4]
    ) {
        guard let bone = skeleton.bones[childID] else { return }
        let newWorld = parentWorld * bone.localTransform.matrix()
        worldMatrices[childID] = newWorld
        guard let grandchildren = childrenByParent[childID] else { return }
        for grandchildID in grandchildren {
            recompose(childID: grandchildID, parentWorld: newWorld, skeleton: skeleton,
                      childrenByParent: childrenByParent, worldMatrices: &worldMatrices)
        }
    }
}

/// Shortest signed angular delta from `from` to `to` in radians, in (-π, π].
/// Crucial for stable IK blending: prevents long-way-around rotations when
/// the target moves through the ±π boundary.
@inline(__always)
func shortestAngleDelta(from: Float, to: Float) -> Float {
    var delta = (to - from).truncatingRemainder(dividingBy: 2 * .pi)
    if delta > .pi { delta -= 2 * .pi }
    if delta < -.pi { delta += 2 * .pi }
    return delta
}
