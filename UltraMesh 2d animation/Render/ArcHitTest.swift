import simd

/// Result of a hit test against rotation arcs.
struct ArcHitResult {
    let arcIndex: Int
    let tangent: SIMD2<Float>
    let hitPoint: SIMD2<Float>
}

/// Hit-testing for the 3D rotation gizmo arcs.
enum ArcHitTest {

    static let tolerance: Float = 12.0
    static let samples: Int = 180

    static func test(
        screenPt: SIMD2<Float>,
        center: SIMD2<Float>,
        radius: Float,
        cameraYaw: Float,
        cameraPitch: Float,
        rotX: Float,
        rotY: Float,
        rotZ: Float
    ) -> ArcHitResult {
        let dist = simd_length(screenPt - center)
        if abs(dist - radius) < tolerance * 2 {
            return ArcHitResult(arcIndex: 4, tangent: SIMD2<Float>(1, 0), hitPoint: screenPt)
        }

        var best = ArcHitResult(arcIndex: 0, tangent: SIMD2<Float>(1, 0), hitPoint: screenPt)
        var bestDist = Float.greatestFiniteMagnitude

        let order: [(ArcMath.ArcPlane, Float, Int)] = [
            (.xy, rotZ, 3),
            (.yz, rotY, 2),
            (.xz, rotX, 1)
        ]

        for (plane, rotation, index) in order {
            let points = ArcMath.arcPoints(
                plane: plane,
                rotation: rotation,
                center: center,
                radius: radius,
                yaw: cameraYaw,
                pitch: cameraPitch,
                samples: samples
            )

            let (minDist, hitPoint, tangent) = closestOnArc(screenPt: screenPt, points: points)
            if minDist < bestDist {
                bestDist = minDist
                best = ArcHitResult(arcIndex: index, tangent: tangent, hitPoint: hitPoint)
            }
        }

        if bestDist < tolerance {
            return best
        }
        return ArcHitResult(arcIndex: 0, tangent: SIMD2<Float>(1, 0), hitPoint: screenPt)
    }

    private static func closestOnArc(
        screenPt: SIMD2<Float>,
        points: [(screen: SIMD2<Float>, depth: Float)]
    ) -> (Float, SIMD2<Float>, SIMD2<Float>) {
        var bestDist = Float.greatestFiniteMagnitude
        var bestPoint = screenPt
        var bestTangent = SIMD2<Float>(1, 0)

        for i in 1..<(points.count - 1) {
            if points[i].depth < 0 { continue }
            let a = points[i - 1].screen
            let b = points[i].screen
            let c = points[i + 1].screen
            let dist = distancePointToSegment(point: screenPt, a: a, b: b)
            if dist < bestDist {
                bestDist = dist
                bestPoint = b
                let tangent = simd_normalize(c - a)
                bestTangent = simd_length(tangent) > 0.001 ? tangent : SIMD2<Float>(1, 0)
            }
        }

        return (bestDist, bestPoint, bestTangent)
    }

    private static func distancePointToSegment(point: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>) -> Float {
        let ab = b - a
        let t = max(0, min(1, simd_dot(point - a, ab) / max(0.0001, simd_dot(ab, ab))))
        let proj = a + ab * t
        return simd_length(point - proj)
    }
}

// ✓ COMPLETE — ArcHitTest.swift
