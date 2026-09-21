import Metal
import simd

/// Builds arc vertex/index buffers for the skew gizmo.
/// Three arcs drawn like Unity rotation handle:
///   - Outer white ring:   full 360° ellipse (perspective foreshortened)
///   - Blue arc (shearX):  ~270° arc on the YZ plane, tilted by shearX
///   - Red arc  (shearY):  ~270° arc on the XZ plane, tilted by shearY
enum ArcGeometryBuilder {

    static let segmentsPerArc: Int = 128

    /// Packed vertex: [posX, posY, normX, normY, arcParam, arcIndex]
    typealias ArcVtx = (pos: SIMD2<Float>, norm: SIMD2<Float>,
                        param: Float, idx: UInt32)

    static func build(
        center:      SIMD2<Float>,
        outerRadius: Float,
        shearX:      Float,
        shearY:      Float,
        rotation:    Float,
        viewSize:    SIMD2<Float>
    ) -> (vertices: [ArcVtx], indices: [UInt16]) {

        var verts: [ArcVtx] = []
        var indices: [UInt16] = []

        let outerVerts = makeArc(
            center: center, radius: outerRadius,
            tilt: SIMD2(1.0, 0.92),
            startAngle: 0, endAngle: .pi * 2,
            arcIndex: 0,
            baseAngle: rotation
        )
        appendStrip(&verts, &indices, outerVerts)
        appendRulerTicks(
            &verts,
            &indices,
            center: center,
            baseRadius: outerRadius,
            tilt: SIMD2(1.0, 0.92),
            baseAngle: rotation,
            arcIndex: 0
        )

        let xArcAngle = rotation + shearX
        let xVerts = makeArc(
            center: center, radius: outerRadius * 0.97,
            tilt: SIMD2(sin(xArcAngle) * 0.4, 1.0),
            startAngle: .pi * 0.1, endAngle: .pi * 1.9,
            arcIndex: 1,
            baseAngle: rotation
        )
        appendStrip(&verts, &indices, xVerts)

        let yArcAngle = rotation + shearY
        let yVerts = makeArc(
            center: center, radius: outerRadius * 0.97,
            tilt: SIMD2(1.0, sin(yArcAngle) * 0.4),
            startAngle: .pi * 0.6, endAngle: .pi * 2.4,
            arcIndex: 2,
            baseAngle: rotation + .pi * 0.5
        )
        appendStrip(&verts, &indices, yVerts)

        return (verts, indices)
    }

    private static func makeArc(
        center: SIMD2<Float>, radius: Float,
        tilt: SIMD2<Float>,
        startAngle: Float, endAngle: Float,
        arcIndex: UInt32, baseAngle: Float
    ) -> [ArcVtx] {
        var result: [ArcVtx] = []
        let n = segmentsPerArc
        for i in 0...n {
            let t = Float(i) / Float(n)
            let angle = startAngle + (endAngle - startAngle) * t + baseAngle
            let unitX = cos(angle) * tilt.x
            let unitY = sin(angle) * tilt.y
            let pos = center + SIMD2(unitX, unitY) * radius
            let norm = normalize(SIMD2(unitX, unitY))
            result.append((pos, norm, t, arcIndex))
            result.append((pos, -norm, t, arcIndex))
        }
        return result
    }

    private static func appendStrip(
        _ verts: inout [ArcVtx], _ idx: inout [UInt16], _ strip: [ArcVtx]
    ) {
        let base = UInt16(verts.count)
        verts.append(contentsOf: strip)
        for i in 0..<UInt16(strip.count - 2) {
            idx.append(contentsOf: [base + i, base + i + 1, base + i + 2])
        }
    }

    private static func appendRulerTicks(
        _ verts: inout [ArcVtx],
        _ idx: inout [UInt16],
        center: SIMD2<Float>,
        baseRadius: Float,
        tilt: SIMD2<Float>,
        baseAngle: Float,
        arcIndex: UInt32
    ) {
        let tickCount = 36
        for i in 0..<tickCount {
            let t = Float(i) / Float(tickCount)
            let angle = baseAngle + t * (.pi * 2)
            let dir = SIMD2<Float>(cos(angle) * tilt.x, sin(angle) * tilt.y)
            let outward = simd_normalize(dir)
            let tickLength: Float = (i % 3 == 0) ? 12.0 : 7.0
            let tickWidth: Float = (i % 3 == 0) ? 2.8 : 1.8
            let start = center + outward * (baseRadius + 2.0)
            let end = center + outward * (baseRadius + 2.0 + tickLength)
            appendTickStrip(
                &verts,
                &idx,
                start: start,
                end: end,
                width: tickWidth,
                arcIndex: arcIndex
            )
        }
    }

    private static func appendTickStrip(
        _ verts: inout [ArcVtx],
        _ idx: inout [UInt16],
        start: SIMD2<Float>,
        end: SIMD2<Float>,
        width: Float,
        arcIndex: UInt32
    ) {
        let segment = end - start
        let length = simd_length(segment)
        guard length > 0.0001 else { return }
        let tangent = segment / length
        let normal = SIMD2<Float>(-tangent.y, tangent.x)
        let halfWidth = width * 0.5

        let v0: ArcVtx = (start + normal * halfWidth, normal, 0.0, arcIndex)
        let v1: ArcVtx = (start - normal * halfWidth, -normal, 0.0, arcIndex)
        let v2: ArcVtx = (end + normal * halfWidth, normal, 1.0, arcIndex)
        let v3: ArcVtx = (end - normal * halfWidth, -normal, 1.0, arcIndex)
        appendStrip(&verts, &idx, [v0, v1, v2, v3])
    }
}
