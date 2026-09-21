import Foundation
import CoreGraphics
import simd

/// Shear/skew math for the 2D sprite transform convention.
///
/// Shear is stored in degrees and applied as an angular deviation of each basis
/// axis, which is the convention the interchange formats for 2D skeletal rigs
/// use — so a rig round-trips through an export without a conversion step.
struct ShearTransform {
    var shearX: Float = 0   // degrees
    var shearY: Float = 0   // degrees

    /// Build a sheared transform matrix from decomposed components.
    func matrix(
        tx: Float, ty: Float,
        rotation: Float,    // degrees
        scaleX: Float, scaleY: Float
    ) -> float3x3 {
        let r = rotation * (.pi / 180)
        let sx = shearX * (.pi / 180)
        let sy = shearY * (.pi / 180)

        // X axis rotated by rotation + shearY
        let xAxis = SIMD2<Float>(cos(r + sy), sin(r + sy)) * scaleX
        // Y axis rotated by rotation + 90deg + shearX
        let yAxis = SIMD2<Float>(cos(r + .pi * 0.5 + sx), sin(r + .pi * 0.5 + sx)) * scaleY

        return float3x3(
            SIMD3(xAxis.x, xAxis.y, 0),
            SIMD3(yAxis.x, yAxis.y, 0),
            SIMD3(tx, ty, 1)
        )
    }

    /// Convert screen-space drag delta to shearX / shearY delta (degrees).
    static func dragDelta(
        screenDelta: SIMD2<Float>,
        zoom: Float,
        axis: ShearAxis,
        snapDegrees: Float? = nil
    ) -> Float {
        let raw: Float = axis == .shearX ? screenDelta.x : screenDelta.y
        var delta = raw / max(zoom, 0.05)
        if let snap = snapDegrees {
            delta = (delta / snap).rounded() * snap
        }
        return delta
    }
}

enum ShearAxis { case shearX, shearY, shearZ }

struct AngleBadge {
    let text:     String
    let position: CGPoint
    let color:    CGColor
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
