import Foundation
import simd

/// Where a light's handles are, in WORLD space, and what a drag on one means.
///
/// Pure geometry: nothing here draws, and nothing here knows about SwiftUI or
/// about pixels. `SceneGizmoOverlay` projects what this returns and hit-tests
/// the result, exactly as it already does for a card's arrows — so a light's
/// handles foreshorten, lean and turn into ellipses for free, because that is
/// what a real projection does to a real direction.
///
/// ## The plane a flat visualisation lies in, and why it faces the camera
///
/// A point light's influence is a SPHERE — the attenuation is a 3D distance —
/// and the silhouette of a sphere is a circle facing the eye. So the ring is
/// drawn in the plane through the light whose normal is the view axis, which is
/// not a screen-space cheat but the correct world plane for that shape. Every
/// engine's point-light gizmo is this circle.
///
/// The same plane answers the drags, and the reason is a counting argument
/// rather than a preference. A pointer gives two numbers. A radius wants one
/// and a direction wants two, so the map from pointer to value is a bijection
/// only once the missing degree of freedom is pinned — and pinning it to the
/// plane the artist is looking at is what keeps the grabbed point under the
/// pointer. Pinning it anywhere else moves the handle away from the finger.
enum SceneLightGizmo {

    /// Which of a light's own handles this is.
    ///
    /// Deliberately NOT "scale". A light has no size to scale: it has a radius,
    /// a cone, a fade band. Scaling a light by a factor would be a control
    /// whose meaning nobody could state, so each quantity gets a handle that
    /// says what it changes.
    enum Handle: Hashable, CaseIterable {
        /// The outer edge of the light's influence.
        case radius
        /// Where the fade begins — the inner edge of the band `softness` sets.
        case softness
        /// The far end of the beam. Drag it to aim the light.
        case direction
        /// The cone's inner half-angle: full strength inside it.
        case innerAngle
        /// The cone's outer half-angle: nothing outside it.
        case outerAngle
    }

    /// The handles a kind of light actually has, in a FIXED order.
    ///
    /// Fixed because hit-testing walks it to break ties, and a tie broken by a
    /// Set's iteration order would grab a different handle on a different
    /// launch — `CLAUDE.md` names that failure and this is exactly it.
    static func handles(for kind: SceneLightKind) -> [Handle] {
        switch kind {
        case .point:
            return [.softness, .radius]
        case .spot:
            // Angles before radius: the two arcs sit ON the radius ring at the
            // cone's edge, so where they overlap the more specific handle wins.
            return [.innerAngle, .outerAngle, .softness, .radius, .direction]
        case .directional:
            // No position and no falloff — a direction and nothing else.
            return [.direction]
        }
    }

    /// Two orthonormal world vectors spanning the plane through the light that
    /// faces the camera.
    ///
    /// `u` is the camera's right and `v` its up, taken from the view matrix's
    /// own rows, so the frame IS the camera's and cannot drift from it.
    static func facingFrame(_ projection: SceneProjection) -> (u: SIMD3<Float>, v: SIMD3<Float>) {
        let view = projection.viewMatrix
        let right = SIMD3<Float>(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        let up = SIMD3<Float>(view.columns.0.y, view.columns.1.y, view.columns.2.y)
        let rl = simd_length(right), ul = simd_length(up)
        guard rl > 1e-6, ul > 1e-6 else {
            return (SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0))
        }
        return (right / rl, up / ul)
    }

    /// The camera's view axis, pointing away from the eye.
    static func viewAxis(_ projection: SceneProjection) -> SIMD3<Float> {
        let view = projection.viewMatrix
        let forward = SIMD3<Float>(view.columns.0.z, view.columns.1.z, view.columns.2.z)
        let length = simd_length(forward)
        return length > 1e-6 ? forward / length : SIMD3<Float>(0, 0, 1)
    }

    /// A circle of `radius` about the light, in the plane facing the camera.
    static func ring(centre: SIMD3<Float>, radius: Float,
                     frame: (u: SIMD3<Float>, v: SIMD3<Float>),
                     samples: Int = 64) -> [SIMD3<Float>] {
        guard radius > 0, samples >= 3 else { return [] }
        return (0...samples).map { index in
            let a = Float(index) / Float(samples) * 2 * .pi
            return centre + frame.u * (cos(a) * radius) + frame.v * (sin(a) * radius)
        }
    }

    /// The plane a spot's cone is DRAWN in: it contains the beam axis and is
    /// turned as far towards the camera as it can be.
    ///
    /// `u` is the component of the camera's right that is perpendicular to the
    /// axis. Seen down the beam that degenerates — every direction across the
    /// axis is equally side-on — and the fallback is any perpendicular, which
    /// is honest: there is no widest view of a cone pointing at you.
    static func conePlane(axis: SIMD3<Float>,
                          projection: SceneProjection) -> SIMD3<Float> {
        let right = facingFrame(projection).u
        var u = right - axis * simd_dot(right, axis)
        let length = simd_length(u)
        if length > 1e-4 {
            u /= length
        } else {
            u = SceneGizmoOverlay.ringFrame(normal: axis).u
        }
        return u
    }

    /// The two rim points of a cone of `halfAngle`, at `distance` from the
    /// light, in the cone's drawing plane.
    static func coneRim(centre: SIMD3<Float>, axis: SIMD3<Float>, across: SIMD3<Float>,
                        halfAngle: Float, distance: Float) -> (SIMD3<Float>, SIMD3<Float>) {
        let a = min(max(halfAngle, 0), .pi)
        let along = axis * (cos(a) * distance)
        let side = across * (sin(a) * distance)
        return (centre + along + side, centre + along - side)
    }

    /// An arc of the cone's rim, swept between the two rim points through the
    /// axis — the curve an artist reads as "the edge of the beam".
    static func coneArc(centre: SIMD3<Float>, axis: SIMD3<Float>, across: SIMD3<Float>,
                        halfAngle: Float, distance: Float, samples: Int = 24) -> [SIMD3<Float>] {
        let a = min(max(halfAngle, 0), .pi)
        guard distance > 0, samples >= 2 else { return [] }
        return (0...samples).map { index in
            let t = -a + 2 * a * Float(index) / Float(samples)
            return centre + axis * (cos(t) * distance) + across * (sin(t) * distance)
        }
    }

    /// Where a handle sits in the world.
    ///
    /// Nil when the light has no such handle — a directional light has no
    /// radius, and asking for one should give nothing rather than a number
    /// derived from something else.
    static func position(_ handle: Handle, light: SceneLight,
                         projection: SceneProjection,
                         directionLength: Float) -> SIMD3<Float>? {
        let centre = light.world
        let frame = facingFrame(projection)
        switch handle {
        case .radius:
            guard light.kind.isPositional, light.radius > 0 else { return nil }
            return centre + frame.u * light.radius
        case .softness:
            guard light.kind.isPositional, light.radius > 0 else { return nil }
            // On the inner edge of the band, and on the VERTICAL axis of the
            // ring so it can never sit on top of the radius handle however
            // small the band gets.
            return centre + frame.v * light.innerRadius
        case .direction:
            guard light.kind != .point else { return nil }
            return centre + light.direction * directionLength
        case .innerAngle, .outerAngle:
            guard light.kind == .spot, light.radius > 0 else { return nil }
            let across = conePlane(axis: light.direction, projection: projection)
            let angle = handle == .innerAngle ? light.innerAngle : light.outerAngle
            return coneRim(centre: centre, axis: light.direction, across: across,
                           halfAngle: angle, distance: light.radius).0
        }
    }

    // MARK: - What a drag means

    /// The radius a pointer is asking for: how far the ray's hit on the facing
    /// plane is from the light.
    ///
    /// A DISTANCE, not a delta. The handle is on the rim, so the rim goes where
    /// the pointer is and the grabbed point stays under it — which a delta
    /// added to the starting radius does not do once the camera is anywhere but
    /// square on.
    static func radius(forHit hit: SIMD3<Float>, centre: SIMD3<Float>) -> Float {
        max(simd_length(hit - centre), 0)
    }

    /// The cone half-angle a pointer is asking for: the angle between the beam
    /// axis and the ray's hit, measured at the light.
    ///
    /// Clamped to the half-turn a cone can span. Nil when the hit is at the
    /// light itself, where there is no angle to read.
    static func halfAngle(forHit hit: SIMD3<Float>, centre: SIMD3<Float>,
                          axis: SIMD3<Float>) -> Float? {
        let d = hit - centre
        let length = simd_length(d)
        guard length > 1e-5 else { return nil }
        let cosine = min(max(simd_dot(d / length, axis), -1), 1)
        return acos(cosine)
    }

    /// Point a light along a world direction, as azimuth and elevation.
    ///
    /// The exact inverse of `SceneLight.direction`, with the one case that has
    /// no inverse handled rather than left to produce a number.
    ///
    /// GIMBAL. A light pointing straight along Z has no azimuth: every azimuth
    /// gives the same direction, and `atan2(0, 0)` is 0. Taking that answer
    /// would silently snap the light's stored azimuth to zero, so that tilting
    /// it back out of the pole would swing it somewhere it was never pointed.
    /// The azimuth is left alone there instead, which makes aiming through the
    /// pole continuous.
    static func aim(_ light: inout SceneLight, along direction: SIMD3<Float>) {
        let length = simd_length(direction)
        guard length > 1e-6 else { return }
        let d = direction / length
        light.elevation = asin(min(max(d.z, -1), 1))
        let horizontal = simd_length(SIMD2<Float>(d.x, d.y))
        guard horizontal > 1e-5 else { return }
        light.azimuth = atan2(d.y, d.x)
    }

    /// Turn a light's direction about a world axis by an angle.
    ///
    /// Rodrigues, then back through `aim`. This is what the rotate rings do to
    /// a light: a light stores where it POINTS, not a full orientation, so a
    /// turn is applied to the direction vector and re-expressed — and a turn
    /// about the beam itself comes back as no change, which is correct, because
    /// a cone has nothing to roll.
    static func rotated(_ direction: SIMD3<Float>, about axis: SIMD3<Float>,
                        by angle: Float) -> SIMD3<Float> {
        let length = simd_length(axis)
        guard length > 1e-6 else { return direction }
        let k = axis / length
        let c = cos(angle), s = sin(angle)
        return direction * c
            + simd_cross(k, direction) * s
            + k * (simd_dot(k, direction) * (1 - c))
    }

    /// The softness a pointer is asking for, from where it put the inner edge.
    ///
    /// `softness` is the fraction of the radius the fade occupies, so the inner
    /// edge at distance `d` means `1 - d / radius`. Clamped to 0...1 at the
    /// point it is read, because a pointer dragged past the rim would otherwise
    /// ask for a negative band.
    static func softness(forHit hit: SIMD3<Float>, centre: SIMD3<Float>,
                         radius: Float) -> Float {
        guard radius > 1e-5 else { return 1 }
        let inner = simd_length(hit - centre)
        return min(max(1 - inner / radius, 0), 1)
    }
}
