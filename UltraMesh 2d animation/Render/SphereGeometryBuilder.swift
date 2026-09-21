import simd

/// Builds arc geometry for the 3D rotation gizmo.
enum SphereGeometryBuilder {

    /// Packed vertex for arc strips.
    struct PackedArcVertex {
        var px: Float
        var py: Float
        var nx: Float
        var ny: Float
        var param: Float
        var index: UInt32
        var depth: Float
    }

    /// Builds vertex and index buffers for all arcs.
    static func build(
        center: SIMD2<Float>,
        radius: Float,
        cameraYaw: Float,
        cameraPitch: Float,
        rotX: Float,
        rotY: Float,
        rotZ: Float
    ) -> (vertices: [PackedArcVertex], indices: [UInt16]) {
        let segments = 160
        var vertices: [PackedArcVertex] = []
        var indices: [UInt16] = []

        let outer = makeArc(
            plane: .xy,
            rotation: 0,
            center: center,
            radius: radius,
            yaw: 0,
            pitch: 0,
            arcIndex: 0,
            samples: segments,
            forceFront: true
        )
        appendStrip(vertices: &vertices, indices: &indices, strip: outer)

        let green = makeArc(
            plane: .xz,
            rotation: rotX,
            center: center,
            radius: radius,
            yaw: cameraYaw,
            pitch: cameraPitch,
            arcIndex: 1,
            samples: segments,
            forceFront: false
        )
        appendStrip(vertices: &vertices, indices: &indices, strip: green)

        let blue = makeArc(
            plane: .yz,
            rotation: rotY,
            center: center,
            radius: radius,
            yaw: cameraYaw,
            pitch: cameraPitch,
            arcIndex: 2,
            samples: segments,
            forceFront: false
        )
        appendStrip(vertices: &vertices, indices: &indices, strip: blue)

        let red = makeArc(
            plane: .xy,
            rotation: rotZ,
            center: center,
            radius: radius,
            yaw: cameraYaw,
            pitch: cameraPitch,
            arcIndex: 3,
            samples: segments,
            forceFront: false
        )
        appendStrip(vertices: &vertices, indices: &indices, strip: red)

        return (vertices, indices)
    }

    private static func makeArc(
        plane: ArcMath.ArcPlane,
        rotation: Float,
        center: SIMD2<Float>,
        radius: Float,
        yaw: Float,
        pitch: Float,
        arcIndex: UInt32,
        samples: Int,
        forceFront: Bool
    ) -> [PackedArcVertex] {
        let points = ArcMath.arcPoints(
            plane: plane,
            rotation: rotation,
            center: center,
            radius: radius,
            yaw: yaw,
            pitch: pitch,
            samples: samples
        )
        var result: [PackedArcVertex] = []
        result.reserveCapacity(points.count * 2)

        for i in 0..<points.count {
            let t = Float(i) / Float(max(1, points.count - 1))
            let current = points[i]
            let prev = points[max(0, i - 1)].screen
            let next = points[min(points.count - 1, i + 1)].screen
            let tangent = simd_normalize(next - prev)
            let normal = simd_normalize(SIMD2<Float>(-tangent.y, tangent.x))
            let depth: Float = forceFront ? 0 : (current.depth > 0 ? 0 : 1)
            result.append(PackedArcVertex(px: current.screen.x, py: current.screen.y,
                                          nx: normal.x, ny: normal.y,
                                          param: t, index: arcIndex, depth: depth))
            result.append(PackedArcVertex(px: current.screen.x, py: current.screen.y,
                                          nx: -normal.x, ny: -normal.y,
                                          param: t, index: arcIndex, depth: depth))
        }
        return result
    }

    private static func appendStrip(
        vertices: inout [PackedArcVertex],
        indices: inout [UInt16],
        strip: [PackedArcVertex]
    ) {
        let base = UInt16(vertices.count)
        vertices.append(contentsOf: strip)
        for i in 0..<UInt16(strip.count - 2) {
            indices.append(contentsOf: [base + i, base + i + 1, base + i + 2])
        }
    }
}

// ✓ COMPLETE — SphereGeometryBuilder.swift
