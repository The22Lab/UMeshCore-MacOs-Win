import Foundation
import simd

/// Pure-function 2D IK solver. Operates on world matrices in place. No object state,
/// no allocations on the hot path beyond the chain-length scratch buffers in FABRIK.
///
/// All three solvers share the same input/output contract:
///   - Read each bone's current world matrix.
///   - Read each bone's `length` from the skeleton.
///   - Compute new world matrices that bring the chain's tip onto the target.
///   - Blend toward the new world matrices by `mix`.
///   - Propagate the change down to descendants via `ConstraintPropagation`.
enum IKSolver {

    /// Iteration cap for FABRIK. The algorithm converges in 4-6 passes for typical
    /// character rigs; 12 is generous for long whip-style chains.
    private static let fabrikMaxIterations = 12

    /// How far off colinear the chain's midpoint has to be before the bend
    /// hint stops helping. Also the hint's strength at exactly colinear, so
    /// the two ends of the ramp meet the old behaviour where it mattered.
    private static let bendHintReach: Float = 0.5

    static func solve(
        constraint: IKConstraint,
        skeleton: Skeleton,
        worldMatrices: inout [UUID: simd_float4x4]
    ) {
        guard constraint.enabled, constraint.mix > 0.0001 else { return }
        guard !constraint.boneChain.isEmpty else { return }
        guard let targetWorld = worldMatrices[constraint.targetBoneID],
              let targetBone = skeleton.bones[constraint.targetBoneID] else { return }

        // World-space position of the target bone's tip.
        let tipLocal3 = SIMD3<Float>(targetBone.length, 0, 0)
        let tipWorld3 = MatrixUtilities.transformPoint(tipLocal3, with: targetWorld)
        let target = SIMD2<Float>(tipWorld3.x, tipWorld3.y)
        let mix = max(0, min(1, constraint.mix))

        // Reject degenerate cases where the target bone is inside the chain — solving
        // would create cycles. Cheap O(n) check.
        if constraint.boneChain.contains(constraint.targetBoneID) { return }

        switch constraint.boneChain.count {
        case 1:
            solveOneBone(
                boneID: constraint.boneChain[0],
                target: target,
                mix: mix,
                skeleton: skeleton,
                worldMatrices: &worldMatrices
            )
        case 2:
            solveTwoBone(
                rootID: constraint.boneChain[0],
                tipID: constraint.boneChain[1],
                target: target,
                bendPositive: constraint.bendPositive,
                stretch: constraint.stretch,
                compress: constraint.compress,
                uniformScale: constraint.uniformScale,
                softness: constraint.softness,
                mix: mix,
                skeleton: skeleton,
                worldMatrices: &worldMatrices
            )
        default:
            solveFABRIK(
                chain: constraint.boneChain,
                target: target,
                bendPositive: constraint.bendPositive,
                stretch: constraint.stretch,
                compress: constraint.compress,
                softness: constraint.softness,
                mix: mix,
                skeleton: skeleton,
                worldMatrices: &worldMatrices
            )
        }
    }

    // MARK: - 1-bone solver (look-at)

    /// Rotate a single bone so its tip points at the target. Cheapest case —
    /// useful for things like eyes, weapon barrels, simple aim setups.
    private static func solveOneBone(
        boneID: UUID,
        target: SIMD2<Float>,
        mix: Float,
        skeleton: Skeleton,
        worldMatrices: inout [UUID: simd_float4x4]
    ) {
        guard let bone = skeleton.bones[boneID],
              let world = worldMatrices[boneID] else { return }

        let originW = MatrixUtilities.transformPoint(.zero, with: world)
        let origin = SIMD2<Float>(originW.x, originW.y)
        let toTarget = target - origin
        guard simd_length_squared(toTarget) > 0.000001 else { return }

        let tipW = MatrixUtilities.transformPoint(SIMD3<Float>(bone.length, 0, 0), with: world)
        let tip = SIMD2<Float>(tipW.x, tipW.y)
        let currentDir = tip - origin
        guard simd_length_squared(currentDir) > 0.000001 else { return }

        let currentAngle = atan2(currentDir.y, currentDir.x)
        let desiredAngle = atan2(toTarget.y, toTarget.x)
        let deltaAngle = shortestAngleDelta(from: currentAngle, to: desiredAngle) * mix

        let rotated = rotateMatrix(world, around: SIMD3<Float>(originW.x, originW.y, 0), byZ: deltaAngle)
        worldMatrices[boneID] = rotated
        ConstraintPropagation.cascade(from: boneID, skeleton: skeleton, worldMatrices: &worldMatrices)
    }

    // MARK: - 2-bone analytical solver

    /// Classic 2-bone IK via the law of cosines. Single closed-form evaluation,
    /// no iteration — the most reliable, fastest, and most production-ready
    /// case. This is the hot path for typical character rigs (arm, leg, etc.).
    private static func solveTwoBone(
        rootID: UUID,
        tipID: UUID,
        target rawTarget: SIMD2<Float>,
        bendPositive: Bool,
        stretch: Bool,
        compress: Bool,
        uniformScale: Bool,
        softness: Float,
        mix: Float,
        skeleton: Skeleton,
        worldMatrices: inout [UUID: simd_float4x4]
    ) {
        guard let rootBone = skeleton.bones[rootID],
              let tipBone = skeleton.bones[tipID],
              let rootWorld = worldMatrices[rootID],
              let tipWorld = worldMatrices[tipID] else { return }

        let rootOriginW = MatrixUtilities.transformPoint(.zero, with: rootWorld)
        let root = SIMD2<Float>(rootOriginW.x, rootOriginW.y)

        let l1 = rootBone.length
        let l2 = tipBone.length
        let maxReach = l1 + l2
        let minReach = abs(l1 - l2)

        // Apply soft-IK damping near maxReach. Smooth asymptotic clamp.
        let target = softenedTarget(target: rawTarget, origin: root, maxReach: maxReach, softness: softness)
        let toTarget = target - root
        let distance = simd_length(toTarget)

        // Determine effective bone lengths under stretch / compress.
        var effectiveL1 = l1
        var effectiveL2 = l2
        if distance > maxReach, stretch, maxReach > 0.0001 {
            let scale = distance / maxReach
            if uniformScale {
                effectiveL1 = l1 * scale
                effectiveL2 = l2 * scale
            } else {
                let split = scale
                effectiveL1 = l1 * split
                effectiveL2 = l2 * split
            }
        } else if distance < minReach, compress {
            // Compression: bones overlap. Treat as a 1-bone solve toward the target.
            let scale = distance / max(minReach, 0.0001)
            effectiveL1 = l1 * scale
            effectiveL2 = l2 * scale
        }

        // Clamp distance to the reachable annulus for the angle math.
        let effectiveMax = effectiveL1 + effectiveL2
        let effectiveMin = abs(effectiveL1 - effectiveL2)
        let solveD = max(effectiveMin + 0.0001, min(effectiveMax - 0.0001, distance))

        // Law of cosines.
        let alpha = atan2(toTarget.y, toTarget.x)
        let cosBeta = clamp(
            (effectiveL1 * effectiveL1 + solveD * solveD - effectiveL2 * effectiveL2)
            / (2 * effectiveL1 * solveD),
            -1, 1
        )
        let beta = acos(cosBeta)
        let bendSign: Float = bendPositive ? 1 : -1

        let rootDesiredAngle = alpha + beta * bendSign
        let cosGamma = clamp(
            (effectiveL1 * effectiveL1 + effectiveL2 * effectiveL2 - solveD * solveD)
            / (2 * effectiveL1 * effectiveL2),
            -1, 1
        )
        let gamma = acos(cosGamma)
        // The second bone turns back TOWARD the target, so its relative angle is
        // opposite in sign to the root's bend. With the same sign the chain is
        // reflected about the root bone and the tip lands nowhere near the
        // target — on a 200-unit leg it missed by up to 192 units, which is why
        // an arm or leg would not follow its IK handle at all.
        let tipRelativeAngle = -(.pi - gamma) * bendSign

        // Current world rotations of the two bones.
        let rootCurrentAngle = matrixRotationZ(rootWorld)
        let tipCurrentAngle = matrixRotationZ(tipWorld)
        let tipDesiredAngle = rootDesiredAngle + tipRelativeAngle

        let rootDelta = shortestAngleDelta(from: rootCurrentAngle, to: rootDesiredAngle) * mix
        let tipDelta = shortestAngleDelta(from: tipCurrentAngle, to: tipDesiredAngle) * mix

        // Rewrite world matrices: rotate root around root origin, then re-derive tip
        // world position as the end of the rotated root, then rotate tip around it.
        let newRootWorld = rotateMatrix(rootWorld, around: SIMD3<Float>(root.x, root.y, 0), byZ: rootDelta)
        worldMatrices[rootID] = newRootWorld

        // New origin of the tip bone is the end of root after rotation.
        let newRootTip3 = MatrixUtilities.transformPoint(SIMD3<Float>(effectiveL1, 0, 0), with: newRootWorld)
        let tipNewOrigin = SIMD2<Float>(newRootTip3.x, newRootTip3.y)

        // First reposition the tip's world matrix to the new origin (translation delta),
        // then rotate it around that origin by tipDelta.
        let tipOldOrigin3 = MatrixUtilities.transformPoint(.zero, with: tipWorld)
        let tipOldOrigin = SIMD2<Float>(tipOldOrigin3.x, tipOldOrigin3.y)
        let translation = SIMD3<Float>(tipNewOrigin.x - tipOldOrigin.x, tipNewOrigin.y - tipOldOrigin.y, 0)
        let translated = MatrixUtilities.translation(translation) * tipWorld
        let newTipWorld = rotateMatrix(translated, around: SIMD3<Float>(tipNewOrigin.x, tipNewOrigin.y, 0), byZ: tipDelta)
        worldMatrices[tipID] = newTipWorld

        // The tip is a child of the root, so cascading from the root would
        // recompose it from its local transform and discard the angle just
        // solved above. Skip it here; its own descendants (a foot, a hand) are
        // updated by the second cascade.
        let childrenByParent = skeleton.childrenIndexForPropagation()
        ConstraintPropagation.cascade(from: rootID, skipping: tipID, skeleton: skeleton,
                                      childrenByParent: childrenByParent, worldMatrices: &worldMatrices)
        ConstraintPropagation.cascade(from: tipID, skeleton: skeleton,
                                      childrenByParent: childrenByParent, worldMatrices: &worldMatrices)
    }

    // MARK: - N-bone FABRIK solver

    /// Forward And Backward Reaching Inverse Kinematics for chains of 3+ bones.
    /// Stable, real-time, no singularities. Each pass walks the chain twice
    /// (forward then backward) keeping bone-length constraints.
    private static func solveFABRIK(
        chain: [UUID],
        target rawTarget: SIMD2<Float>,
        bendPositive: Bool,
        stretch: Bool,
        compress: Bool,
        softness: Float,
        mix: Float,
        skeleton: Skeleton,
        worldMatrices: inout [UUID: simd_float4x4]
    ) {
        let n = chain.count
        guard n >= 2 else { return }

        // Pull bone lengths + current joint world positions into flat buffers.
        var lengths: [Float] = []
        lengths.reserveCapacity(n)
        var joints: [SIMD2<Float>] = []        // joint[i] = origin of bone[i]
        joints.reserveCapacity(n + 1)         // last entry is tip of final bone

        for boneID in chain {
            guard let bone = skeleton.bones[boneID],
                  let world = worldMatrices[boneID] else { return }
            let origin = MatrixUtilities.transformPoint(.zero, with: world)
            joints.append(SIMD2<Float>(origin.x, origin.y))
            lengths.append(bone.length)
        }
        guard let lastBone = skeleton.bones[chain.last!],
              let lastWorld = worldMatrices[chain.last!] else { return }
        let lastTip = MatrixUtilities.transformPoint(SIMD3<Float>(lastBone.length, 0, 0), with: lastWorld)
        joints.append(SIMD2<Float>(lastTip.x, lastTip.y))

        let rootPos = joints[0]
        let totalLength: Float = lengths.reduce(0, +)

        // Soft-IK damping on the target.
        let target = softenedTarget(target: rawTarget, origin: rootPos, maxReach: totalLength, softness: softness)
        let toTarget = target - rootPos
        let dist = simd_length(toTarget)

        // Unreachable & stretching: scale lengths so the chain just reaches.
        var workingLengths = lengths
        if dist > totalLength {
            if stretch, totalLength > 0.0001 {
                let scale = dist / totalLength
                for i in workingLengths.indices { workingLengths[i] *= scale }
            } else {
                // Saturated: lay the chain straight at the target direction.
                let dir = toTarget / max(dist, 0.0001)
                var cursor = rootPos
                joints[0] = cursor
                for i in 0..<n {
                    cursor += dir * lengths[i]
                    joints[i + 1] = cursor
                }
                writeBackJoints(chain: chain, joints: joints, mix: mix, skeleton: skeleton, worldMatrices: &worldMatrices)
                return
            }
        }

        if dist < 0.0001 {
            // Target at the root — nothing to solve.
            return
        }

        // Bend-direction hint: nudge the chain's midpoint perpendicular to the
        // line root→target before iterating, so FABRIK converges to the
        // preferred side rather than picking one arbitrarily when the chain is
        // colinear and the problem is genuinely symmetric.
        //
        // FADED IN, NOT SWITCHED ON. This used to be
        // `if abs(lateral) < 0.5 { joints[mid] += perp * 0.5 }` — all or
        // nothing. So as a limb straightened and `lateral` crossed 0.5, the
        // whole solution moved half a unit in a single frame, and moved back
        // as it bent again. That is a pop rather than a shimmer, and it landed
        // exactly at full extension: a kick, a punch, a reach. The most
        // visible moment in the animation.
        //
        // The nudge is strongest at colinear, where the symmetry actually
        // needs breaking, and reaches zero at the boundary so it joins the
        // un-nudged case continuously. `verify_motion_stability.py` measures
        // it: half a unit of output movement from an input that moved four
        // thousandths, against nothing measurable now.
        //
        // One behaviour difference, deliberately: a chain sitting slightly on
        // the NON-preferred side is nudged less than it used to be and keeps
        // its side instead of being flipped across. Half a unit of lateral
        // offset is colinear for any real limb, and flipping it is what the
        // step was doing every time it crossed.
        let mid = (n + 1) / 2
        if joints.count > mid {
            let along = toTarget / max(dist, 0.0001)
            let perp = SIMD2<Float>(-along.y, along.x) * (bendPositive ? 1 : -1)
            let toMid = joints[mid] - rootPos
            let lateral = toMid.x * perp.x + toMid.y * perp.y
            joints[mid] += perp * max(0, bendHintReach - abs(lateral))
        }

        // FABRIK iterations.
        for _ in 0..<fabrikMaxIterations {
            // Forward pass: place tip at target, drag joints back.
            joints[n] = target
            for i in (0..<n).reversed() {
                let dir = joints[i] - joints[i + 1]
                let length = simd_length(dir)
                guard length > 0.0001 else { continue }
                joints[i] = joints[i + 1] + (dir / length) * workingLengths[i]
            }
            // Backward pass: place root, push joints forward.
            joints[0] = rootPos
            for i in 0..<n {
                let dir = joints[i + 1] - joints[i]
                let length = simd_length(dir)
                guard length > 0.0001 else { continue }
                joints[i + 1] = joints[i] + (dir / length) * workingLengths[i]
            }
            // NO EARLY TERMINATION, deliberately.
            //
            // There used to be a `break` here when the tip came within 0.2
            // units of the target. It meant the solver ran between one and
            // twelve iterations depending on how hard that particular frame
            // was — and the residual after N iterations differs from the
            // residual after N+1 by a finite amount, so every change in the
            // count moved the solved chain. Measured over a target sweeping
            // smoothly away: four different iteration counts and a worst
            // one-frame jump of 0.12 units, from an input with no jump in it
            // at all.
            //
            // `evaluate(animationTime)` has to be a function of animationTime.
            // An iteration count that depends on the geometry makes it a
            // function of the geometry's difficulty as well, and that is what
            // a jittering IK chain is. A fixed count costs at most twelve
            // passes over the chain per constraint per frame — a few
            // normalisations each — and buys a solve that is continuous in the
            // target by construction.
        }

        // Compress: if target is unreachably close (target inside root area), the
        // last forward pass already produced a valid pose, nothing extra needed.
        _ = compress

        writeBackJoints(chain: chain, joints: joints, mix: mix, skeleton: skeleton, worldMatrices: &worldMatrices)
    }

    /// Convert solved joint positions back to per-bone world matrices and write
    /// into the matrices dictionary, blending by `mix`.
    private static func writeBackJoints(
        chain: [UUID],
        joints: [SIMD2<Float>],
        mix: Float,
        skeleton: Skeleton,
        worldMatrices: inout [UUID: simd_float4x4]
    ) {
        let childrenByParent = skeleton.childrenIndexForPropagation()
        for (i, boneID) in chain.enumerated() {
            guard let oldWorld = worldMatrices[boneID] else { continue }
            let oldOrigin3 = MatrixUtilities.transformPoint(.zero, with: oldWorld)
            let oldOrigin = SIMD2<Float>(oldOrigin3.x, oldOrigin3.y)
            let newOrigin = joints[i]
            let nextJoint = joints[i + 1]

            let dir = nextJoint - newOrigin
            guard simd_length_squared(dir) > 0.000001 else { continue }
            let desiredAngle = atan2(dir.y, dir.x)
            let currentAngle = matrixRotationZ(oldWorld)
            let deltaAngle = shortestAngleDelta(from: currentAngle, to: desiredAngle) * mix

            // Blend position by mix as well, so partial mix doesn't tear joints apart.
            let blendedOrigin = oldOrigin + (newOrigin - oldOrigin) * mix
            let translation = SIMD3<Float>(blendedOrigin.x - oldOrigin.x, blendedOrigin.y - oldOrigin.y, 0)
            let translated = MatrixUtilities.translation(translation) * oldWorld
            let rotated = rotateMatrix(
                translated,
                around: SIMD3<Float>(blendedOrigin.x, blendedOrigin.y, 0),
                byZ: deltaAngle
            )
            worldMatrices[boneID] = rotated
            ConstraintPropagation.cascade(from: boneID, skeleton: skeleton,
                                          childrenByParent: childrenByParent, worldMatrices: &worldMatrices)
        }
    }

    // MARK: - Math helpers

    /// Apply a soft-IK damping curve to the target relative to `origin`. When the
    /// raw target distance exceeds `maxReach - softness`, the effective target is
    /// pulled back along the line toward `origin` so the chain never fully extends.
    /// Result: smooth ease-out instead of a hard pop at the reach limit.
    private static func softenedTarget(
        target: SIMD2<Float>,
        origin: SIMD2<Float>,
        maxReach: Float,
        softness: Float
    ) -> SIMD2<Float> {
        guard softness > 0.0001, maxReach > 0.0001 else { return target }
        let toTarget = target - origin
        let distance = simd_length(toTarget)
        let softZone = maxReach - softness
        guard distance > softZone else { return target }
        let over = distance - softZone
        let damped = softness * (1.0 - exp(-over / max(softness, 0.0001)))
        let newDistance = softZone + damped
        let dir = toTarget / max(distance, 0.0001)
        return origin + dir * newDistance
    }

    /// Pre-multiply `matrix` by `R(angle)` around the world-space pivot `pivot`.
    /// Equivalent to `T(pivot) * R(angle) * T(-pivot) * matrix`.
    @inline(__always)
    private static func rotateMatrix(_ matrix: simd_float4x4, around pivot: SIMD3<Float>, byZ angle: Float) -> simd_float4x4 {
        if abs(angle) < 0.000001 { return matrix }
        let toOrigin = MatrixUtilities.translation(-pivot)
        let rot = MatrixUtilities.rotationZ(angle)
        let fromOrigin = MatrixUtilities.translation(pivot)
        return fromOrigin * rot * toOrigin * matrix
    }

    /// Extract the Z-axis rotation from a 2D transform matrix (assumes no scale
    /// shear — true for skeleton bones built by the existing code path).
    @inline(__always)
    private static func matrixRotationZ(_ matrix: simd_float4x4) -> Float {
        atan2(matrix.columns.0.y, matrix.columns.0.x)
    }

    @inline(__always)
    private static func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float {
        max(lo, min(hi, x))
    }
}
