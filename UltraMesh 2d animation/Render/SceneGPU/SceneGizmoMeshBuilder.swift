import Foundation
import simd

/// Turns a `SceneGizmoLayout` into triangles: shaded cones and cylinders for
/// the move/scale/shear arrows, tube-shaded tori for the rotate rings,
/// translucent quads for the plane handles. CPU, pure Swift, no Metal types —
/// `SceneMetalRenderer` uploads what this returns.
///
/// EVERYTHING IN WORLD SPACE. The vertex shader carries each vertex through
/// `SceneGizmoLayout.viewProjection` and slides it by `screenOffsetNDC`
/// itself; nothing here knows about the screen.
///
/// NO NEAR-PLANE CUTTING HERE, unlike `SceneGizmoOverlay.ringArcs`. That
/// function hand-rolls a cut because a SwiftUI `Canvas` stroke is a polyline
/// with no notion of clip-space clipping — a segment that crosses the near
/// plane has to be cut by hand or it closes the ring across the gap. A
/// triangle handed to the GPU has no such problem: Metal's rasteriser clips
/// every primitive against the view frustum, near plane included, exactly
/// and for free. Reproducing the CPU workaround here would be solving a
/// problem the hardware already solves, worse.
enum SceneGizmoMeshBuilder {

    // MARK: - Tuning

    /// Radial segments for a cylinder or cone's round cross-section. Low
    /// enough that a gizmo redrawn every frame costs nothing worth measuring,
    /// high enough that the facets do not read as facets at handle size.
    static let axisSides = 12
    /// Segments around the rotate ring's own circle, and around its tube.
    static let ringSegments = 64
    static let tubeSides = 10

    /// Fractions of `layout.scale` — the one world length every handle is
    /// built at — that lay out an arrow: most of the length is shaft, the
    /// rest is the head, and the head is visibly wider than the shaft the
    /// way every 3D editor's arrow is.
    ///
    /// GIRTH BUMPED UP FROM WHAT PURE PROPORTION WOULD GIVE, now that
    /// `SceneGizmoOverlay.handlePixels` is a quarter of what it was. Scaled
    /// down by the exact same factor as the length, a shaft's radius lands
    /// under a pixel on screen at ordinary zoom — a hairline that aliases
    /// away rather than a handle. These stay chunky enough to read at the new
    /// length; only the LENGTH is the 75% reduction that was asked for.
    static let shaftFraction: Float = 0.78
    static let shaftRadiusFraction: Float = 0.06
    static let headRadiusFraction: Float = 0.14
    static let cubeHalfExtentFraction: Float = 0.075
    static let tubeRadiusFraction: Float = 0.026
    static let planeQuadColorAlpha: Float = 0.5

    /// A highlighted handle reads thicker, not merely brighter — the same
    /// idea `SceneGizmoOverlay.litWidth` used to carry as a stroke width.
    static let highlightedThicknessScale: Float = 1.6

    /// A light's own diagram — sizes for its tubes and dots, as fractions of
    /// `layout.scale`, exactly like every other fraction above. `layout.scale`
    /// is built at the GIZMO'S ORIGIN, which for a light target IS the light
    /// (`SceneGizmoOverlay.basis(for: light).origin == light.world`), so it is
    /// already "how many world units make a constant number of pixels at
    /// THIS light's own depth" — the same screen-constant reference the axes
    /// use, reused rather than re-derived. The influence ring's and the
    /// cone's own RADIUS is not scaled by this at all: those come straight
    /// from the light's `radius`/`direction`, whatever size the artist set.
    static let lightTubeRadiusFraction: Float = 0.02
    static let lightHandleSphereRadiusFraction: Float = 0.06
    static let lightCentreSphereRadiusFraction: Float = 0.05
    static let lightBeamHeadRadiusFraction: Float = 0.09
    /// How much of the beam's own length its arrowhead occupies.
    static let lightBeamHeadLengthFraction: Float = 0.18

    // MARK: - Build

    static func build(_ layout: SceneGizmoLayout) -> [SceneGizmoVertexIn] {
        var vertices: [SceneGizmoVertexIn] = []

        // THE LIGHT'S DIAGRAM FIRST, UNDER THE MANIPULATOR — the same order
        // `drawLight` used to draw in, before it moved here: it says what the
        // light DOES, the arrows say what a drag would do, and a handle an
        // artist is reaching for should never be hidden behind a ring.
        if let light = layout.lightDiagram {
            vertices += lightDiagramMesh(light, scale: layout.scale)
        }

        // Planes, then axes, then rings — the same order
        // `SceneGizmoOverlay`'s old `draw(_:in:)` drew them in, so nearly
        // coincident translucent surfaces still read the way they used to.
        for (_, plane) in layout.planes.sorted(by: { $0.key.sortKey < $1.key.sortKey }) {
            vertices += planeMesh(plane, origin: layout.origin, scale: layout.scale)
        }
        for (_, axis) in layout.axes.sorted(by: { $0.key.sortKey < $1.key.sortKey }) {
            vertices += axisMesh(axis, origin: layout.origin, scale: layout.scale)
        }
        for (_, ring) in layout.rings.sorted(by: { $0.key.sortKey < $1.key.sortKey }) {
            vertices += ringMesh(ring, origin: layout.origin, scale: layout.scale)
        }
        if layout.showViewRing {
            vertices += viewRingMesh(layout)
        }
        if let center = layout.centerHandle {
            vertices += centerHandleMesh(center, layout: layout)
        }
        return vertices
    }

    /// The free-move / uniform-scale marker: a small cube at the origin,
    /// oriented off `layout.forward` since any orientation reads fine at this
    /// size — it is a dot, not a directional cue.
    private static func centerHandleMesh(_ center: SceneGizmoLayout.CenterHandle,
                                         layout: SceneGizmoLayout) -> [SceneGizmoVertexIn] {
        var color = center.color
        let thickness: Float = center.highlighted ? highlightedThicknessScale : 1
        color.w = center.highlighted ? 1 : 0.9
        return cube(center: layout.origin,
                   halfExtent: layout.scale * cubeHalfExtentFraction * 0.8 * thickness,
                   along: layout.forward, color: color)
    }

    // MARK: - Axis: shaft + head

    private static func axisMesh(_ axis: SceneGizmoLayout.AxisGeometry,
                                 origin: SIMD3<Float>, scale: Float) -> [SceneGizmoVertexIn] {
        let thickness: Float = axis.highlighted ? highlightedThicknessScale : 1
        var color = axis.color
        color.w *= axis.awayAlpha
        let direction = simd_normalize(axis.direction)

        let shaftLength = scale * shaftFraction
        let shaftEnd = origin + direction * shaftLength
        let tip = origin + direction * scale
        let shaftRadius = scale * shaftRadiusFraction * thickness
        let headRadius = scale * headRadiusFraction * thickness

        var vertices = cylinder(from: origin, to: shaftEnd, radius: shaftRadius,
                                sides: axisSides, color: color)
        switch axis.head {
        case .arrow:
            vertices += cone(base: shaftEnd, apex: tip, radius: headRadius,
                             sides: axisSides, color: color)
        case .cube:
            vertices += cube(center: tip, halfExtent: scale * cubeHalfExtentFraction * thickness,
                             along: direction, color: color)
        }
        return vertices
    }

    // MARK: - Ring: a tube-shaded torus

    private static func ringMesh(_ ring: SceneGizmoLayout.RingGeometry,
                                 origin: SIMD3<Float>, scale: Float) -> [SceneGizmoVertexIn] {
        let thickness: Float = ring.highlighted ? highlightedThicknessScale : 1
        var color = ring.color
        color.w *= ring.awayAlpha
        return torus(center: origin, normal: simd_normalize(ring.normal), radius: scale,
                    tubeRadius: scale * tubeRadiusFraction * thickness,
                    ringSegments: ringSegments, tubeSides: tubeSides, color: color)
    }

    /// The fourth ring: honestly screen-space, so it is built as a torus
    /// BILLBOARDED to face `layout.forward` — the gizmo camera's own view
    /// axis — rather than lying in any world plane. Sitting outside the three
    /// world rings (`SceneGizmoOverlay.viewRingScale`) so the two kinds never
    /// overlap.
    private static func viewRingMesh(_ layout: SceneGizmoLayout) -> [SceneGizmoVertexIn] {
        let color = layout.viewRingColor
        let thin = layout.scale * tubeRadiusFraction * 0.7
        return torus(center: layout.origin, normal: layout.forward,
                    radius: layout.scale * Float(SceneGizmoOverlay.viewRingScale),
                    tubeRadius: thin, ringSegments: ringSegments, tubeSides: tubeSides,
                    color: color)
    }

    // MARK: - Plane handle: a translucent quad

    private static func planeMesh(_ plane: SceneGizmoLayout.PlaneGeometry,
                                  origin: SIMD3<Float>, scale: Float) -> [SceneGizmoVertexIn] {
        let a = plane.a, b = plane.b
        let lo = SceneGizmoOverlay.planeOffset * scale
        let hi = (SceneGizmoOverlay.planeOffset + SceneGizmoOverlay.planeSize) * scale
        var color = plane.color
        color.w *= plane.highlighted ? 0.85 : planeQuadColorAlpha
        let normal = simd_normalize(simd_cross(a, b))
        let p00 = origin + a * lo + b * lo
        let p10 = origin + a * hi + b * lo
        let p11 = origin + a * hi + b * hi
        let p01 = origin + a * lo + b * hi
        func v(_ p: SIMD3<Float>) -> SceneGizmoVertexIn {
            SceneGizmoVertexIn(world: p, normal: normal, color: color)
        }
        // Both winding orders, so the quad reads the same lit from either
        // side — the gizmo pipeline draws with no back-face culling, but a
        // one-sided quad would still go dark from behind without this.
        return [v(p00), v(p10), v(p11), v(p00), v(p11), v(p01),
                v(p00), v(p11), v(p10), v(p00), v(p01), v(p11)]
    }

    // MARK: - A light's own diagram

    /// The counterpart to the old `drawLight(_:in:)`: the influence sphere
    /// (and where its fade starts), a spot's cone, the aim beam, and a small
    /// sphere at the light itself and at each of its own handles.
    ///
    /// TINTED WITH THE LIGHT'S OWN COLOUR, exactly as the SwiftUI version was
    /// — it is how an artist tells two lights apart at a glance without
    /// reading a label, and it is why this never reaches for
    /// `SceneGizmoOverlay.axisColor(_:)`: that palette means X, Y and Z, and
    /// chrome borrowing it would be claiming to be an axis.
    private static func lightDiagramMesh(_ diagram: SceneGizmoLayout.LightDiagram,
                                         scale: Float) -> [SceneGizmoVertexIn] {
        var vertices: [SceneGizmoVertexIn] = []
        // A disabled light reads in a flatter, dimmer version of its own
        // colour — present, placeable, visibly off — the same reading
        // `drawLight` gave it by mixing `light.colour` down towards white.
        let dim: Float = diagram.isEnabled ? 1 : 0.55
        func tinted(_ alpha: Float) -> SIMD4<Float> {
            SIMD4<Float>(diagram.tint.x, diagram.tint.y, diagram.tint.z, alpha * dim)
        }

        let tubeRadius = scale * lightTubeRadiusFraction

        // The band between the inner edge and the rim is where the light
        // fades, so the rim is drawn at full strength and the inner edge
        // thinner and dimmer — one is where the light ends, the other is
        // where it starts to go.
        if diagram.influenceRadius > 0 {
            vertices += torus(center: diagram.centre, normal: diagram.viewAxis,
                              radius: diagram.influenceRadius, tubeRadius: tubeRadius,
                              ringSegments: ringSegments, tubeSides: tubeSides,
                              color: tinted(0.6))
        }
        if diagram.innerRadius > 0 {
            vertices += torus(center: diagram.centre, normal: diagram.viewAxis,
                              radius: diagram.innerRadius, tubeRadius: tubeRadius * 0.7,
                              ringSegments: ringSegments, tubeSides: tubeSides,
                              color: tinted(0.32))
        }
        for edge in diagram.outerEdges {
            vertices += cylinder(from: edge.0, to: edge.1, radius: tubeRadius,
                                 sides: tubeSides, color: tinted(0.6))
        }
        for edge in diagram.innerEdges {
            vertices += cylinder(from: edge.0, to: edge.1, radius: tubeRadius * 0.7,
                                 sides: tubeSides, color: tinted(0.32))
        }
        vertices += tubeAlongPolyline(diagram.outerArc, radius: tubeRadius,
                                      sides: tubeSides, color: tinted(0.6))
        vertices += tubeAlongPolyline(diagram.innerArc, radius: tubeRadius * 0.7,
                                      sides: tubeSides, color: tinted(0.32))

        // The beam: a shaft plus an arrowhead, so it reads as a direction
        // rather than a radius that happens to be drawn as a line.
        if let beam = diagram.beam {
            let span = beam.1 - beam.0
            let shaftEnd = beam.0 + span * (1 - lightBeamHeadLengthFraction)
            vertices += cylinder(from: beam.0, to: shaftEnd, radius: tubeRadius,
                                 sides: tubeSides, color: tinted(0.95))
            vertices += cone(base: shaftEnd, apex: beam.1,
                             radius: scale * lightBeamHeadRadiusFraction,
                             sides: tubeSides, color: tinted(0.95))
        }

        // The light itself, drawn LAST of the chrome so the cone's edges,
        // which all meet here, sit behind it rather than poking through it.
        vertices += sphere(center: diagram.centre,
                           radius: scale * lightCentreSphereRadiusFraction,
                           color: tinted(0.95))

        for handle in diagram.handles {
            let thickness: Float = handle.highlighted ? highlightedThicknessScale : 1
            vertices += sphere(center: handle.position,
                               radius: scale * lightHandleSphereRadiusFraction * thickness,
                               color: tinted(handle.highlighted ? 1 : 0.85))
        }
        return vertices
    }

    /// A tube of constant radius following a polyline — one cylinder segment
    /// per pair of consecutive points. Used for a cone's rim arc, which is a
    /// genuine partial circle and so cannot reuse `torus`, built for a full one.
    private static func tubeAlongPolyline(_ points: [SIMD3<Float>], radius: Float, sides: Int,
                                          color: SIMD4<Float>) -> [SceneGizmoVertexIn] {
        guard points.count >= 2 else { return [] }
        var vertices: [SceneGizmoVertexIn] = []
        for i in 0..<(points.count - 1) {
            vertices += cylinder(from: points[i], to: points[i + 1], radius: radius,
                                 sides: sides, color: color)
        }
        return vertices
    }

    // MARK: - Primitives

    /// A round tube between two points, radial normals, no caps — the shaft
    /// meets its head or the origin square, and neither end is ever seen.
    private static func cylinder(from base: SIMD3<Float>, to tip: SIMD3<Float>,
                                 radius: Float, sides: Int,
                                 color: SIMD4<Float>) -> [SceneGizmoVertexIn] {
        let axis = tip - base
        let length = simd_length(axis)
        guard length > 1e-6, radius > 1e-6 else { return [] }
        let dir = axis / length
        let (u, v) = SceneGizmoOverlay.ringFrame(normal: dir)

        var vertices: [SceneGizmoVertexIn] = []
        vertices.reserveCapacity(sides * 6)
        for i in 0..<sides {
            let a0 = Float(i) / Float(sides) * 2 * .pi
            let a1 = Float(i + 1) / Float(sides) * 2 * .pi
            let n0 = u * cos(a0) + v * sin(a0)
            let n1 = u * cos(a1) + v * sin(a1)
            let b0 = base + n0 * radius, b1 = base + n1 * radius
            let t0 = tip + n0 * radius, t1 = tip + n1 * radius
            vertices.append(SceneGizmoVertexIn(world: b0, normal: n0, color: color))
            vertices.append(SceneGizmoVertexIn(world: b1, normal: n1, color: color))
            vertices.append(SceneGizmoVertexIn(world: t0, normal: n0, color: color))
            vertices.append(SceneGizmoVertexIn(world: b1, normal: n1, color: color))
            vertices.append(SceneGizmoVertexIn(world: t1, normal: n1, color: color))
            vertices.append(SceneGizmoVertexIn(world: t0, normal: n0, color: color))
        }
        return vertices
    }

    /// An arrowhead: a base ring, capped, coming to a point.
    private static func cone(base: SIMD3<Float>, apex: SIMD3<Float>, radius: Float,
                             sides: Int, color: SIMD4<Float>) -> [SceneGizmoVertexIn] {
        let axis = apex - base
        let length = simd_length(axis)
        guard length > 1e-6, radius > 1e-6 else { return [] }
        let dir = axis / length
        let (u, v) = SceneGizmoOverlay.ringFrame(normal: dir)

        var vertices: [SceneGizmoVertexIn] = []
        vertices.reserveCapacity(sides * 6)
        for i in 0..<sides {
            let a0 = Float(i) / Float(sides) * 2 * .pi
            let a1 = Float(i + 1) / Float(sides) * 2 * .pi
            let n0 = u * cos(a0) + v * sin(a0)
            let n1 = u * cos(a1) + v * sin(a1)
            let p0 = base + n0 * radius, p1 = base + n1 * radius
            // Side face: normals tilted a little toward the apex direction so
            // the cone shades as a cone rather than a flat-sided fan — a
            // cheap stand-in for the true slant normal.
            let side0 = simd_normalize(n0 + dir * 0.35)
            let side1 = simd_normalize(n1 + dir * 0.35)
            let apexNormal = simd_normalize(simd_normalize(n0 + n1) + dir * 0.35)
            vertices.append(SceneGizmoVertexIn(world: p0, normal: side0, color: color))
            vertices.append(SceneGizmoVertexIn(world: p1, normal: side1, color: color))
            vertices.append(SceneGizmoVertexIn(world: apex, normal: apexNormal, color: color))
            // The base cap, so the head does not read as hollow from the side.
            vertices.append(SceneGizmoVertexIn(world: base, normal: -dir, color: color))
            vertices.append(SceneGizmoVertexIn(world: p1, normal: -dir, color: color))
            vertices.append(SceneGizmoVertexIn(world: p0, normal: -dir, color: color))
        }
        return vertices
    }

    /// A small cube centred at `center`, aligned to `along` — the scale/shear
    /// cap. Six faces, flat-shaded, each its own four corners.
    private static func cube(center: SIMD3<Float>, halfExtent: Float,
                             along: SIMD3<Float>, color: SIMD4<Float>) -> [SceneGizmoVertexIn] {
        guard halfExtent > 1e-6 else { return [] }
        let (u, v) = SceneGizmoOverlay.ringFrame(normal: along)
        let axes: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (along, u, v), (-along, u, -v), (u, v, along),
            (-u, v, -along), (v, along, u), (-v, along, -u),
        ]
        var vertices: [SceneGizmoVertexIn] = []
        vertices.reserveCapacity(axes.count * 6)
        for (normal, right, up) in axes {
            let face = center + normal * halfExtent
            let p00 = face - right * halfExtent - up * halfExtent
            let p10 = face + right * halfExtent - up * halfExtent
            let p11 = face + right * halfExtent + up * halfExtent
            let p01 = face - right * halfExtent + up * halfExtent
            func vtx(_ p: SIMD3<Float>) -> SceneGizmoVertexIn {
                SceneGizmoVertexIn(world: p, normal: normal, color: color)
            }
            vertices.append(vtx(p00)); vertices.append(vtx(p10)); vertices.append(vtx(p11))
            vertices.append(vtx(p00)); vertices.append(vtx(p11)); vertices.append(vtx(p01))
        }
        return vertices
    }

    /// A torus: a circle of `radius` swept by a tube of `tubeRadius`, in the
    /// plane whose normal is `normal`.
    private static func torus(center: SIMD3<Float>, normal: SIMD3<Float>, radius: Float,
                              tubeRadius: Float, ringSegments: Int, tubeSides: Int,
                              color: SIMD4<Float>) -> [SceneGizmoVertexIn] {
        guard radius > 1e-6, tubeRadius > 1e-6 else { return [] }
        let (u, v) = SceneGizmoOverlay.ringFrame(normal: normal)

        func radial(_ angle: Float) -> SIMD3<Float> { u * cos(angle) + v * sin(angle) }
        func ringPoint(_ radialDir: SIMD3<Float>) -> SIMD3<Float> { center + radialDir * radius }
        func tubePoint(_ ringCenter: SIMD3<Float>, _ radialDir: SIMD3<Float>,
                       _ phase: Float) -> (SIMD3<Float>, SIMD3<Float>) {
            let n = radialDir * cos(phase) + normal * sin(phase)
            return (ringCenter + n * tubeRadius, n)
        }

        var vertices: [SceneGizmoVertexIn] = []
        vertices.reserveCapacity(ringSegments * tubeSides * 6)
        for i in 0..<ringSegments {
            let t0 = Float(i) / Float(ringSegments) * 2 * .pi
            let t1 = Float(i + 1) / Float(ringSegments) * 2 * .pi
            let radial0 = radial(t0), radial1 = radial(t1)
            let c0 = ringPoint(radial0), c1 = ringPoint(radial1)
            for j in 0..<tubeSides {
                let p0 = Float(j) / Float(tubeSides) * 2 * .pi
                let p1 = Float(j + 1) / Float(tubeSides) * 2 * .pi
                let (a0, n0) = tubePoint(c0, radial0, p0)
                let (a1, n1) = tubePoint(c0, radial0, p1)
                let (b0, m0) = tubePoint(c1, radial1, p0)
                let (b1, m1) = tubePoint(c1, radial1, p1)
                vertices.append(SceneGizmoVertexIn(world: a0, normal: n0, color: color))
                vertices.append(SceneGizmoVertexIn(world: b0, normal: m0, color: color))
                vertices.append(SceneGizmoVertexIn(world: a1, normal: n1, color: color))
                vertices.append(SceneGizmoVertexIn(world: b0, normal: m0, color: color))
                vertices.append(SceneGizmoVertexIn(world: b1, normal: m1, color: color))
                vertices.append(SceneGizmoVertexIn(world: a1, normal: n1, color: color))
            }
        }
        return vertices
    }

    /// A low-poly UV sphere — the light's own centre marker and its handle
    /// dots. Rotationally symmetric, so unlike every other primitive here it
    /// needs no `(u, v)` frame derived from a direction: the poles are just
    /// `(0, 1, 0)`, and nothing about a sphere cares which way that points.
    private static func sphere(center: SIMD3<Float>, radius: Float,
                               latSegments: Int = 6, lonSegments: Int = 10,
                               color: SIMD4<Float>) -> [SceneGizmoVertexIn] {
        guard radius > 1e-6 else { return [] }
        func point(_ lat: Int, _ lon: Int) -> (SIMD3<Float>, SIMD3<Float>) {
            let theta = Float(lat) / Float(latSegments) * .pi
            let phi = Float(lon) / Float(lonSegments) * 2 * .pi
            let n = SIMD3<Float>(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
            return (center + n * radius, n)
        }
        var vertices: [SceneGizmoVertexIn] = []
        vertices.reserveCapacity(latSegments * lonSegments * 6)
        for lat in 0..<latSegments {
            for lon in 0..<lonSegments {
                let (p00, n00) = point(lat, lon)
                let (p01, n01) = point(lat, lon + 1)
                let (p10, n10) = point(lat + 1, lon)
                let (p11, n11) = point(lat + 1, lon + 1)
                vertices.append(SceneGizmoVertexIn(world: p00, normal: n00, color: color))
                vertices.append(SceneGizmoVertexIn(world: p10, normal: n10, color: color))
                vertices.append(SceneGizmoVertexIn(world: p11, normal: n11, color: color))
                vertices.append(SceneGizmoVertexIn(world: p00, normal: n00, color: color))
                vertices.append(SceneGizmoVertexIn(world: p11, normal: n11, color: color))
                vertices.append(SceneGizmoVertexIn(world: p01, normal: n01, color: color))
            }
        }
        return vertices
    }
}

private extension SceneGizmoOverlay.HandleID {
    /// A FIXED order to build/emit in, for the reason every other fixed
    /// handle order in this feature exists: a `Dictionary`'s order is seeded
    /// per process, and a gizmo whose triangles came out in a different
    /// sequence on every launch is not a rendering bug today but is one
    /// nobody could ever reproduce.
    var sortKey: Int {
        switch self {
        case .axisX: return 0
        case .axisY: return 1
        case .axisZ: return 2
        case .planeXY: return 3
        case .planeXZ: return 4
        case .planeYZ: return 5
        case .free: return 6
        case .uniform: return 7
        case .viewRing: return 8
        case .light: return 9
        }
    }
}
