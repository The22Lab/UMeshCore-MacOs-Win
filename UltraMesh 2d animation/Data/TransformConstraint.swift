import Foundation
import simd

/// 2D Transform Constraint. One or more "affected" bones copy world-space transform
/// components (position, rotation, scale, shear) from a single "target" bone, with
/// independent blend amounts and per-channel offsets.
///
/// Correspondence with the equivalent constraint in other 2D skeletal riggers,
/// for anyone porting a rig in or out:
///   - targetBoneID  → target bone
///   - affectedBones → constrained bones
///   - positionMix / rotationMix / scaleMix / shearMix → independent channel mixes
///   - mix           → master blend multiplied into every channel
///
/// All state is plain values, so every channel can be driven from animation curves
/// or driven externally. The solver is stateless and pure — safe to run in parallel
/// per evaluation pass.
struct TransformConstraint: BoneConstraint, Identifiable, Equatable {

    let id: UUID
    var name: String
    var enabled: Bool
    /// Lower order runs first. Default `50` so Transform Constraints evaluate after
    /// IK / Path (which use order 0…49 by convention) and before Physics (order ≥ 100).
    var order: Int
    /// Master blend strength, multiplied into every channel mix before applying.
    var mix: Float

    /// Source bone. Its current world matrix supplies the values to copy.
    var targetBoneID: UUID

    /// Bones receiving the copied transform components. A single constraint can
    /// drive any number of bones with the same target.
    var affectedBones: [UUID]

    var copyPosition: Bool
    var copyRotation: Bool
    var copyScale: Bool
    var copyShear: Bool

    /// Per-channel blend strength (0…1). Effective amount = mix × channelMix.
    var positionMix: Float
    var rotationMix: Float
    var scaleMix: Float
    var shearMix: Float

    /// Offsets added to the target's value before blending. Applied even when a
    /// channel is muted via channelMix = 0, so they always remain inert in that case.
    var offsetPositionX: Float
    var offsetPositionY: Float
    /// Radians.
    var offsetRotation: Float
    var offsetScaleX: Float
    var offsetScaleY: Float
    /// Radians.
    var offsetShear: Float

    init(
        id: UUID = UUID(),
        name: String,
        enabled: Bool = true,
        order: Int = 50,
        mix: Float = 1.0,
        targetBoneID: UUID,
        affectedBones: [UUID],
        copyPosition: Bool = false,
        copyRotation: Bool = true,
        copyScale: Bool = false,
        copyShear: Bool = false,
        positionMix: Float = 1.0,
        rotationMix: Float = 1.0,
        scaleMix: Float = 1.0,
        shearMix: Float = 1.0,
        offsetPositionX: Float = 0,
        offsetPositionY: Float = 0,
        offsetRotation: Float = 0,
        offsetScaleX: Float = 0,
        offsetScaleY: Float = 0,
        offsetShear: Float = 0
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.order = order
        self.mix = mix
        self.targetBoneID = targetBoneID
        self.affectedBones = affectedBones
        self.copyPosition = copyPosition
        self.copyRotation = copyRotation
        self.copyScale = copyScale
        self.copyShear = copyShear
        self.positionMix = positionMix
        self.rotationMix = rotationMix
        self.scaleMix = scaleMix
        self.shearMix = shearMix
        self.offsetPositionX = offsetPositionX
        self.offsetPositionY = offsetPositionY
        self.offsetRotation = offsetRotation
        self.offsetScaleX = offsetScaleX
        self.offsetScaleY = offsetScaleY
        self.offsetShear = offsetShear
    }

    func apply(skeleton: Skeleton, worldMatrices: inout [UUID: simd_float4x4]) {
        TransformConstraintSolver.solve(constraint: self, skeleton: skeleton, worldMatrices: &worldMatrices)
    }
}

/// Stateless solver for Transform Constraints. Pure functions, no allocations on the
/// hot path beyond a fixed-size decomposed-transform value.
enum TransformConstraintSolver {

    /// Decomposed 2D transform: T · Rz · Sk(skewX, skewY) · S(scaleX, scaleY).
    /// Matches `Transform3D2D.matrix()` composition order, so recomposing this
    /// reproduces the original matrix when shearY is zero (the usual convention).
    @usableFromInline
    struct Decomposed2D {
        var position: SIMD2<Float>
        /// Radians.
        var rotation: Float
        var scaleX: Float
        var scaleY: Float
        /// Shear X — angular deviation of the Y-axis from perpendicular,
        /// expressed in radians. Reconstructable from any affine 2D matrix.
        var skewX: Float
        /// Shear Y — only meaningful when explicitly composed, since
        /// matrix decomposition cannot separate it from `rotation` uniquely. Used
        /// during channel blending so `offsetShear` can drive a tilt on the X-axis
        /// frame; folded back into `rotation` if non-zero on recompose.
        var skewY: Float
    }

    static func solve(
        constraint: TransformConstraint,
        skeleton: Skeleton,
        worldMatrices: inout [UUID: simd_float4x4]
    ) {
        let masterMix = clamp01(constraint.mix)
        guard masterMix > 0.0001 else { return }
        guard skeleton.bones[constraint.targetBoneID] != nil,
              let targetMatrix = worldMatrices[constraint.targetBoneID] else { return }

        // Skip the (common) zero-work case — every channel either disabled or at zero mix.
        let pMix = constraint.copyPosition ? clamp01(constraint.positionMix) * masterMix : 0
        let rMix = constraint.copyRotation ? clamp01(constraint.rotationMix) * masterMix : 0
        let sMix = constraint.copyScale    ? clamp01(constraint.scaleMix)    * masterMix : 0
        let kMix = constraint.copyShear    ? clamp01(constraint.shearMix)    * masterMix : 0
        guard pMix + rMix + sMix + kMix > 0.0001 else { return }

        let target = decompose(targetMatrix)

        let childrenByParent = skeleton.childrenIndexForPropagation()
        for boneID in constraint.affectedBones {
            // Defensive: skip stale references (bone deleted while constraint still references it).
            guard skeleton.bones[boneID] != nil,
                  let currentMatrix = worldMatrices[boneID] else { continue }
            // Don't let a bone constrain itself — undefined and easy to misconfigure in UI.
            if boneID == constraint.targetBoneID { continue }

            var current = decompose(currentMatrix)

            if pMix > 0 {
                let tx = target.position.x + constraint.offsetPositionX
                let ty = target.position.y + constraint.offsetPositionY
                current.position.x += (tx - current.position.x) * pMix
                current.position.y += (ty - current.position.y) * pMix
            }

            if rMix > 0 {
                let targetRot = target.rotation + constraint.offsetRotation
                // Shortest-arc blend to avoid winding spins through ±π.
                let delta = shortestAngleDelta(from: current.rotation, to: targetRot)
                current.rotation += delta * rMix
            }

            if sMix > 0 {
                let tsx = target.scaleX + constraint.offsetScaleX
                let tsy = target.scaleY + constraint.offsetScaleY
                current.scaleX += (tsx - current.scaleX) * sMix
                current.scaleY += (tsy - current.scaleY) * sMix
            }

            if kMix > 0 {
                let targetSkew = target.skewX + constraint.offsetShear
                current.skewX += (targetSkew - current.skewX) * kMix
            }

            worldMatrices[boneID] = compose(current)
            ConstraintPropagation.cascade(from: boneID, skeleton: skeleton,
                                          childrenByParent: childrenByParent, worldMatrices: &worldMatrices)
        }
    }

    // MARK: - Decomposition / Composition

    /// Decompose a world matrix into its 2D components. Recovers position,
    /// Z-rotation, per-axis scale, and shear X (Y-axis deviation from perpendicular).
    /// Shear Y is folded into `rotation` since it cannot be recovered independently
    /// from a 2x2 matrix.
    @inline(__always)
    static func decompose(_ m: simd_float4x4) -> Decomposed2D {
        // World matrix composition is T * Rz * Sk * S → upper-left 2x2 holds rotation
        // * skew * scale; column 3 holds translation.
        let a = m.columns.0.x
        let b = m.columns.0.y
        let c = m.columns.1.x
        let d = m.columns.1.y
        let scaleX = sqrt(a * a + b * b)
        let rotation = atan2(b, a)
        // Express the Y-axis in a frame rotated by -rotation. With no skew the Y-axis
        // there is (0, scaleY); with skew X it becomes (scaleY · tan(skewX), scaleY).
        let cosR = cos(rotation)
        let sinR = sin(rotation)
        let yLocalX =  cosR * c + sinR * d
        let yLocalY = -sinR * c + cosR * d
        let scaleY = sqrt(yLocalX * yLocalX + yLocalY * yLocalY)
        // atan2(yLocalX, yLocalY) is the angle by which Y has departed from +90°
        // relative to X — i.e. shear X.
        let skewX = atan2(yLocalX, yLocalY)
        return Decomposed2D(
            position: SIMD2<Float>(m.columns.3.x, m.columns.3.y),
            rotation: rotation,
            scaleX: scaleX.isFinite ? scaleX : 1,
            scaleY: scaleY.isFinite ? scaleY : 1,
            skewX: skewX.isFinite ? skewX : 0,
            skewY: 0
        )
    }

    /// Recompose a Decomposed2D into a world matrix using the project's standard
    /// composition order (T · Rz · Sk · S). Delegates to `Transform3D2D.matrix()`
    /// for byte-identical behavior with the rest of the rig pipeline.
    @inline(__always)
    static func compose(_ d: Decomposed2D) -> simd_float4x4 {
        let xform = Transform3D2D(
            position: SIMD3<Float>(d.position.x, d.position.y, 0),
            rotation: SIMD3<Float>(0, 0, d.rotation),
            scale: SIMD3<Float>(d.scaleX, d.scaleY, 1),
            skew: SIMD2<Float>(d.skewX, d.skewY)
        )
        return xform.matrix()
    }

    @inline(__always)
    private static func clamp01(_ x: Float) -> Float {
        x < 0 ? 0 : (x > 1 ? 1 : x)
    }
}
