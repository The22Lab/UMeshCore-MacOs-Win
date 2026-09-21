import Foundation
import simd

enum MatrixUtilities {
    static func identity() -> simd_float4x4 {
        matrix_float4x4(diagonal: SIMD4<Float>(1, 1, 1, 1))
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = identity()
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    static func scale(_ s: SIMD3<Float>) -> simd_float4x4 {
        var m = identity()
        m.columns.0.x = s.x
        m.columns.1.y = s.y
        m.columns.2.z = s.z
        return m
    }

    static func rotationX(_ radians: Float) -> simd_float4x4 {
        let c = cos(radians)
        let s = sin(radians)
        return simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, c, s, 0),
            SIMD4<Float>(0, -s, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    static func rotationY(_ radians: Float) -> simd_float4x4 {
        let c = cos(radians)
        let s = sin(radians)
        return simd_float4x4(columns: (
            SIMD4<Float>(c, 0, -s, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(s, 0, c, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    static func rotationZ(_ radians: Float) -> simd_float4x4 {
        let c = cos(radians)
        let s = sin(radians)
        return simd_float4x4(columns: (
            SIMD4<Float>(c, s, 0, 0),
            SIMD4<Float>(-s, c, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    static func skew(_ skew: SIMD2<Float>) -> simd_float4x4 {
        let sx = tan(skew.x)
        let sy = tan(skew.y)
        return simd_float4x4(columns: (
            SIMD4<Float>(1, sy, 0, 0),
            SIMD4<Float>(sx, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 0, 1)
        ))
    }

    /// Exact inverse of `shearedAxes`: recovers rotation / scale / skew from a
    /// pair of basis axes. `preservedSkewYDegrees` pins the skew.y component
    /// so the decomposition is unique and so a rigid composition reproduces
    /// the sprite's authored values bit-for-bit. Returns nil for degenerate
    /// (zero-length) axes.
    static func decomposeTransform(
        xAxis: SIMD2<Float>,
        yAxis: SIMD2<Float>,
        preservedSkewYDegrees: Float
    ) -> (rotationRadians: Float, scale: SIMD2<Float>, skewDegrees: SIMD2<Float>)? {
        let xLength = simd_length(xAxis)
        let yLength = simd_length(yAxis)
        guard xLength > 0.000001, yLength > 0.000001 else { return nil }
        let xAngleDeg = atan2(xAxis.y, xAxis.x) * 180 / Float.pi
        let yAngleDeg = atan2(yAxis.y, yAxis.x) * 180 / Float.pi
        let rotationDeg = xAngleDeg - preservedSkewYDegrees
        var skewX = yAngleDeg - 90 - rotationDeg
        skewX = skewX.truncatingRemainder(dividingBy: 360)
        if skewX > 180 { skewX -= 360 }
        if skewX <= -180 { skewX += 360 }
        return (
            rotationDeg * Float.pi / 180,
            SIMD2<Float>(xLength, yLength),
            SIMD2<Float>(skewX, preservedSkewYDegrees)
        )
    }

    static func perspective(m34: Float) -> simd_float4x4 {
        var m = identity()
        m.columns.2.w = m34
        return m
    }

    static func transformPoint(_ point: SIMD3<Float>, with matrix: simd_float4x4) -> SIMD3<Float> {
        let v = SIMD4<Float>(point.x, point.y, point.z, 1)
        let r = matrix * v
        let w = abs(r.w) < 0.0001 ? 1 : r.w
        return SIMD3<Float>(r.x / w, r.y / w, r.z / w)
    }

    /// The two world-space basis axes produced by a
    /// rotation + shear + scale (rotation and shear in degrees).
    /// This is the single source of truth for the sprite affine convention:
    /// every forward transform, inverse transform, and decomposition in the
    /// app derives from these axes so they can never drift apart.
    static func shearedAxes(
        rotationDegrees: Float,
        shear: SIMD2<Float>,
        scale: SIMD2<Float>
    ) -> (x: SIMD2<Float>, y: SIMD2<Float>) {
        let xAxisAngle = (rotationDegrees + shear.y) * (.pi / 180)
        let yAxisAngle = (rotationDegrees + 90 + shear.x) * (.pi / 180)
        let xAxis = SIMD2<Float>(cos(xAxisAngle), sin(xAxisAngle)) * scale.x
        let yAxis = SIMD2<Float>(cos(yAxisAngle), sin(yAxisAngle)) * scale.y
        return (xAxis, yAxis)
    }

    /// 2D shear transform for local points (degrees).
    static func shearedWorldTransform(
        local: SIMD2<Float>,
        position: SIMD2<Float>,
        rotation: Float,
        shear: SIMD2<Float>,
        scale: SIMD2<Float>
    ) -> SIMD2<Float> {
        let axes = shearedAxes(rotationDegrees: rotation, shear: shear, scale: scale)
        return position + axes.x * local.x + axes.y * local.y
    }

    /// Exact inverse of `shearedWorldTransform`: maps a world point back to the
    /// local space of a sprite pose. Returns .zero for degenerate (zero-area)
    /// transforms, mirroring the previous hit-testing behavior.
    static func shearedWorldInverse(
        world: SIMD2<Float>,
        position: SIMD2<Float>,
        rotation: Float,
        shear: SIMD2<Float>,
        scale: SIMD2<Float>
    ) -> SIMD2<Float> {
        let axes = shearedAxes(rotationDegrees: rotation, shear: shear, scale: scale)
        let relative = world - position
        let determinant = axes.x.x * axes.y.y - axes.x.y * axes.y.x
        guard abs(determinant) > 0.000001 else { return .zero }
        let invDeterminant = 1 / determinant
        return SIMD2<Float>(
            (relative.x * axes.y.y - relative.y * axes.y.x) * invDeterminant,
            (axes.x.x * relative.y - axes.x.y * relative.x) * invDeterminant
        )
    }

    /// `shearedWorldTransform` as a 4x4, for FOLDING rather than applying.
    ///
    /// Affine, not linear -- it sends (0,0) to `position` -- so the translation
    /// is a column of its own rather than something the basis images carry.
    ///
    /// SHEAR HERE IS AN ANGLE IN DEGREES, because `shearedAxes` adds it to an
    /// axis' direction. `SceneLayer.shear` is a raw SLOPE and goes through
    /// `SceneLayer.planePoint` instead. Both fields are spelled `shear`, both
    /// are `SIMD2<Float>`, and the two are not interchangeable: feeding one to
    /// the other's formula compiles, runs, and is invisible until something is
    /// actually sheared. Measured in `Editor/verify_scene_rig_geometry.py`.
    static func shearedMatrix(
        position: SIMD2<Float>,
        rotationDegrees: Float,
        shear: SIMD2<Float>,
        scale: SIMD2<Float>
    ) -> simd_float4x4 {
        let axes = shearedAxes(rotationDegrees: rotationDegrees, shear: shear, scale: scale)
        var m = identity()
        m.columns.0 = SIMD4<Float>(axes.x.x, axes.x.y, 0, 0)
        m.columns.1 = SIMD4<Float>(axes.y.x, axes.y.y, 0, 0)
        m.columns.3 = SIMD4<Float>(position.x, position.y, 0, 1)
        return m
    }

    /// The inverse of `shearedMatrix`, or nil when the basis encloses no area.
    ///
    /// NIL RATHER THAN A ZERO. `shearedWorldInverse` answers a degenerate
    /// transform with `.zero`, which is the honest answer to a point query and
    /// the wrong one for a fold: a palette built on it skins the entire sprite
    /// onto the origin, which reads as the artwork collapsing rather than as a
    /// sprite that could not be inverted. A caller that gets nil drops the
    /// sprite.
    static func shearedMatrixInverse(
        position: SIMD2<Float>,
        rotationDegrees: Float,
        shear: SIMD2<Float>,
        scale: SIMD2<Float>
    ) -> simd_float4x4? {
        let axes = shearedAxes(rotationDegrees: rotationDegrees, shear: shear, scale: scale)
        let determinant = axes.x.x * axes.y.y - axes.x.y * axes.y.x
        guard abs(determinant) > 0.000001 else { return nil }
        let inverse = 1 / determinant
        let m00 = axes.y.y * inverse
        let m01 = -axes.y.x * inverse
        let m10 = -axes.x.y * inverse
        let m11 = axes.x.x * inverse
        var m = identity()
        m.columns.0 = SIMD4<Float>(m00, m10, 0, 0)
        m.columns.1 = SIMD4<Float>(m01, m11, 0, 0)
        m.columns.3 = SIMD4<Float>(-(m00 * position.x + m01 * position.y),
                                   -(m10 * position.x + m11 * position.y),
                                   0, 1)
        return m
    }
}
