import Foundation
import simd

/// 2D Inverse Kinematics constraint. Drives a chain of bones so the tip of the
/// chain reaches the world-space tip of a target bone.
///
/// Supports:
///   - 1-bone chain (look-at)
///   - 2-bone chain (analytical, exact in one step)
///   - N-bone chain (FABRIK, iterative, stable in real time)
///   - Soft IK (damping near maximum reach to avoid popping)
///   - Stretch (extend bones beyond their authored length to reach far targets)
///   - Compress (let bones overlap and rotate to face very close targets)
///   - Uniform scaling (scale the whole chain together rather than per-bone)
///   - Bend direction (which side the elbow bends)
///   - Mix (blend strength)
///
/// Every property is a plain value, so animation tracks can drive any of them
/// — Phase 3 just adds new `AnimationTrackProperty` cases referencing the
/// constraint ID and field name.
struct IKConstraint: BoneConstraint, Identifiable, Equatable {

    let id: UUID
    var name: String
    var enabled: Bool
    var order: Int
    var mix: Float

    /// Bones from root to effector. The effector tip is what we try to put on
    /// the target. Must contain at least 1 bone.
    var boneChain: [UUID]

    /// The bone whose WORLD TIP position defines where the IK should reach.
    /// Using a bone as the target rather than a free-floating point is what lets
    /// the target itself be animated or parented.
    var targetBoneID: UUID

    /// Sign of the elbow bend for 2-bone IK. For N-bone FABRIK this acts as a
    /// preferred-side hint applied to the midpoint of the chain.
    var bendPositive: Bool

    /// If true and the target is unreachably far, stretch bones uniformly to reach.
    var stretch: Bool

    /// If true and the target is inside the natural reach, allow bones to compress
    /// (overlap) and still rotate to face the target.
    var compress: Bool

    /// If true, stretch/compress scale the entire chain uniformly. If false, the
    /// scale is split per-bone proportionally to their lengths.
    var uniformScale: Bool

    /// Soft-IK damping window in world units. When > 0, the chain asymptotically
    /// approaches but never quite reaches the target as the target moves outside
    /// `maxReach - softness`. Eliminates the snap that hard IK shows at the edge.
    var softness: Float

    init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        order: Int = 0,
        mix: Float = 1.0,
        boneChain: [UUID],
        targetBoneID: UUID,
        bendPositive: Bool = true,
        stretch: Bool = false,
        compress: Bool = false,
        uniformScale: Bool = false,
        softness: Float = 0
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.order = order
        self.mix = mix
        self.boneChain = boneChain
        self.targetBoneID = targetBoneID
        self.bendPositive = bendPositive
        self.stretch = stretch
        self.compress = compress
        self.uniformScale = uniformScale
        self.softness = softness
    }

    func apply(skeleton: Skeleton, worldMatrices: inout [UUID: simd_float4x4]) {
        IKSolver.solve(constraint: self, skeleton: skeleton, worldMatrices: &worldMatrices)
    }
}
