import simd

/// Shared arc projection math for the 3D rotation gizmo.
enum ArcMath {

    /// The planes used for each arc.
    enum ArcPlane {
        case xz
        case yz
        case xy
    }

    /// Projects a world-space point onto screen space using a virtual camera.
    static func project(
        world: SIMD3<Float>,
        yaw: Float,
        pitch: Float,
        center: SIMD2<Float>,
        radius: Float
    ) -> (screen: SIMD2<Float>, depth: Float) {
        let camRight = simd_normalize(SIMD3<Float>(-sin(yaw), 0, cos(yaw)))
        let camUp = SIMD3<Float>(sin(pitch) * cos(yaw), cos(pitch), sin(pitch) * sin(yaw))
        let camForward = simd_normalize(simd_cross(camUp, camRight))

        let screenX = center.x + simd_dot(world, camRight) * radius
        let screenY = center.y - simd_dot(world, camUp) * radius
        let depth = simd_dot(world, camForward)
        return (SIMD2<Float>(screenX, screenY), depth)
    }

    /// Generates arc points for a plane and rotation.
    static func arcPoints(
        plane: ArcPlane,
        rotation: Float,
        center: SIMD2<Float>,
        radius: Float,
        yaw: Float,
        pitch: Float,
        samples: Int
    ) -> [(screen: SIMD2<Float>, depth: Float)] {
        let count = max(12, samples)
        var points: [(SIMD2<Float>, Float)] = []
        points.reserveCapacity(count + 1)

        for i in 0...count {
            let t = Float(i) / Float(count)
            let angle = t * Float.pi * 2
            var world: SIMD3<Float>
            switch plane {
            case .xz:
                world = SIMD3<Float>(cos(angle), 0, sin(angle))
                world = rotateAroundX(world, rotation)
            case .yz:
                world = SIMD3<Float>(0, cos(angle), sin(angle))
                world = rotateAroundY(world, rotation)
            case .xy:
                world = SIMD3<Float>(cos(angle), sin(angle), 0)
                world = rotateAroundZ(world, rotation)
            }
            let projected = project(world: world, yaw: yaw, pitch: pitch, center: center, radius: radius)
            points.append(projected)
        }

        return points
    }

    private static func rotateAroundX(_ v: SIMD3<Float>, _ radians: Float) -> SIMD3<Float> {
        let c = cos(radians)
        let s = sin(radians)
        return SIMD3<Float>(v.x, v.y * c - v.z * s, v.y * s + v.z * c)
    }

    private static func rotateAroundY(_ v: SIMD3<Float>, _ radians: Float) -> SIMD3<Float> {
        let c = cos(radians)
        let s = sin(radians)
        return SIMD3<Float>(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)
    }

    private static func rotateAroundZ(_ v: SIMD3<Float>, _ radians: Float) -> SIMD3<Float> {
        let c = cos(radians)
        let s = sin(radians)
        return SIMD3<Float>(v.x * c - v.y * s, v.x * s + v.y * c, v.z)
    }
}

// ✓ COMPLETE — ArcMath.swift
