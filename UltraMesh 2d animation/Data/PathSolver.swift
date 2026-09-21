import Foundation
import simd

/// Pure Catmull-Rom path solver. Operates on world matrices in place with no external
/// state. The hot path allocates only the two scratch buffers built once per call:
/// the extended control-point list and the arc-length lookup table.
///
/// Algorithm:
///   1. Extract path control points from path-bone root positions.
///   2. Add phantom endpoints so the Catmull-Rom spline passes through the first/last point.
///   3. Walk 256 uniform parameter steps to build an arc-length → t table.
///   4. For each follower bone, binary-search the table for the target arc position,
///      evaluate (position, tangent), then blend translation and rotation by the mix values.
enum PathSolver {

    // MARK: - Entry Point

    static func solve(
        constraint: PathConstraint,
        skeleton: Skeleton,
        worldMatrices: inout [UUID: simd_float4x4]
    ) {
        guard constraint.enabled, constraint.mix > 0.0001 else { return }
        guard !constraint.bones.isEmpty, constraint.pathBones.count >= 2 else { return }

        // Collect world-space control points from path bones.
        var cp: [SIMD2<Float>] = []
        cp.reserveCapacity(constraint.pathBones.count)
        for bid in constraint.pathBones {
            guard let w = worldMatrices[bid] else { return }
            let o = MatrixUtilities.transformPoint(.zero, with: w)
            cp.append(SIMD2<Float>(o.x, o.y))
        }
        // Reversing the control points is enough to walk the curve backwards:
        // everything downstream is expressed in arc length along `cp`.
        if constraint.reversed { cp.reverse() }

        let closed = constraint.closed && cp.count >= 3
        let table = buildArcTable(cp: cp, samples: 256, closed: closed)
        guard let totalLen = table.last?.s, totalLen > 0.1 else { return }

        let effMix   = min(1, max(0, constraint.mix))
        let posMix   = min(1, max(0, constraint.positionMix)) * effMix
        let rotMix   = min(1, max(0, constraint.rotateMix))   * effMix
        let startArc = constraint.position * totalLen

        let spacingArc: Float
        switch constraint.spacingMode {
        case .length:       spacingArc = max(0, constraint.spacing)
        case .percent:      spacingArc = max(0, constraint.spacing) * totalLen
        case .proportional: spacingArc = max(0, constraint.spacing)
        case .fixed:        spacingArc = max(0, constraint.spacing)
        }

        // Pass 1 — where every follower lands.
        //
        // Chain rotate modes need to know the *next* bone's position before they
        // can orient the current one, so positions are resolved for the whole
        // chain first and rotation is applied afterwards.
        var targets: [(boneID: UUID, position: SIMD2<Float>, oldOrigin: SIMD2<Float>, tangent: SIMD2<Float>, old: simd_float4x4)] = []
        targets.reserveCapacity(constraint.bones.count)

        for (i, boneID) in constraint.bones.enumerated() {
            guard let oldW = worldMatrices[boneID] else { continue }

            let rawArc: Float
            if constraint.spacingMode == .proportional {
                let blen = skeleton.bones[boneID]?.length ?? spacingArc
                rawArc = startArc + Float(i) * blen
            } else {
                rawArc = startArc + Float(i) * spacingArc
            }

            // A closed path wraps instead of clamping, so a chain can run round
            // the loop indefinitely.
            let arc = closed
                ? wrapArc(rawArc, total: totalLen)
                : min(totalLen, max(0, rawArc))

            let t = arcToT(s: arc, table: table)
            let (pathPos, tangent) = eval(cp: cp, t: t, closed: closed)

            let oldO3 = MatrixUtilities.transformPoint(.zero, with: oldW)
            let oldO  = SIMD2<Float>(oldO3.x, oldO3.y)
            let newO  = oldO + (pathPos - oldO) * posMix

            targets.append((boneID, newO, oldO, tangent, oldW))
        }

        // Pass 2 — translate, orient, and optionally stretch.
        let childrenByParent = skeleton.childrenIndexForPropagation()
        for (index, target) in targets.enumerated() {
            let delta = target.position - target.oldOrigin
            var w = MatrixUtilities.translation(SIMD3<Float>(delta.x, delta.y, 0)) * target.old

            // Direction the bone should point in, by rotate mode.
            var aim: SIMD2<Float>? = nil
            switch constraint.rotateMode {
            case .tangent:
                aim = simd_length_squared(target.tangent) > 0.0001 ? target.tangent : nil
            case .chain, .chainScale:
                // Point at the next follower so the chain stays connected. The
                // last bone has no successor, so it falls back to the tangent.
                if index + 1 < targets.count {
                    let toNext = targets[index + 1].position - target.position
                    aim = simd_length_squared(toNext) > 0.0001 ? simd_normalize(toNext) : nil
                }
                if aim == nil, simd_length_squared(target.tangent) > 0.0001 {
                    aim = target.tangent
                }
            }

            if rotMix > 0.0001, let aim {
                let want  = atan2(aim.y, aim.x) + constraint.offsetRotation
                let cur      = rotZ(w)
                let rotDelta = shortestAngleDelta(from: cur, to: want) * rotMix
                if abs(rotDelta) > 0.0001 {
                    w = rotateAround(w, pivot: SIMD3<Float>(target.position.x, target.position.y, 0), angle: rotDelta)
                }
            }

            // Chain Scale additionally stretches the bone so it exactly spans
            // the gap to the next one, which is what keeps a segmented chain
            // gapless as the path stretches.
            if constraint.rotateMode == .chainScale,
               index + 1 < targets.count,
               let restLength = skeleton.bones[target.boneID]?.length,
               restLength > 0.0001 {
                let span = simd_distance(targets[index + 1].position, target.position)
                let factor = 1 + ((span / restLength) - 1) * effMix
                if factor.isFinite, factor > 0.0001, abs(factor - 1) > 0.0001 {
                    w = scaleAlongLocalX(w, pivot: SIMD3<Float>(target.position.x, target.position.y, 0), factor: factor)
                }
            }

            worldMatrices[target.boneID] = w
            ConstraintPropagation.cascade(from: target.boneID, skeleton: skeleton,
                                          childrenByParent: childrenByParent, worldMatrices: &worldMatrices)
        }
    }

    /// Fold an arc position into `0..<total`, handling negatives, so a closed
    /// path can be walked in either direction without bounds checks.
    @inline(__always)
    private static func wrapArc(_ s: Float, total: Float) -> Float {
        guard total > 0.0001 else { return 0 }
        let r = s.truncatingRemainder(dividingBy: total)
        return r < 0 ? r + total : r
    }

    /// Scale a world matrix along its own X axis about a pivot. Used by Chain
    /// Scale, where only the bone's length may change, not its thickness.
    private static func scaleAlongLocalX(
        _ m: simd_float4x4,
        pivot: SIMD3<Float>,
        factor: Float
    ) -> simd_float4x4 {
        var out = m
        out.columns.0 *= factor
        // Scaling the basis also moves the origin, so re-anchor it on the pivot.
        let movedOrigin = MatrixUtilities.transformPoint(.zero, with: out)
        let correction = MatrixUtilities.translation(
            SIMD3<Float>(pivot.x - movedOrigin.x, pivot.y - movedOrigin.y, 0)
        )
        return correction * out
    }

    // MARK: - Arc Length Table

    private struct ArcSample { var t: Float; var s: Float }

    private static func buildArcTable(cp: [SIMD2<Float>], samples: Int, closed: Bool) -> [ArcSample] {
        let pts  = addPhantoms(cp, closed: closed)
        let segN = pts.count - 3
        guard segN >= 1 else { return [] }

        let tMax = Float(segN)
        let step = tMax / Float(samples)
        var tbl: [ArcSample] = []
        tbl.reserveCapacity(samples + 1)

        var prev = evalDirect(pts: pts, t: 0)
        var cum: Float = 0
        tbl.append(ArcSample(t: 0, s: 0))

        for i in 1...samples {
            let t   = min(Float(i) * step, tMax)
            let pos = evalDirect(pts: pts, t: t)
            cum += simd_distance(pos, prev)
            tbl.append(ArcSample(t: t, s: cum))
            prev = pos
        }
        return tbl
    }

    private static func arcToT(s: Float, table: [ArcSample]) -> Float {
        guard table.count >= 2 else { return 0 }
        let total = table.last!.s
        guard total > 0.0001 else { return 0 }
        if s <= 0      { return table.first!.t }
        if s >= total  { return table.last!.t  }

        var lo = 0, hi = table.count - 1
        while lo + 1 < hi {
            let mid = (lo + hi) >> 1
            if table[mid].s < s { lo = mid } else { hi = mid }
        }
        let span = table[hi].s - table[lo].s
        guard span > 0.0001 else { return table[lo].t }
        let frac = (s - table[lo].s) / span
        return table[lo].t + frac * (table[hi].t - table[lo].t)
    }

    // MARK: - Catmull-Rom

    private static func eval(cp: [SIMD2<Float>], t: Float, closed: Bool) -> (SIMD2<Float>, SIMD2<Float>) {
        let pts  = addPhantoms(cp, closed: closed)
        let pos  = evalDirect(pts: pts, t: t)
        let tMax = Float(pts.count - 3)
        let eps: Float = 0.001
        let p1   = evalDirect(pts: pts, t: min(t + eps, tMax))
        let p0   = evalDirect(pts: pts, t: max(t - eps, 0))
        let diff = p1 - p0
        let tan: SIMD2<Float> = simd_length_squared(diff) > 1e-6
            ? simd_normalize(diff) : SIMD2<Float>(1, 0)
        return (pos, tan)
    }

    private static func evalDirect(pts: [SIMD2<Float>], t: Float) -> SIMD2<Float> {
        let n = pts.count - 3
        guard n >= 1 else { return pts.first ?? .zero }
        let seg = max(0, min(n - 1, Int(t)))
        return cr(pts[seg], pts[seg+1], pts[seg+2], pts[seg+3], t - Float(seg))
    }

    /// Extend the control points so the Catmull-Rom spline passes through the
    /// first and last of them.
    ///
    /// Open paths get mirrored phantom endpoints. Closed paths instead wrap:
    /// the point before the first is the last real point, and two points from
    /// the start are appended, which makes the final segment join back to the
    /// beginning with continuous curvature rather than a visible corner.
    private static func addPhantoms(_ pts: [SIMD2<Float>], closed: Bool) -> [SIMD2<Float>] {
        guard pts.count >= 2 else { return pts }
        if closed {
            return [pts[pts.count - 1]] + pts + [pts[0], pts[1]]
        }
        let a = pts[0]         + (pts[0]         - pts[1])         * 0.5
        let b = pts[pts.count-1] + (pts[pts.count-1] - pts[pts.count-2]) * 0.5
        return [a] + pts + [b]
    }

    @inline(__always)
    private static func cr(_ p0: SIMD2<Float>, _ p1: SIMD2<Float>,
                            _ p2: SIMD2<Float>, _ p3: SIMD2<Float>,
                            _ t: Float) -> SIMD2<Float> {
        let t2 = t * t
        let t3 = t2 * t
        let a: SIMD2<Float> = 2 * p1
        let b: SIMD2<Float> = (-p0 + p2) * t
        let c: SIMD2<Float> = (2*p0 - 5*p1 + 4*p2 - p3) * t2
        let d: SIMD2<Float> = (-p0 + 3*p1 - 3*p2 + p3) * t3
        return 0.5 * (a + b + c + d)
    }

    // MARK: - Math Helpers

    @inline(__always)
    private static func rotZ(_ m: simd_float4x4) -> Float {
        atan2(m.columns.0.y, m.columns.0.x)
    }

    @inline(__always)
    private static func rotateAround(_ m: simd_float4x4, pivot: SIMD3<Float>, angle: Float) -> simd_float4x4 {
        let toO = MatrixUtilities.translation(-pivot)
        let rot = MatrixUtilities.rotationZ(angle)
        let frO = MatrixUtilities.translation(pivot)
        return frO * rot * toO * m
    }
}
