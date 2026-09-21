import Foundation
import simd

final class GizmoRenderer {
    typealias WorldToNDC = (SIMD2<Float>, CGSize) -> SIMD2<Float>

    struct RotateGizmoGeometry {
        var fill: [GizmoVertex]
        var stroke: [GizmoVertex]
    }

    private let worldToNDC: WorldToNDC
    var worldTransform: ((SIMD2<Float>) -> SIMD2<Float>)?
    var ndcTransform: ((SIMD2<Float>, CGSize) -> SIMD2<Float>)?

    init(worldToNDC: @escaping WorldToNDC) {
        self.worldToNDC = worldToNDC
    }

    /// Translate, as it was before the family restyle.
    ///
    /// The spikes that replaced these arrows read as traced and misshapen —
    /// a taper is right for Rotate's needle, which points, and wrong for an
    /// axis arrow, which travels. Put back verbatim at the author's request,
    /// glow disc and all: this one deliberately does NOT follow the contoured
    /// house style the other three now share, and
    /// `verify_transform_gizmos.py` records that as a decision rather than
    /// letting it look like drift.
    func moveGizmoVertices(center: SIMD2<Float>,
                           zoom: CGFloat,
                           active: GizmoHandle?,
                           hovered: GizmoHandle?,
                           viewSize: CGSize) -> [GizmoVertex] {
        // Proportions tuned to match the provided reference image.
        let lengthPt = 92.0
        let xAxisLength = screenToWorld(lengthPt * 0.86, zoom: zoom)
        let yAxisLength = screenToWorld(lengthPt * 0.86, zoom: zoom)
        let xHeadSize = screenToWorld(23.0, zoom: zoom)
        let yHeadSize = screenToWorld(24.0, zoom: zoom)
        let xHalfWidth = screenToWorld(6.8, zoom: zoom)
        let yHalfWidth = screenToWorld(6.0, zoom: zoom)
        // FROM THE SHARED METRICS, which the hit test reads too. These were
        // three literals here and two different literals in `hitTestGizmo`, and
        // the gap between them is the whole of "it is very hard to grab X or Y
        // alone": the disc was drawn at 16 and grabbed at up to 122.
        let centerRadius = screenToWorld(CGFloat(MoveGizmoMetrics.centerRadiusPx), zoom: zoom)
        let centerInnerRadius = centerRadius * MoveGizmoMetrics.centerInnerScale
        let centerGlowRadius = screenToWorld(44.0, zoom: zoom)
        let axisInset = screenToWorld(CGFloat(MoveGizmoMetrics.axisInnerPx), zoom: zoom)

        let xStart = center + SIMD2<Float>(axisInset, 0)
        let xEnd = center + SIMD2<Float>(xAxisLength, 0)
        let yStart = center + SIMD2<Float>(0, axisInset)
        let yEnd = center + SIMD2<Float>(0, yAxisLength)

        let red = handleColor(for: .moveX, active: active, hovered: hovered, base: SIMD4(0.86, 0.33, 0.38, 0.96))
        let green = handleColor(for: .moveY, active: active, hovered: hovered, base: SIMD4(0.43, 0.72, 0.49, 0.98))
        let blue = handleColor(for: .moveCenter, active: active, hovered: hovered, base: SIMD4(0.38, 0.64, 0.88, 0.98))
        let darkEdge = SIMD4<Float>(0.03, 0.03, 0.03, 0.42)

        var vertices: [GizmoVertex] = []

        // Removed directional glow blobs to keep gizmo clean and precise.
        vertices.append(contentsOf: circleFill(center: center, radius: centerGlowRadius, color: SIMD4<Float>(0.08, 0.66, 1.0, 0.22), viewSize: viewSize, segments: 44))

        // Dark silhouette pass for sharp shape definition.
        vertices.append(contentsOf: roundedArrow(from: xStart, to: xEnd, halfWidth: xHalfWidth * 1.10, headSize: xHeadSize * 1.04, color: darkEdge, viewSize: viewSize))
        vertices.append(contentsOf: roundedArrow(from: yStart, to: yEnd, halfWidth: yHalfWidth * 1.10, headSize: yHeadSize * 1.04, color: darkEdge, viewSize: viewSize))

        // Main colored arrows.
        vertices.append(contentsOf: roundedArrow(from: xStart, to: xEnd, halfWidth: xHalfWidth, headSize: xHeadSize, color: red, viewSize: viewSize))
        vertices.append(contentsOf: roundedArrow(from: yStart, to: yEnd, halfWidth: yHalfWidth, headSize: yHeadSize, color: green, viewSize: viewSize))

        // Center orb.
        vertices.append(contentsOf: circleFill(center: center, radius: centerRadius * 1.05, color: SIMD4<Float>(0.02, 0.10, 0.16, 0.28), viewSize: viewSize, segments: 24))
        vertices.append(contentsOf: circleFill(center: center, radius: centerRadius, color: blue, viewSize: viewSize, segments: 22))
        vertices.append(contentsOf: circleFill(center: center, radius: centerInnerRadius, color: SIMD4<Float>(0.12, 0.74, 1.0, 0.28), viewSize: viewSize, segments: 18))
        return vertices
    }

    /// The rotate gizmo, redrawn from the reference: a small ring at the
    /// pivot, a ring of evenly spaced dots as the angular track, and a long
    /// tapering needle pointing at the current angle.
    ///
    /// Entirely triangles, every edge feathered. The old one drew its two
    /// rings with `circleStroke`, which emits Metal `.line` primitives — one
    /// device pixel, binary coverage, no antialiasing — and that is what the
    /// jagged edges were. It was not tessellation: the old ring already used
    /// 96 segments, whose flat sides measure a thirtieth of a pixel.
    ///
    /// `stroke` comes back empty, and both call sites draw with `.triangle`.
    /// It is kept in the return type only so the two consumers do not have to
    /// change shape; if a later gizmo needs it, it is still there.
    func rotateGizmoVertices(center: SIMD2<Float>,
                             rotation: Float,
                             zoom: CGFloat,
                             active: GizmoHandle?,
                             hovered: GizmoHandle?,
                             viewSize: CGSize) -> RotateGizmoGeometry {
        typealias M = RotateGizmoMetrics
        func world(_ pixels: Float) -> Float { screenToWorld(CGFloat(pixels), zoom: zoom) }

        let isLit = active == .rotateRing || hovered == .rotateRing
        let accentBase = SIMD4<Float>(UM.gizmoRotateAccent.x, UM.gizmoRotateAccent.y,
                                      UM.gizmoRotateAccent.z, isLit ? 1.0 : 0.92)
        let accent = handleColor(for: .rotateRing, active: active, hovered: hovered,
                                 base: accentBase)
        let needleColor = SIMD4<Float>(UM.gizmoRotateNeedle.x, UM.gizmoRotateNeedle.y,
                                       UM.gizmoRotateNeedle.z, isLit ? 1.0 : 0.90)
        // The dots are the quiet part of the drawing until the gizmo is in use.
        let dotColor = SIMD4<Float>(accent.x, accent.y, accent.z,
                                    accent.w * (isLit ? 1.0 : 0.78))
        // The dark edge every part is drawn on. The accent is a bright yellow
        // and stays one: no yellow clears 3:1 against this canvas's near-white
        // checker square, so the mark is given an edge rather than being
        // dimmed into olive. It goes under the needle too — the needle is red,
        // artwork is often red, and a red spike over a red sprite is a spike
        // nobody can see.
        let contour = SIMD4<Float>(UM.gizmoRotateContour.x, UM.gizmoRotateContour.y,
                                   UM.gizmoRotateContour.z, 0.95)
        let contourWidth = world(M.contourPx)
        let feather = world(M.featherPx)
        let direction = SIMD2<Float>(cos(rotation), sin(rotation))
        let normal = SIMD2<Float>(-direction.y, direction.x)

        var fill: [GizmoVertex] = []

        // The track: one dot every 15 degrees, which reads as a ring and gives
        // the eye something to count against while dragging.
        let trackRadius = world(M.trackRadiusPx)
        let dotRadius = world(M.dotRadiusPx)
        for index in 0..<M.dotCount {
            let angle = (Float.pi * 2) * Float(index) / Float(M.dotCount)
            let point = center + SIMD2<Float>(cos(angle), sin(angle)) * trackRadius
            fill.append(contentsOf: featheredDisc(center: point,
                                                  radius: dotRadius + contourWidth,
                                                  color: contour,
                                                  feather: feather,
                                                  viewSize: viewSize,
                                                  segments: M.dotSegments))
            fill.append(contentsOf: featheredDisc(center: point,
                                                  radius: dotRadius,
                                                  color: dotColor,
                                                  feather: feather,
                                                  viewSize: viewSize,
                                                  segments: M.dotSegments))
        }

        // The needle: a semicircular base and a point, one convex outline.
        let inner = world(M.needleInnerPx)
        let outer = world(M.needleOuterPx)
        let halfWidth = world(M.needleHalfWidthPx)
        let baseCenter = center + direction * (inner + halfWidth)
        var outline: [SIMD2<Float>] = []
        let capSegments = 12
        for step in 0...capSegments {
            // From one side of the base round the back to the other.
            let sweep = Float.pi * Float(step) / Float(capSegments)
            let along = -cos(sweep)
            let across = sin(sweep)
            outline.append(baseCenter + direction * (along * halfWidth)
                           + normal * (across * halfWidth))
        }
        outline.append(center + direction * outer)
        // The contour is the same outline pushed out from its own centroid, so
        // the spike keeps its taper instead of being scaled about the pivot.
        // `grown` is shared with Translate's and Scale's marks: it was written
        // out here first and then again there, which is two statements of one
        // idea and exactly what this project keeps consolidating.
        fill.append(contentsOf: featheredConvexPolygon(grown(outline, by: contourWidth),
                                                       color: contour,
                                                       feather: feather,
                                                       viewSize: viewSize))
        fill.append(contentsOf: featheredConvexPolygon(outline,
                                                       color: needleColor,
                                                       feather: feather,
                                                       viewSize: viewSize))

        // The pivot ring, drawn last so it sits over the needle's base.
        let pivotRadius = world(M.pivotRadiusPx)
        let stroke = world(M.pivotStrokePx)
        fill.append(contentsOf: featheredAnnulus(center: center,
                                                 innerRadius: pivotRadius - stroke * 0.5 - contourWidth,
                                                 outerRadius: pivotRadius + stroke * 0.5 + contourWidth,
                                                 color: contour,
                                                 feather: feather,
                                                 viewSize: viewSize,
                                                 segments: M.ringSegments))
        fill.append(contentsOf: featheredAnnulus(center: center,
                                                 innerRadius: pivotRadius - stroke * 0.5,
                                                 outerRadius: pivotRadius + stroke * 0.5,
                                                 color: accent,
                                                 feather: feather,
                                                 viewSize: viewSize,
                                                 segments: M.ringSegments))

        // The nub: the same angle as the needle, marked on the ring itself, so
        // the angle stays readable when the needle runs off the viewport.
        let nubRadius = world(M.nubRadiusPx)
        let nubCenter = center + direction * (pivotRadius + nubRadius * 0.35)
        fill.append(contentsOf: featheredDisc(center: nubCenter,
                                              radius: nubRadius + contourWidth,
                                              color: contour,
                                              feather: feather,
                                              viewSize: viewSize,
                                              segments: M.dotSegments))
        fill.append(contentsOf: featheredDisc(center: nubCenter,
                                              radius: nubRadius,
                                              color: accent,
                                              feather: feather,
                                              viewSize: viewSize,
                                              segments: M.dotSegments))

        return RotateGizmoGeometry(fill: fill, stroke: [])
    }

    /// Scale: two bars with square heads, and a square in the pivot for
    /// uniform scale — the convention, in the family's clothes.
    ///
    /// The `sqrt(zoom)` term is gone. It multiplied the length by the square
    /// root of the zoom and then divided by the zoom, so the gizmo was 46px at
    /// 0.25x and 184px at 4x: chrome that changed size as the canvas moved.
    func scaleGizmoVertices(center: SIMD2<Float>,
                            zoom: CGFloat,
                            active: GizmoHandle?,
                            hovered: GizmoHandle?,
                            viewSize: CGSize) -> [GizmoVertex] {
        func world(_ pixels: Float) -> Float { screenToWorld(CGFloat(pixels), zoom: zoom) }
        let contour = SIMD4<Float>(UM.gizmoRotateContour.x, UM.gizmoRotateContour.y,
                                   UM.gizmoRotateContour.z, 0.95)
        let outlineWidth = world(GizmoStyle.contourPx)
        let feather = world(GizmoStyle.featherPx)

        let x = handleColor(for: .scaleCorner(0), active: active, hovered: hovered,
                            base: SIMD4(UM.gizmoAxisX.x, UM.gizmoAxisX.y, UM.gizmoAxisX.z, 0.96))
        let y = handleColor(for: .scaleCorner(1), active: active, hovered: hovered,
                            base: SIMD4(UM.gizmoAxisY.x, UM.gizmoAxisY.y, UM.gizmoAxisY.z, 0.96))
        let uniform = handleColor(for: .scaleCorner(2), active: active, hovered: hovered,
                                  base: SIMD4(UM.gizmoRotateAccent.x, UM.gizmoRotateAccent.y,
                                              UM.gizmoRotateAccent.z, 0.96))

        let start = world(GizmoStyle.pivotRadiusPx + 5)
        let reach = world(78)
        let halfWidth = world(3.4)
        let headHalf = world(8.0)

        var vertices: [GizmoVertex] = []
        vertices += gizmoBar(from: center + SIMD2<Float>(start, 0),
                             to: center + SIMD2<Float>(reach, 0),
                             halfWidth: halfWidth, headHalf: headHalf,
                             color: x, contour: contour, outlineWidth: outlineWidth,
                             feather: feather, viewSize: viewSize)
        vertices += gizmoBar(from: center + SIMD2<Float>(0, start),
                             to: center + SIMD2<Float>(0, reach),
                             halfWidth: halfWidth, headHalf: headHalf,
                             color: y, contour: contour, outlineWidth: outlineWidth,
                             feather: feather, viewSize: viewSize)
        vertices += gizmoPivot(center: center, color: uniform, contour: contour,
                               zoom: zoom, viewSize: viewSize)
        // The uniform handle: a square inside the ring, so it is obvious that
        // the centre of Scale does something Translate's centre does not.
        let inner = world(GizmoStyle.pivotRadiusPx * 0.46)
        let square = [SIMD2<Float>(-inner, -inner), SIMD2<Float>(inner, -inner),
                      SIMD2<Float>(inner, inner), SIMD2<Float>(-inner, inner)].map { center + $0 }
        vertices += featheredConvexPolygon(grown(square, by: outlineWidth),
                                           color: contour, feather: feather, viewSize: viewSize)
        vertices += featheredConvexPolygon(square, color: uniform, feather: feather,
                                           viewSize: viewSize)
        return vertices
    }

    /// Shear: two arcs that sweep to the angles they set.
    ///
    /// It used to draw two flattened ellipses and a ring at a radius taken
    /// from the sprite's TRANSFORMED CORNERS — so shearing the sprite moved
    /// its corners, which changed the radius, which redrew the whole gizmo
    /// bigger on every frame of the drag. That was the "animation", and it
    /// came with a ghost copy of each ellipse drawn underneath in grey.
    ///
    /// A fixed radius now, from `SkewGizmoMetrics`, and each arc SWEEPS from
    /// its axis to the shear angle on that axis — so the gizmo reads the value
    /// out rather than looking the same at every angle. The dot at the end of
    /// the sweep is the handle.
    func skewGizmoVertices(center: SIMD2<Float>,
                           shearXDegrees: Float,
                           shearYDegrees: Float,
                           zoom: CGFloat,
                           active: GizmoHandle?,
                           hovered: GizmoHandle?,
                           viewSize: CGSize) -> [GizmoVertex] {
        typealias M = SkewGizmoMetrics
        func world(_ pixels: Float) -> Float { screenToWorld(CGFloat(pixels), zoom: zoom) }
        let contour = SIMD4<Float>(UM.gizmoRotateContour.x, UM.gizmoRotateContour.y,
                                   UM.gizmoRotateContour.z, 0.95)
        let outlineWidth = world(GizmoStyle.contourPx)
        let feather = world(GizmoStyle.featherPx)
        let radius = world(M.trackRadiusPx)
        let arcWidth = world(M.arcWidthPx)

        let x = handleColor(for: .skewEdge(0), active: active, hovered: hovered,
                            base: SIMD4(UM.gizmoAxisX.x, UM.gizmoAxisX.y, UM.gizmoAxisX.z, 0.96))
        let y = handleColor(for: .skewEdge(1), active: active, hovered: hovered,
                            base: SIMD4(UM.gizmoAxisY.x, UM.gizmoAxisY.y, UM.gizmoAxisY.z, 0.96))
        let guide = SIMD4<Float>(UM.gizmoRotateAccent.x, UM.gizmoRotateAccent.y,
                                 UM.gizmoRotateAccent.z, 0.55)

        var vertices: [GizmoVertex] = []

        // The quiet ring the sweeps are read against, so zero has something to
        // be zero of.
        vertices += gizmoArc(center: center, radius: radius, width: world(M.guideWidthPx),
                             from: 0, to: .pi * 2, color: guide, contour: contour,
                             outlineWidth: outlineWidth, feather: feather,
                             viewSize: viewSize, segments: M.arcSegments)

        // One sweep per axis, from its own axis out to its angle. Clamped for
        // DRAWING only: past a right angle an arc wraps and stops meaning
        // anything, while the value itself is free to go where it likes.
        let limit = M.maxSweepDegrees * .pi / 180
        func sweep(axisAngle: Float, degrees: Float, color: SIMD4<Float>) {
            let angle = max(-limit, min(limit, degrees * .pi / 180))
            let handle = center + SIMD2<Float>(cos(axisAngle + angle), sin(axisAngle + angle)) * radius
            if abs(angle) > 1e-4 {
                vertices += gizmoArc(center: center, radius: radius, width: arcWidth,
                                     from: axisAngle, to: axisAngle + angle,
                                     color: color, contour: contour,
                                     outlineWidth: outlineWidth, feather: feather,
                                     viewSize: viewSize, segments: M.arcSegments)
            }
            vertices += gizmoDot(at: handle, radius: world(M.handleRadiusPx),
                                 color: color, contour: contour,
                                 outlineWidth: outlineWidth, feather: feather,
                                 viewSize: viewSize)
        }
        sweep(axisAngle: 0, degrees: shearXDegrees, color: x)
        sweep(axisAngle: .pi / 2, degrees: shearYDegrees, color: y)

        vertices += gizmoPivot(center: center,
                               color: SIMD4(UM.gizmoRotateAccent.x, UM.gizmoRotateAccent.y,
                                            UM.gizmoRotateAccent.z, 0.96),
                               contour: contour, zoom: zoom, viewSize: viewSize)
        return vertices
    }

    func pivotVertices(at center: SIMD2<Float>, zoom: CGFloat, viewSize: CGSize) -> [GizmoVertex] {
        let color = SIMD4<Float>(0.95, 0.95, 0.98, 0.85)
        let size = screenToWorld(8, zoom: zoom)
        let half = size * 0.5
        let horizontalStart = SIMD2<Float>(center.x - half, center.y)
        let horizontalEnd = SIMD2<Float>(center.x + half, center.y)
        let verticalStart = SIMD2<Float>(center.x, center.y - half)
        let verticalEnd = SIMD2<Float>(center.x, center.y + half)
        return line(from: horizontalStart, to: horizontalEnd, color: color, viewSize: viewSize)
            + line(from: verticalStart, to: verticalEnd, color: color, viewSize: viewSize)
    }

    /// A mesh node: a soft shadow, a hard rim, and the fill on top.
    ///
    /// The rim is the point. A flat disc behind a translucent shadow has no
    /// defined edge — over pale artwork it washed out, over busy artwork it
    /// smudged, and a row of them read as blobs rather than as points you can
    /// grab. A near-opaque dark ring gives every node the same edge whatever
    /// is behind it, which is how the node markers in mature 2D riggers read,
    /// and it is what lets the fill
    /// stay a flat statement of what the node MEANS: plain, hovered, selected.
    ///
    /// 24 segments, not 16: at the sizes these are drawn now, and at 2x, the
    /// old count left a visible flat on the shadow's circumference.
    func meshVertexMarker(center: SIMD2<Float>, radius: Float, color: SIMD4<Float>, viewSize: CGSize) -> [GizmoVertex] {
        let shadow = MeshOverlayMetrics.shadowInk
        let rim = MeshOverlayMetrics.rimInk
        let segments = MeshOverlayMetrics.segments
        return circleFill(center: center, radius: radius * MeshOverlayMetrics.shadowScale, color: shadow, viewSize: viewSize, segments: segments)
            + circleFill(center: center, radius: radius * MeshOverlayMetrics.rimScale, color: rim, viewSize: viewSize, segments: segments)
            + circleFill(center: center, radius: radius, color: color, viewSize: viewSize, segments: segments)
    }

    func boneWeightPieMarker(center: SIMD2<Float>,
                             radius: Float,
                             slices: [(weight: Float, color: SIMD4<Float>)],
                             viewSize: CGSize) -> [GizmoVertex] {
        guard !slices.isEmpty else { return [] }
        let totalWeight = slices.reduce(Float(0)) { $0 + max(0, $1.weight) }
        guard totalWeight > 0.0001 else { return [] }

        // The same shadow and the same rim as a plain node: in weight paint
        // these ARE the nodes, and a pie with no edge sitting next to a rimmed
        // disc looked like two different kinds of thing.
        let shadowColor = MeshOverlayMetrics.shadowInk
        let rim = MeshOverlayMetrics.rimInk
        let segments = MeshOverlayMetrics.pieSegments
        var vertices: [GizmoVertex] = []
        vertices.append(contentsOf: circleFill(center: center, radius: radius * MeshOverlayMetrics.shadowScale, color: shadowColor, viewSize: viewSize, segments: segments))
        vertices.append(contentsOf: circleFill(center: center, radius: radius * MeshOverlayMetrics.rimScale, color: rim, viewSize: viewSize, segments: segments))

        let totalSegments = 32
        var startAngle: Float = -.pi / 2
        for slice in slices {
            let normalized = max(0, slice.weight) / totalWeight
            guard normalized > 0.0001 else { continue }
            let sweep = normalized * Float.pi * 2
            let segmentCount = max(2, Int((normalized * Float(totalSegments)).rounded(.up)))
            let step = sweep / Float(segmentCount)
            let centerNDC = worldToNDC(center, viewSize)
            for segIndex in 0..<segmentCount {
                let a0 = startAngle + Float(segIndex) * step
                let a1 = startAngle + Float(segIndex + 1) * step
                let p1 = center + SIMD2<Float>(cos(a0), sin(a0)) * radius
                let p2 = center + SIMD2<Float>(cos(a1), sin(a1)) * radius
                vertices.append(GizmoVertex(position: centerNDC, color: slice.color))
                vertices.append(GizmoVertex(position: worldToNDC(p1, viewSize), color: slice.color))
                vertices.append(GizmoVertex(position: worldToNDC(p2, viewSize), color: slice.color))
            }
            startAngle += sweep
        }
        return vertices
    }

    func boneBodyVertices(start: SIMD2<Float>,
                          end: SIMD2<Float>,
                          halfWidth: Float,
                          fillColor: SIMD4<Float>,
                          outlineColor: SIMD4<Float>,
                          viewSize: CGSize) -> [GizmoVertex] {
        let delta = end - start
        let length = simd_length(delta)
        let outlineThickness = max(halfWidth * 0.28, 0.4)
        let outerRadius = halfWidth + outlineThickness
        let outerTip: SIMD2<Float>
        if length > 0.0001 {
            outerTip = end + (delta / length) * outlineThickness
        } else {
            outerTip = end
        }

        return teardropFill(start: start, tip: outerTip, headRadius: outerRadius, color: outlineColor, viewSize: viewSize)
            + teardropFill(start: start, tip: end, headRadius: halfWidth, color: fillColor, viewSize: viewSize)
    }

    func boneJointVertices(center: SIMD2<Float>,
                           radius: Float,
                           fillColor: SIMD4<Float>,
                           ringColor: SIMD4<Float>,
                           viewSize: CGSize) -> [GizmoVertex] {
        let outerRadius = radius * 0.66
        let innerRadius = radius * 0.50
        return ringFill(center: center,
                        innerRadius: innerRadius,
                        outerRadius: outerRadius,
                        color: ringColor,
                        viewSize: viewSize,
                        segments: 28)
            + circleFill(center: center, radius: radius * 0.22, color: fillColor, viewSize: viewSize, segments: 14)
    }

    private func teardropFill(start: SIMD2<Float>,
                              tip: SIMD2<Float>,
                              headRadius: Float,
                              color: SIMD4<Float>,
                              viewSize: CGSize) -> [GizmoVertex] {
        let delta = tip - start
        let length = simd_length(delta)
        guard length > headRadius * 1.02 else {
            return circleFill(center: start, radius: headRadius, color: color, viewSize: viewSize, segments: 26)
        }

        let dir = delta / length
        let perp = SIMD2<Float>(-dir.y, dir.x)
        let cosT = min(max(headRadius / length, -1), 1)
        let theta = acos(cosT)

        let arcSegments = 28
        var perimeter: [SIMD2<Float>] = []
        for i in 0...arcSegments {
            let t = Float(i) / Float(arcSegments)
            let angle = theta + t * (2 * Float.pi - 2 * theta)
            let p = start + dir * (headRadius * cos(angle)) + perp * (headRadius * sin(angle))
            perimeter.append(p)
        }
        perimeter.append(tip)
        return filledPolygon(points: perimeter, color: color, viewSize: viewSize)
    }

    private func line(from start: SIMD2<Float>, to end: SIMD2<Float>, color: SIMD4<Float>, viewSize: CGSize) -> [GizmoVertex] {
        [
            GizmoVertex(position: worldToNDC(start, viewSize), color: color),
            GizmoVertex(position: worldToNDC(end, viewSize), color: color)
        ]
    }



    private func filledPolygon(points: [SIMD2<Float>], color: SIMD4<Float>, viewSize: CGSize) -> [GizmoVertex] {
        guard points.count >= 3 else { return [] }
        var vertices: [GizmoVertex] = []
        let origin = worldToNDC(points[0], viewSize)
        for index in 1..<(points.count - 1) {
            vertices.append(GizmoVertex(position: origin, color: color))
            vertices.append(GizmoVertex(position: worldToNDC(points[index], viewSize), color: color))
            vertices.append(GizmoVertex(position: worldToNDC(points[index + 1], viewSize), color: color))
        }
        return vertices
    }


    private func roundedArrow(from start: SIMD2<Float>,
                              to end: SIMD2<Float>,
                              halfWidth: Float,
                              headSize: Float,
                              color: SIMD4<Float>,
                              viewSize: CGSize) -> [GizmoVertex] {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0.001 else { return [] }

        let dir = delta / length
        let headBase = end - dir * min(headSize * 0.9, length * 0.45)

        var vertices: [GizmoVertex] = []
        vertices.append(contentsOf: capsuleSegment(from: start, to: headBase, halfWidth: halfWidth, color: color, viewSize: viewSize))
        vertices.append(contentsOf: softArrowHead(at: end, direction: dir, size: headSize, halfWidth: halfWidth * 1.9, color: color, viewSize: viewSize))
        return vertices
    }

    private func capsuleSegment(from start: SIMD2<Float>,
                                to end: SIMD2<Float>,
                                halfWidth: Float,
                                color: SIMD4<Float>,
                                viewSize: CGSize) -> [GizmoVertex] {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0.0001 else { return [] }

        let dir = delta / length
        let perp = SIMD2<Float>(-dir.y, dir.x) * halfWidth
        let p0 = start + perp
        let p1 = end + perp
        let p2 = end - perp
        let p3 = start - perp

        return filledPolygon(points: [p0, p1, p2, p3], color: color, viewSize: viewSize)
            + circleFill(center: start, radius: halfWidth, color: color, viewSize: viewSize, segments: 16)
            + circleFill(center: end, radius: halfWidth, color: color, viewSize: viewSize, segments: 16)
    }

    private func softArrowHead(at tip: SIMD2<Float>,
                               direction: SIMD2<Float>,
                               size: Float,
                               halfWidth: Float,
                               color: SIMD4<Float>,
                               viewSize: CGSize) -> [GizmoVertex] {
        let dir = simd_normalize(direction)
        let perp = SIMD2<Float>(-dir.y, dir.x)
        let baseCenter = tip - dir * size
        let shoulderCenter = tip - dir * (size * 0.36)
        let taperCenter = tip - dir * (size * 0.72)

        let shoulderHalfWidth = halfWidth * 0.34
        let baseHalfWidth = halfWidth
        let taperHalfWidth = halfWidth * 0.68

        let shoulderLeft = shoulderCenter + perp * shoulderHalfWidth
        let shoulderRight = shoulderCenter - perp * shoulderHalfWidth
        let taperLeft = taperCenter + perp * taperHalfWidth
        let taperRight = taperCenter - perp * taperHalfWidth
        let left = baseCenter + perp * baseHalfWidth
        let right = baseCenter - perp * baseHalfWidth

        return filledPolygon(points: [tip, shoulderLeft, shoulderRight], color: color, viewSize: viewSize)
            + filledPolygon(points: [shoulderLeft, taperLeft, taperRight, shoulderRight], color: color, viewSize: viewSize)
            + filledPolygon(points: [taperLeft, left, right, taperRight], color: color, viewSize: viewSize)
    }

    // MARK: - The family's shared marks
    //
    // Rotate was redrawn first and these came out of it. Translate, Scale and
    // Shear draw with them so the four tools read as one set rather than as
    // four people's work.

    /// The pivot ring every gizmo sits on, contoured.
    private func gizmoPivot(center: SIMD2<Float>,
                            color: SIMD4<Float>,
                            contour: SIMD4<Float>,
                            zoom: CGFloat,
                            viewSize: CGSize) -> [GizmoVertex] {
        let radius = screenToWorld(CGFloat(GizmoStyle.pivotRadiusPx), zoom: zoom)
        let stroke = screenToWorld(CGFloat(GizmoStyle.pivotStrokePx), zoom: zoom)
        let outline = screenToWorld(CGFloat(GizmoStyle.contourPx), zoom: zoom)
        let feather = screenToWorld(CGFloat(GizmoStyle.featherPx), zoom: zoom)
        return featheredAnnulus(center: center,
                                innerRadius: radius - stroke * 0.5 - outline,
                                outerRadius: radius + stroke * 0.5 + outline,
                                color: contour, feather: feather,
                                viewSize: viewSize, segments: 72)
            + featheredAnnulus(center: center,
                               innerRadius: radius - stroke * 0.5,
                               outerRadius: radius + stroke * 0.5,
                               color: color, feather: feather,
                               viewSize: viewSize, segments: 72)
    }


    /// A convex outline pushed out from its own centroid, so a tapered shape
    /// keeps its taper instead of being scaled about some other point.
    private func grown(_ points: [SIMD2<Float>], by amount: Float) -> [SIMD2<Float>] {
        let centroid = points.reduce(SIMD2<Float>(repeating: 0), +) / Float(points.count)
        return points.map { point in
            let away = point - centroid
            let length = simd_length(away)
            return length > 1e-6 ? point + away / length * amount : point
        }
    }

    /// A parallel-sided bar with a square head: the scale handle.
    private func gizmoBar(from start: SIMD2<Float>,
                          to end: SIMD2<Float>,
                          halfWidth: Float,
                          headHalf: Float,
                          color: SIMD4<Float>,
                          contour: SIMD4<Float>,
                          outlineWidth: Float,
                          feather: Float,
                          viewSize: CGSize) -> [GizmoVertex] {
        let delta = end - start
        let length = simd_length(delta)
        guard length > 1e-5 else { return [] }
        let direction = delta / length
        let normal = SIMD2<Float>(-direction.y, direction.x)
        let shaftEnd = end - direction * headHalf
        let shaft = [start + normal * halfWidth, shaftEnd + normal * halfWidth,
                     shaftEnd - normal * halfWidth, start - normal * halfWidth]
        let head = [end + direction * headHalf + normal * headHalf,
                    end + direction * headHalf - normal * headHalf,
                    end - direction * headHalf - normal * headHalf,
                    end - direction * headHalf + normal * headHalf]
        var vertices: [GizmoVertex] = []
        vertices += featheredConvexPolygon(grown(shaft, by: outlineWidth),
                                           color: contour, feather: feather, viewSize: viewSize)
        vertices += featheredConvexPolygon(grown(head, by: outlineWidth),
                                           color: contour, feather: feather, viewSize: viewSize)
        vertices += featheredConvexPolygon(shaft, color: color, feather: feather, viewSize: viewSize)
        vertices += featheredConvexPolygon(head, color: color, feather: feather, viewSize: viewSize)
        return vertices
    }

    /// A contoured dot: the thing an artist aims at.
    private func gizmoDot(at center: SIMD2<Float>,
                          radius: Float,
                          color: SIMD4<Float>,
                          contour: SIMD4<Float>,
                          outlineWidth: Float,
                          feather: Float,
                          viewSize: CGSize) -> [GizmoVertex] {
        featheredDisc(center: center, radius: radius + outlineWidth, color: contour,
                      feather: feather, viewSize: viewSize, segments: GizmoStyle.discSegments)
            + featheredDisc(center: center, radius: radius, color: color,
                            feather: feather, viewSize: viewSize, segments: GizmoStyle.discSegments)
    }

    /// A band of a circle, contoured, from one angle to another.
    private func gizmoArc(center: SIMD2<Float>,
                          radius: Float,
                          width: Float,
                          from startAngle: Float,
                          to endAngle: Float,
                          color: SIMD4<Float>,
                          contour: SIMD4<Float>?,
                          outlineWidth: Float,
                          feather: Float,
                          viewSize: CGSize,
                          segments: Int) -> [GizmoVertex] {
        var vertices: [GizmoVertex] = []
        if let contour {
            vertices += featheredArcBand(center: center, radius: radius,
                                         width: width + outlineWidth * 2,
                                         from: startAngle, to: endAngle,
                                         color: contour, feather: feather,
                                         viewSize: viewSize, segments: segments)
        }
        vertices += featheredArcBand(center: center, radius: radius, width: width,
                                     from: startAngle, to: endAngle,
                                     color: color, feather: feather,
                                     viewSize: viewSize, segments: segments)
        return vertices
    }

    /// One arc band, both rims faded.
    private func featheredArcBand(center: SIMD2<Float>,
                                  radius: Float,
                                  width: Float,
                                  from startAngle: Float,
                                  to endAngle: Float,
                                  color: SIMD4<Float>,
                                  feather: Float,
                                  viewSize: CGSize,
                                  segments: Int) -> [GizmoVertex] {
        let sweep = endAngle - startAngle
        guard abs(sweep) > 1e-5, segments >= 1 else { return [] }
        let steps = max(2, Int((Float(segments) * abs(sweep) / (Float.pi * 2)).rounded(.up)))
        let inner = radius - width * 0.5
        let outer = radius + width * 0.5
        let half = feather * 0.5
        let coreInner = min(inner + half, radius)
        let coreOuter = max(outer - half, radius)
        let clear = SIMD4<Float>(color.x, color.y, color.z, 0)
        var vertices: [GizmoVertex] = []
        for step in 0..<steps {
            let a0 = startAngle + sweep * Float(step) / Float(steps)
            let a1 = startAngle + sweep * Float(step + 1) / Float(steps)
            let d0 = SIMD2<Float>(cos(a0), sin(a0))
            let d1 = SIMD2<Float>(cos(a1), sin(a1))
            func band(_ from: Float, _ to: Float, _ c0: SIMD4<Float>, _ c1: SIMD4<Float>) {
                let p00 = center + d0 * from, p01 = center + d0 * to
                let p10 = center + d1 * from, p11 = center + d1 * to
                vertices.append(GizmoVertex(position: worldToNDC(p00, viewSize), color: c0))
                vertices.append(GizmoVertex(position: worldToNDC(p01, viewSize), color: c1))
                vertices.append(GizmoVertex(position: worldToNDC(p10, viewSize), color: c0))
                vertices.append(GizmoVertex(position: worldToNDC(p10, viewSize), color: c0))
                vertices.append(GizmoVertex(position: worldToNDC(p01, viewSize), color: c1))
                vertices.append(GizmoVertex(position: worldToNDC(p11, viewSize), color: c1))
            }
            band(max(inner - half, 0), coreInner, clear, color)
            band(coreInner, coreOuter, color, color)
            band(coreOuter, outer + half, color, clear)
        }
        return vertices
    }

    // MARK: - Feathered primitives
    //
    // Triangles with an alpha ramp along every edge. This is analytic
    // antialiasing: the ramp puts the perceived edge — the alpha-weighted
    // centroid of the pixels it covers — where the geometry actually is, to a
    // fraction of a pixel. A Metal `.line` primitive cannot: it is one device
    // pixel with binary coverage, so its edge lands on whole pixels only and
    // jumps a whole pixel at a time. That jump is what "pixelated" was.

    /// A ring band with both rims faded.
    private func featheredAnnulus(center: SIMD2<Float>,
                                  innerRadius: Float,
                                  outerRadius: Float,
                                  color: SIMD4<Float>,
                                  feather: Float,
                                  viewSize: CGSize,
                                  segments: Int) -> [GizmoVertex] {
        guard segments >= 3, outerRadius > innerRadius else { return [] }
        let half = feather * 0.5
        // The band can be thinner than the feather; clamp so the core never
        // inverts, which would wind the triangles backwards.
        let coreInner = min(innerRadius + half, (innerRadius + outerRadius) * 0.5)
        let coreOuter = max(outerRadius - half, (innerRadius + outerRadius) * 0.5)
        let clear = SIMD4<Float>(color.x, color.y, color.z, 0)
        var vertices: [GizmoVertex] = []
        vertices.reserveCapacity(segments * 18)
        let step = (Float.pi * 2) / Float(segments)
        for i in 0..<segments {
            let a0 = Float(i) * step
            let a1 = Float(i + 1) * step
            let d0 = SIMD2<Float>(cos(a0), sin(a0))
            let d1 = SIMD2<Float>(cos(a1), sin(a1))
            func band(_ from: Float, _ to: Float, _ fromColor: SIMD4<Float>, _ toColor: SIMD4<Float>) {
                let p00 = center + d0 * from, p01 = center + d0 * to
                let p10 = center + d1 * from, p11 = center + d1 * to
                vertices.append(GizmoVertex(position: worldToNDC(p00, viewSize), color: fromColor))
                vertices.append(GizmoVertex(position: worldToNDC(p01, viewSize), color: toColor))
                vertices.append(GizmoVertex(position: worldToNDC(p10, viewSize), color: fromColor))
                vertices.append(GizmoVertex(position: worldToNDC(p10, viewSize), color: fromColor))
                vertices.append(GizmoVertex(position: worldToNDC(p01, viewSize), color: toColor))
                vertices.append(GizmoVertex(position: worldToNDC(p11, viewSize), color: toColor))
            }
            band(max(innerRadius - half, 0), coreInner, clear, color)   // inner feather
            band(coreInner, coreOuter, color, color)                    // core
            band(coreOuter, outerRadius + half, color, clear)           // outer feather
        }
        return vertices
    }

    /// A disc with a faded rim.
    private func featheredDisc(center: SIMD2<Float>,
                               radius: Float,
                               color: SIMD4<Float>,
                               feather: Float,
                               viewSize: CGSize,
                               segments: Int) -> [GizmoVertex] {
        guard segments >= 3, radius > 0 else { return [] }
        let half = min(feather * 0.5, radius * 0.49)
        let core = radius - half
        var vertices = circleFill(center: center, radius: core, color: color,
                                  viewSize: viewSize, segments: segments)
        vertices.append(contentsOf: featheredAnnulus(center: center,
                                                     innerRadius: core,
                                                     outerRadius: radius + half,
                                                     color: color,
                                                     feather: feather,
                                                     viewSize: viewSize,
                                                     segments: segments))
        return vertices
    }

    /// A convex outline, filled, with a skirt fading outwards from every edge.
    ///
    /// Convex on purpose: the fill is a fan from the centroid, and the skirt is
    /// pushed along each edge's outward normal, both of which need convexity to
    /// be correct. The needle — a semicircular base and a point — is convex.
    private func featheredConvexPolygon(_ points: [SIMD2<Float>],
                                        color: SIMD4<Float>,
                                        feather: Float,
                                        viewSize: CGSize) -> [GizmoVertex] {
        guard points.count >= 3 else { return [] }
        let centroid = points.reduce(SIMD2<Float>(repeating: 0), +) / Float(points.count)
        let clear = SIMD4<Float>(color.x, color.y, color.z, 0)
        var vertices: [GizmoVertex] = []
        vertices.reserveCapacity(points.count * 9)
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            vertices.append(GizmoVertex(position: worldToNDC(centroid, viewSize), color: color))
            vertices.append(GizmoVertex(position: worldToNDC(a, viewSize), color: color))
            vertices.append(GizmoVertex(position: worldToNDC(b, viewSize), color: color))

            // Outward, taken from the centroid rather than from the winding:
            // a polygon assembled from an arc and a point can be given either
            // way round, and a skirt pushed inwards eats the shape.
            let edge = b - a
            let length = simd_length(edge)
            guard length > 1e-6 else { continue }
            var normal = SIMD2<Float>(-edge.y, edge.x) / length
            if simd_dot(normal, (a + b) * 0.5 - centroid) < 0 { normal = -normal }
            let a2 = a + normal * feather
            let b2 = b + normal * feather
            vertices.append(GizmoVertex(position: worldToNDC(a, viewSize), color: color))
            vertices.append(GizmoVertex(position: worldToNDC(a2, viewSize), color: clear))
            vertices.append(GizmoVertex(position: worldToNDC(b, viewSize), color: color))
            vertices.append(GizmoVertex(position: worldToNDC(b, viewSize), color: color))
            vertices.append(GizmoVertex(position: worldToNDC(a2, viewSize), color: clear))
            vertices.append(GizmoVertex(position: worldToNDC(b2, viewSize), color: clear))
        }
        return vertices
    }

    private func circleFill(center: SIMD2<Float>, radius: Float, color: SIMD4<Float>, viewSize: CGSize, segments: Int) -> [GizmoVertex] {
        guard segments >= 3 else { return [] }
        var vertices: [GizmoVertex] = []
        let step = (Float.pi * 2) / Float(segments)
        for i in 0..<segments {
            let a0 = Float(i) * step
            let a1 = Float(i + 1) * step
            let p0 = center
            let p1 = center + SIMD2<Float>(cos(a0), sin(a0)) * radius
            let p2 = center + SIMD2<Float>(cos(a1), sin(a1)) * radius
            vertices.append(GizmoVertex(position: worldToNDC(p0, viewSize), color: color))
            vertices.append(GizmoVertex(position: worldToNDC(p1, viewSize), color: color))
            vertices.append(GizmoVertex(position: worldToNDC(p2, viewSize), color: color))
        }
        return vertices
    }

    private func ringFill(center: SIMD2<Float>,
                          innerRadius: Float,
                          outerRadius: Float,
                          color: SIMD4<Float>,
                          viewSize: CGSize,
                          segments: Int) -> [GizmoVertex] {
        ringArcFill(center: center,
                    innerRadius: innerRadius,
                    outerRadius: outerRadius,
                    startAngle: 0,
                    endAngle: Float.pi * 2,
                    color: color,
                    viewSize: viewSize,
                    segments: segments)
    }

    private func ringArcFill(center: SIMD2<Float>,
                             innerRadius: Float,
                             outerRadius: Float,
                             startAngle: Float,
                             endAngle: Float,
                             color: SIMD4<Float>,
                             viewSize: CGSize,
                             segments: Int) -> [GizmoVertex] {
        guard segments >= 3 else { return [] }
        let total = max(0.0001, endAngle - startAngle)
        let step = total / Float(segments)
        var vertices: [GizmoVertex] = []

        for i in 0..<segments {
            let a0 = startAngle + Float(i) * step
            let a1 = startAngle + Float(i + 1) * step
            let outer0 = center + SIMD2<Float>(cos(a0), sin(a0)) * outerRadius
            let outer1 = center + SIMD2<Float>(cos(a1), sin(a1)) * outerRadius
            let inner0 = center + SIMD2<Float>(cos(a0), sin(a0)) * innerRadius
            let inner1 = center + SIMD2<Float>(cos(a1), sin(a1)) * innerRadius

            vertices.append(GizmoVertex(position: worldToNDC(outer0, viewSize), color: color))
            vertices.append(GizmoVertex(position: worldToNDC(inner0, viewSize), color: color))
            vertices.append(GizmoVertex(position: worldToNDC(outer1, viewSize), color: color))

            vertices.append(GizmoVertex(position: worldToNDC(outer1, viewSize), color: color))
            vertices.append(GizmoVertex(position: worldToNDC(inner0, viewSize), color: color))
            vertices.append(GizmoVertex(position: worldToNDC(inner1, viewSize), color: color))
        }

        return vertices
    }


    private func handleColor(for handle: GizmoHandle,
                             active: GizmoHandle?,
                             hovered: GizmoHandle?,
                             base: SIMD4<Float>) -> SIMD4<Float> {
        if active == handle {
            return SIMD4<Float>(
                min(base.x + 0.28, 1.0),
                min(base.y + 0.28, 1.0),
                min(base.z + 0.28, 1.0),
                1.0
            )
        }
        if hovered == handle {
            return SIMD4<Float>(
                min(base.x + 0.16, 1.0),
                min(base.y + 0.16, 1.0),
                min(base.z + 0.16, 1.0),
                0.98
            )
        }
        return base
    }

    private func screenToWorld(_ lengthPt: CGFloat, zoom: CGFloat) -> Float {
        Float(lengthPt / max(zoom, 0.0001))
    }

    private func worldToNDC(_ world: SIMD2<Float>, _ viewSize: CGSize) -> SIMD2<Float> {
        if let ndcTransform {
            return ndcTransform(world, viewSize)
        }
        let transformed = worldTransform?(world) ?? world
        return worldToNDC(transformed, viewSize)
    }
}
