import Foundation
import simd

enum SkewGizmoHitTest {

    // Larger tolerance to make arc drag acquisition significantly easier.
    static let hitTolerance: Float = 16

    static func test(
        screenPt: SIMD2<Float>,
        center: SIMD2<Float>,
        outerRadius: Float,
        shearX: Float,
        shearY: Float,
        rotation: Float
    ) -> Int {

        let zDist = distToEllipse(
            pt: screenPt,
            center: center,
            radiusX: outerRadius,
            radiusY: outerRadius,
            rotation: 0
        )

        let xDist = distToEllipse(
            pt: screenPt,
            center: center,
            radiusX: outerRadius * 0.58,
            radiusY: outerRadius,
            rotation: 0
        )

        let yDist = distToEllipse(
            pt: screenPt,
            center: center,
            radiusX: outerRadius,
            radiusY: outerRadius * 0.58,
            rotation: 0
        )

        // Pick nearest arc under tolerance so hover/drag matches what user sees.
        var bestArc = 0
        var bestDistance = hitTolerance
        if xDist < bestDistance {
            bestDistance = xDist
            bestArc = 1
        }
        if yDist < bestDistance {
            bestDistance = yDist
            bestArc = 2
        }
        if zDist < bestDistance {
            bestDistance = zDist
            bestArc = 3
        }
        return bestArc
    }

    private static func distToEllipse(
        pt: SIMD2<Float>,
        center: SIMD2<Float>,
        radiusX: Float,
        radiusY: Float,
        rotation: Float
    ) -> Float {
        var minD: Float = .infinity
        let steps = 96
        for i in 0...steps {
            let t = Float(i) / Float(steps)
            let a = t * (.pi * 2)
            let local = SIMD2<Float>(cos(a) * radiusX, sin(a) * radiusY)
            let rotated = SIMD2<Float>(
                local.x * cos(rotation) - local.y * sin(rotation),
                local.x * sin(rotation) + local.y * cos(rotation)
            )
            let arcPt = center + rotated
            minD = min(minD, length(pt - arcPt))
        }
        return minD
    }
}
