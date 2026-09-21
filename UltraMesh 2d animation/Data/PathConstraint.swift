import Foundation
import simd

/// How the spacing between consecutive constrained bones is measured along the arc.
/// How a follower bone orients itself along the path.
///
/// Three rotate modes. `tangent` is the simple case; `chain`
/// and `chainScale` exist because a chain of bones following a path must stay
/// connected end to end, which pure per-bone tangent alignment does not
/// guarantee once the curve bends sharply.
enum PathRotateMode: String, Codable, CaseIterable, Equatable {
    /// Each bone points along the curve tangent at its own position.
    case tangent
    /// Each bone points at where the next bone landed, keeping the chain
    /// visually connected regardless of curvature.
    case chain
    /// Like `chain`, and additionally stretches each bone so it exactly spans
    /// the gap to the next one.
    case chainScale

    var title: String {
        switch self {
        case .tangent:    return "Tangent"
        case .chain:      return "Chain"
        case .chainScale: return "Chain Scale"
        }
    }
}

enum PathSpacingMode: String, Codable, CaseIterable, Equatable {
    /// World-unit distance between bone placement positions.
    case length
    /// Fraction of the total arc length (0–1 per gap).
    case percent
    /// Each bone's own authored length drives the step, so naturally-sized chains
    /// drape proportionally (a short bone takes less arc than a long one).
    case proportional
    /// Every follower sits at the same arc distance regardless of bone length
    /// or total path length: the spacing value is taken as-is, in world units,
    /// and is not rescaled when the path is edited.
    case fixed
}

/// Path Constraint. Places a chain of bones along a smooth Catmull-Rom spline whose
/// control points come from a second set of "path bones". Each follower bone is snapped
/// to an arc-length position on the spline and optionally rotated to align with the
/// tangent at that position.
///
/// Correspondence with the equivalent constraint in other 2D skeletal riggers,
/// for anyone porting a rig in or out:
///   pathBones   → path attachment vertices (world root positions become control points)
///   bones       → constrained bones list
///   positionMix → translate mix
///   rotateMix   → rotate mix
struct PathConstraint: BoneConstraint, Identifiable, Equatable {

    let id: UUID
    var name: String
    var enabled: Bool
    /// Lower order runs first, matching IKConstraint convention.
    var order: Int
    /// Master blend — multiplied into positionMix and rotateMix before applying.
    var mix: Float

    /// Bones whose world-root positions define the Catmull-Rom control points.
    /// Minimum 2 required for a valid spline.
    var pathBones: [UUID]

    /// Bones placed along the spline, ordered from path start toward path end.
    var bones: [UUID]

    /// Where on the path the first bone is placed. 0 = path start, 1 = path end.
    var position: Float

    /// Distance between consecutive bones along the arc.
    var spacing: Float

    /// How `spacing` is interpreted.
    var spacingMode: PathSpacingMode

    /// Blend strength: how strongly bones are translated to their path positions.
    var positionMix: Float

    /// Blend strength: how strongly bones rotate to face the path tangent.
    var rotateMix: Float

    /// Additional rotation (radians) applied on top of the tangent direction at every bone.
    var offsetRotation: Float

    /// Closed loop. Followers that run past the end wrap around to the start
    /// instead of piling up on the last control point.
    var closed: Bool

    /// Walk the path from the last control point to the first.
    var reversed: Bool

    /// How followers orient themselves along the curve.
    var rotateMode: PathRotateMode

    init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        order: Int = 0,
        mix: Float = 1.0,
        pathBones: [UUID],
        bones: [UUID],
        position: Float = 0.0,
        spacing: Float = 60.0,
        spacingMode: PathSpacingMode = .length,
        positionMix: Float = 1.0,
        rotateMix: Float = 1.0,
        offsetRotation: Float = 0.0,
        closed: Bool = false,
        reversed: Bool = false,
        rotateMode: PathRotateMode = .tangent
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.order = order
        self.mix = mix
        self.pathBones = pathBones
        self.bones = bones
        self.position = position
        self.spacing = spacing
        self.spacingMode = spacingMode
        self.positionMix = positionMix
        self.rotateMix = rotateMix
        self.offsetRotation = offsetRotation
        self.closed = closed
        self.reversed = reversed
        self.rotateMode = rotateMode
    }

    func apply(skeleton: Skeleton, worldMatrices: inout [UUID: simd_float4x4]) {
        PathSolver.solve(constraint: self, skeleton: skeleton, worldMatrices: &worldMatrices)
    }
}
