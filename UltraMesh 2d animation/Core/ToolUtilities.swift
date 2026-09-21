import Foundation
import CoreGraphics
import Metal
import simd
#if canImport(UIKit)
import UIKit
#endif

enum ToolUtilities {
    enum SelectionTarget {
        case image(UUID)
        case bone(UUID)
    }

#if os(iOS)
    /// Touch input needs far larger effective targets than a mouse pointer.
    /// All hit-test tolerances below are expressed in drawable pixels, so they
    /// scale with the display's backing factor to stay constant in points.
    private static var displayScale: Float {
        let scale = Float(UITraitCollection.current.displayScale)
        return scale > 0 ? scale : 2
    }

    /// Multiplier applied to pointer-sized hit tolerances on touch devices.
    /// Sized so a 12 px mouse target becomes a comfortable ~22 pt touch target.
    static var touchHitScale: Float { displayScale * 1.85 }
#else
    /// On macOS the pointer is pixel-precise; tolerances are used verbatim.
    static var touchHitScale: Float { 1.0 }
#endif

    // `hitTest(point:scene:assets:)` and `isPointInsideImage` were deleted, not
    // deprecated. Both tested a bounding quad and knew nothing about alpha,
    // draw order or skins, and every caller has moved to `CanvasPicking`.
    // Leaving them would leave a second, less accurate way to answer the same
    // question — which is how the accurate path came to be cancelled by the
    // inaccurate one in the first place.

    static func snap(_ value: Float, grid: Float) -> Float {
        guard grid > 0 else { return value }
        return (value / grid).rounded() * grid
    }

    static func snapAngle(_ radians: Float, stepDegrees: Float) -> Float {
        let step = stepDegrees * Float.pi / 180
        guard step > 0 else { return radians }
        return (radians / step).rounded() * step
    }

    static func snapScale(_ value: Float, step: Float) -> Float {
        guard step > 0 else { return value }
        return (value / step).rounded() * step
    }

    static func snapScale(_ value: SIMD2<Float>, step: Float) -> SIMD2<Float> {
        SIMD2<Float>(snapScale(value.x, step: step), snapScale(value.y, step: step))
    }

    static func snap(_ point: SIMD2<Float>, grid: Float) -> SIMD2<Float> {
        SIMD2<Float>(snap(point.x, grid: grid), snap(point.y, grid: grid))
    }

    static func constrainAxis(delta: SIMD2<Float>) -> SIMD2<Float> {
        abs(delta.x) > abs(delta.y) ? SIMD2<Float>(delta.x, 0) : SIMD2<Float>(0, delta.y)
    }

    static func hitTestGizmo(tool: ActiveTool,
                             screenPoint: SIMD2<Float>,
                             viewSize: SIMD2<Float>,
                             scene: SceneManager,
                             assets: AssetManager,
                             camera: CameraState?) -> GizmoHandle? {
        let selectedImage = scene.selectedImageID.flatMap { scene.image(for: $0) }
        let selectedBoneSegment = scene.selectedBoneID.flatMap { scene.skeleton.lineSegment(for: $0) }
        guard let center = selectedImage?.position ?? selectedBoneSegment?.start else { return nil }
        let zoom = Float(camera?.zoom ?? 1.0)
        let centerScreen = camera?.worldToScreen(center, viewSize: viewSize) ?? (center + viewSize * 0.5)
        // 1.0 on macOS (pointer-precise); enlarged for touch on iPad.
        let hitScale = touchHitScale

        switch tool {
        case .move, .select:
            // MEASURED AGAINST WHAT IS DRAWN, and decided by which handle is
            // NEAREST rather than by which test runs first.
            //
            // It used to carry a 22 for the centre and a 24 for the axes, both
            // multiplied by `touchHitScale`, against a disc drawn at 16 and
            // axes drawn to start at 16.5. Three faults compounded: the disc's
            // grab radius grew with the touch scale until it covered the axes
            // — on a 3x iPad, none of the X axis answered as X — the axis bands
            // were measured from the centre rather than from where they start,
            // so both covered the origin; and the first match won, so X beat Y
            // wherever they overlapped, whatever the pointer was nearer to.
            let axisLength = Float(MoveGizmoMetrics.axisLengthPx
                                   * sqrt(max(zoom, 0.001)) / max(zoom, 0.001))
            let xHandle = center + SIMD2<Float>(axisLength, 0)
            let yHandle = center + SIMD2<Float>(0, axisLength)
            let xScreen = camera?.worldToScreen(xHandle, viewSize: viewSize) ?? (xHandle + viewSize * 0.5)
            let yScreen = camera?.worldToScreen(yHandle, viewSize: viewSize) ?? (yHandle + viewSize * 0.5)

            // The axes are drawn the same length, so one projected length
            // converts the metrics' pixels into this frame's screen distances.
            let drawnAxisPx = max(simd_length(xScreen - centerScreen), 0.0001)
            let pxPerMetric = drawnAxisPx / MoveGizmoMetrics.axisLengthPx
            let centreGrab = MoveGizmoMetrics.centerGrabPx(hitScale: hitScale) * pxPerMetric
            let inner = MoveGizmoMetrics.axisGrabInnerPx(hitScale: hitScale) * pxPerMetric
            let outer = MoveGizmoMetrics.axisGrabOuterPx(hitScale: hitScale) * pxPerMetric
            let across = MoveGizmoMetrics.axisGrabAcrossPx(hitScale: hitScale) * pxPerMetric

            /// Distance ACROSS an axis, or nil when the press is off its length.
            func acrossAxis(_ tip: SIMD2<Float>) -> Float? {
                let axis = tip - centerScreen
                let length = simd_length(axis)
                guard length > 0.0001 else { return nil }
                let unit = axis / length
                let toPoint = screenPoint - centerScreen
                let along = simd_dot(toPoint, unit)
                guard along >= inner, along <= outer else { return nil }
                let sideways = abs(toPoint.x * -unit.y + toPoint.y * unit.x)
                return sideways <= across ? sideways : nil
            }

            var best: (handle: GizmoHandle, distance: Float)?
            let centreDistance = simd_length(screenPoint - centerScreen)
            if centreDistance <= centreGrab {
                best = (.moveCenter, centreDistance)
            }
            // Strictly nearer, so an exact tie — a press on the diagonal,
            // equally far from both — falls to X and does so identically every
            // time. A deterministic tie is not the fault; a disc-shaped one
            // decided by test order was.
            if let sideways = acrossAxis(xScreen), best == nil || sideways < best!.distance {
                best = (.moveX, sideways)
            }
            if let sideways = acrossAxis(yScreen), best == nil || sideways < best!.distance {
                best = (.moveY, sideways)
            }
            return best?.handle
        case .bone:
            if let boneID = hitTestBone(screenPoint: screenPoint, viewSize: viewSize, scene: scene, camera: camera) {
                return .bone(boneID)
            }
            return nil
        case .rotate:
            // Measured against the gizmo's own metrics. This used to carry a
            // 58 and a 50 of its own, which corresponded to nothing that was
            // drawn: the artist aimed at the ring they could see and the grab
            // band was eight pixels somewhere else.
            let distance = simd_length(screenPoint - centerScreen)
            if RotateGizmoMetrics.grabsTrack(distancePx: distance, hitScale: hitScale) {
                return .rotateRing
            }
            // The needle is the biggest thing on screen and pointing at it is
            // the obvious way to say "turn this", so it grabs too.
            let rotation = selectedImage?.rotation
                ?? selectedBoneSegment.map { atan2($0.end.y - $0.start.y, $0.end.x - $0.start.x) }
            if let rotation, distance > 0.001 {
                // Both sides in SCREEN space, by projecting the needle's own
                // tip. Comparing the sprite's world rotation against a screen
                // angle works only while the camera is unrotated, and the
                // camera can be rotated — the drawn needle would have been in
                // one place and its grab band in another.
                let tipWorld = center + SIMD2<Float>(cos(rotation), sin(rotation))
                    * (RotateGizmoMetrics.needleOuterPx / max(zoom, 0.0001))
                let tipScreen = camera?.worldToScreen(tipWorld, viewSize: viewSize)
                    ?? (tipWorld + viewSize * 0.5)
                let needleDirection = tipScreen - centerScreen
                if simd_length(needleDirection) > 0.001 {
                    let toPoint = screenPoint - centerScreen
                    var delta = atan2(needleDirection.x * toPoint.y - needleDirection.y * toPoint.x,
                                      simd_dot(needleDirection, toPoint))
                    while delta > .pi { delta -= 2 * .pi }
                    while delta < -.pi { delta += 2 * .pi }
                    if RotateGizmoMetrics.grabsNeedle(distancePx: distance,
                                                      angleDelta: delta,
                                                      hitScale: hitScale) {
                        return .rotateRing
                    }
                }
            }
            return nil
        case .scale:
            if selectedImage == nil, selectedBoneSegment != nil {
                let axisLength = Float(94.0 / max(zoom, 0.001))
                let xHandle = center + SIMD2<Float>(axisLength, 0)
                let xScreen = camera?.worldToScreen(xHandle, viewSize: viewSize) ?? (xHandle + viewSize * 0.5)
                if pointNearSegment(point: screenPoint, start: centerScreen, end: xScreen, radius: 13 * hitScale) {
                    return .scaleCorner(0)
                }
                if simd_length(screenPoint - xScreen) < 16 * hitScale {
                    return .scaleCorner(2)
                }
                return nil
            }
            let axisLength = Float(80.0 / max(zoom, 0.001))
            let xHandle = center + SIMD2<Float>(axisLength, 0)
            let yHandle = center + SIMD2<Float>(0, axisLength)
            let uHandle = center + SIMD2<Float>(axisLength * 0.78, axisLength * 0.78)
            let xScreen = camera?.worldToScreen(xHandle, viewSize: viewSize) ?? (xHandle + viewSize * 0.5)
            let yScreen = camera?.worldToScreen(yHandle, viewSize: viewSize) ?? (yHandle + viewSize * 0.5)
            let uScreen = camera?.worldToScreen(uHandle, viewSize: viewSize) ?? (uHandle + viewSize * 0.5)
            if pointNearSegment(point: screenPoint, start: centerScreen, end: xScreen, radius: 13 * hitScale) { return .scaleCorner(0) }
            if pointNearSegment(point: screenPoint, start: centerScreen, end: yScreen, radius: 13 * hitScale) { return .scaleCorner(1) }
            if simd_length(screenPoint - uScreen) < 16 * hitScale { return .scaleCorner(2) }
            return nil
        case .skew:
            // The same fixed radius the gizmo draws at. It used to measure the
            // sprite's transformed corners, so the grab band moved as the
            // sprite sheared — away from the arcs the artist was aiming at.
            guard let image = selectedImage else { return nil }
            let distance = simd_length(screenPoint - centerScreen)
            guard SkewGizmoMetrics.grabsTrack(distancePx: distance, hitScale: hitScale) else {
                return nil
            }
            // Which arc: whichever handle the click is nearer to, in screen
            // space, so the answer survives a rotated camera.
            let limit = SkewGizmoMetrics.maxSweepDegrees * .pi / 180
            var best: (handle: GizmoHandle, distance: Float)?
            for (index, axis) in [Float(0), .pi / 2].enumerated() {
                let degrees = index == 0 ? image.skew.x : image.skew.y
                let angle = max(-limit, min(limit, degrees * .pi / 180))
                let world = center + SIMD2<Float>(cos(axis + angle), sin(axis + angle))
                    * (SkewGizmoMetrics.trackRadiusPx / max(zoom, 0.0001))
                let screen = camera?.worldToScreen(world, viewSize: viewSize)
                    ?? (world + viewSize * 0.5)
                let reach = simd_length(screenPoint - screen)
                if best == nil || reach < best!.distance {
                    best = (.skewEdge(index), reach)
                }
            }
            return best?.handle
        case .mesh:
            // ONE projection for both questions. Asked separately they
            // resolved the mesh three times between them, on every pointer
            // move, and `sanitizedForRender` is not a thing to run three times
            // per move.
            guard let projection = meshProjection(scene: scene, assets: assets,
                                                  camera: camera, viewSize: viewSize) else { return nil }
            if let vertex = hitTestMeshVertex(screenPoint: screenPoint, projection: projection) {
                return .meshVertex(vertex)
            }
            return hitTestMeshInternalEdge(screenPoint: screenPoint,
                                           projection: projection).map { .meshInternalEdge($0) }
        case .physicsPreview:
            return nil
        }
    }

    /// The rectangle a sprite is framed by, in its own local space.
    ///
    /// The PNG's rectangle until the sprite is traced; the mesh's own bounds
    /// after that — and that is for more than looks. This
    /// quad is also what picking tests, what the rubber band intersects and
    /// what the skew gizmo sizes itself from, so an arm traced out of a
    /// 512 x 512 sheet used to be selectable by clicking the empty corner, and
    /// its gizmo drawn for an object nine times the size of the one on screen.
    ///
    /// A CENTRE AS WELL AS A SIZE. A mesh is not centred on the sprite's
    /// origin, so a frame that keeps the origin as its centre is still the
    /// wrong rectangle.
    ///
    /// Derived, never stored: a stored frame is one more thing every mesh edit
    /// has to remember to update, and the first edit that forgets leaves a
    /// frame that is wrong in a way nothing afterwards can detect.
    struct LocalFrame {
        var center: SIMD2<Float>
        var size: SIMD2<Float>
    }

    static func localFrame(for image: SceneImage, assetSize: SIMD2<Float>) -> LocalFrame {
        let vertices = image.mesh.vertices
        guard !vertices.isEmpty else {
            return LocalFrame(center: .zero, size: assetSize)
        }
        var minPoint = vertices[0]
        var maxPoint = vertices[0]
        for vertex in vertices.dropFirst() {
            minPoint = simd_min(minPoint, vertex)
            maxPoint = simd_max(maxPoint, vertex)
        }
        return LocalFrame(center: (minPoint + maxPoint) * 0.5,
                          size: maxPoint - minPoint)
    }

    static func transformedCorners(for image: SceneImage,
                                   frame: LocalFrame,
                                   shearOverride: SIMD2<Float>? = nil) -> [SIMD2<Float>] {
        let halfWidth = frame.size.x * 0.5
        let halfHeight = frame.size.y * 0.5
        let center = frame.center
        let local = [
            SIMD2<Float>(center.x - halfWidth, center.y + halfHeight),
            SIMD2<Float>(center.x + halfWidth, center.y + halfHeight),
            SIMD2<Float>(center.x - halfWidth, center.y - halfHeight),
            SIMD2<Float>(center.x + halfWidth, center.y - halfHeight)
        ]
        let rotationDeg = image.rotation * 180 / Float.pi
        let shear = shearOverride ?? image.skew
        return local.map { p in
            MatrixUtilities.shearedWorldTransform(
                local: p,
                position: image.position,
                rotation: rotationDeg,
                shear: shear,
                scale: image.scale
            )
        }
    }

    static func transformedVertices(for image: SceneImage, mesh: Mesh) -> [SIMD2<Float>] {
        transformedVertices(for: image, localVertices: mesh.vertices)
    }

    static func transformedVertices(for image: SceneImage, localVertices: [SIMD2<Float>], shearOverride: SIMD2<Float>? = nil) -> [SIMD2<Float>] {
        let rotationDeg = image.rotation * 180 / Float.pi
        let shear = shearOverride ?? image.skew
        return localVertices.map { vertex in
            MatrixUtilities.shearedWorldTransform(
                local: vertex,
                position: image.position,
                rotation: rotationDeg,
                shear: shear,
                scale: image.scale
            )
        }
    }

    /// The selected sprite's mesh, skinned and projected to the screen, ONCE.
    ///
    /// `resolvedMesh` runs `sanitizedForRender`, which rebuilds the hull,
    /// re-walks every triangle and rebuilds the per-vertex skinning tables.
    /// It is documented as a once-per-sprite-per-frame cost. The pointer path
    /// was paying it four times per MOUSE MOVE: the node test resolved once,
    /// the internal-edge test resolved twice (once for the mesh, once more
    /// inside `skinnedLocalVertices`), and the hover then asked the node
    /// question a second time. On a mesh of any size that is what made
    /// selecting one feel like the canvas had stopped responding.
    ///
    /// A value, not a cache: it is built at the start of an event and handed
    /// to every hit test in that event, so it cannot go stale between one and
    /// the next. Staleness is the failure that matters here — a hit test run
    /// against out-of-date positions puts the selection radius somewhere other
    /// than the marker the artist can see.
    struct MeshProjection {
        let imageID: UUID
        let mesh: Mesh
        /// Screen positions, one per mesh vertex, in vertex order.
        let screenVertices: [SIMD2<Float>]
        /// How close a click has to land, in points. Comes from
        /// `MeshOverlayMetrics`, so it tracks the size the node is DRAWN at:
        /// stated separately the two drifted, and weight paint's deliberately
        /// large nodes had a visible outer ring that was not clickable.
        let grabRadius: Float
    }

    static func meshProjection(scene: SceneManager,
                               assets: AssetManager,
                               camera: CameraState?,
                               viewSize: SIMD2<Float>) -> MeshProjection? {
        guard let selectedID = scene.selectedImageID,
              let image = scene.image(for: selectedID),
              let asset = assets.asset(for: image.assetID) else { return nil }
        let mesh = resolvedMesh(for: image, assetSize: asset.size)
        // Skinned, to match what the overlay draws. Hit-testing against
        // unskinned positions put the selection radius somewhere other than
        // the marker the artist can see, on every mesh bound to a bone.
        let localVertices = scene.skinnedLocalVertices(
            for: image, assetSize: asset.size,
            showDeformed: scene.isMeshOverlayDeformed, mesh: mesh)
        let worldVertices = transformedVertices(for: image, localVertices: localVertices)
        return MeshProjection(
            imageID: selectedID,
            mesh: mesh,
            screenVertices: worldVertices.map { world in
                camera?.worldToScreen(world, viewSize: viewSize) ?? (world + viewSize * 0.5)
            },
            grabRadius: MeshOverlayMetrics.grabRadiusPx(
                weightPainting: scene.meshWeightPaintEnabled) * touchHitScale
        )
    }

    static func hitTestMeshVertex(screenPoint: SIMD2<Float>,
                                  projection: MeshProjection) -> Int? {
        let radius = projection.grabRadius
        var bestIndex: Int?
        var bestDistance = Float.greatestFiniteMagnitude
        for (index, vertex) in projection.screenVertices.enumerated() {
            let distance = simd_length(screenPoint - vertex)
            if distance <= radius, distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    /// Convenience for a caller with nothing else to ask of the mesh.
    static func hitTestMeshVertex(screenPoint: SIMD2<Float>,
                                  viewSize: SIMD2<Float>,
                                  scene: SceneManager,
                                  assets: AssetManager,
                                  camera: CameraState?) -> Int? {
        guard let projection = meshProjection(scene: scene, assets: assets,
                                              camera: camera, viewSize: viewSize) else { return nil }
        return hitTestMeshVertex(screenPoint: screenPoint, projection: projection)
    }

    static func hitTestMeshHullEdge(screenPoint: SIMD2<Float>,
                                    projection: MeshProjection) -> Int? {
        let mesh = projection.mesh
        let screenVertices = projection.screenVertices
        guard mesh.hullVertexIndices.count > 1 else { return nil }
        let radius: Float = 10 * touchHitScale
        var bestEdge: Int?
        var bestDistance = Float.greatestFiniteMagnitude
        for edgeIndex in mesh.hullVertexIndices.indices {
            let startIndex = Int(mesh.hullVertexIndices[edgeIndex])
            let endIndex = Int(mesh.hullVertexIndices[(edgeIndex + 1) % mesh.hullVertexIndices.count])
            guard screenVertices.indices.contains(startIndex),
                  screenVertices.indices.contains(endIndex) else {
                continue
            }
            let distance = distancePointToSegment(point: screenPoint, a: screenVertices[startIndex], b: screenVertices[endIndex])
            if distance <= radius, distance < bestDistance {
                bestDistance = distance
                bestEdge = edgeIndex
            }
        }
        return bestEdge
    }

    static func hitTestMeshVertices(rect: CGRect, projection: MeshProjection) -> Set<Int> {
        var hits: Set<Int> = []
        for (index, screen) in projection.screenVertices.enumerated() {
            if rect.contains(CGPoint(x: CGFloat(screen.x), y: CGFloat(screen.y))) {
                hits.insert(index)
            }
        }
        return hits
    }

    /// Convenience for a caller with nothing else to ask of the mesh.
    static func hitTestMeshVertices(rect: CGRect,
                                    viewSize: SIMD2<Float>,
                                    scene: SceneManager,
                                    assets: AssetManager,
                                    camera: CameraState?) -> Set<Int> {
        guard let projection = meshProjection(scene: scene, assets: assets,
                                              camera: camera, viewSize: viewSize) else { return [] }
        return hitTestMeshVertices(rect: rect, projection: projection)
    }

    static func hitTestMeshInternalEdge(screenPoint: SIMD2<Float>,
                                        projection: MeshProjection) -> Int? {
        let mesh = projection.mesh
        let screenVertices = projection.screenVertices
        let radius: Float = 10 * touchHitScale
        var bestEdge: Int?
        var bestDistance = Float.greatestFiniteMagnitude
        for (edgeIndex, edge) in mesh.internalEdges.enumerated() {
            let startIndex = Int(edge.a)
            let endIndex = Int(edge.b)
            guard screenVertices.indices.contains(startIndex),
                  screenVertices.indices.contains(endIndex) else {
                continue
            }
            let distance = distancePointToSegment(point: screenPoint, a: screenVertices[startIndex], b: screenVertices[endIndex])
            if distance <= radius, distance < bestDistance {
                bestDistance = distance
                bestEdge = edgeIndex
            }
        }
        return bestEdge
    }

    /// Convenience for a caller with nothing else to ask of the mesh.
    static func hitTestMeshInternalEdge(screenPoint: SIMD2<Float>,
                                        viewSize: SIMD2<Float>,
                                        scene: SceneManager,
                                        assets: AssetManager,
                                        camera: CameraState?) -> Int? {
        guard let projection = meshProjection(scene: scene, assets: assets,
                                              camera: camera, viewSize: viewSize) else { return nil }
        return hitTestMeshInternalEdge(screenPoint: screenPoint, projection: projection)
    }

    /// Convenience for a caller with nothing else to ask of the mesh.
    static func hitTestMeshHullEdge(screenPoint: SIMD2<Float>,
                                    viewSize: SIMD2<Float>,
                                    scene: SceneManager,
                                    assets: AssetManager,
                                    camera: CameraState?) -> Int? {
        guard let projection = meshProjection(scene: scene, assets: assets,
                                              camera: camera, viewSize: viewSize) else { return nil }
        return hitTestMeshHullEdge(screenPoint: screenPoint, projection: projection)
    }

    static func hitTestBone(
        screenPoint: SIMD2<Float>,
        viewSize: SIMD2<Float>,
        scene: SceneManager,
        camera: CameraState?
    ) -> UUID? {
        hitTestBoneDetailed(screenPoint: screenPoint, viewSize: viewSize,
                            scene: scene, camera: camera)?.id
    }

    /// The same pick, plus how far away the winner actually was.
    ///
    /// The distance is what lets `CanvasPicking` tell a click that landed ON a
    /// bone from one that landed within its capture radius. Without it, a bone
    /// 25pt away could not be distinguished from a bone under the cursor, and
    /// so always beat a sprite — which is exactly what it used to do.
    static func hitTestBoneDetailed(
        screenPoint: SIMD2<Float>,
        viewSize: SIMD2<Float>,
        scene: SceneManager,
        camera: CameraState?
    ) -> (id: UUID, distance: Float)? {
        let segments = scene.skeleton.worldLineSegments()
        guard !segments.isEmpty else { return nil }

#if os(iOS)
        // ── Touch-optimised bone picking ─────────────────────────────────
        // Finger-sized capture areas plus a probability score, so a single
        // tap always lands on the bone the user most plausibly meant:
        //   • joints beat shafts (they are the primary manipulation points)
        //   • visually smaller bones beat large ones when both are in range
        //     (a big parent shaft must never swallow the tiny finger bone
        //     drawn on top of it)
        //   • bones drawn later (children, higher in the draw order) win ties
        //   • the currently selected bone is slightly de-prioritised, so a
        //     tap near a *different* bone switches selection with one touch
        //     instead of feeling locked to the previous choice.
        let scale = displayScale
        let jointRadius: Float = 26 * scale   // ≈ 26 pt capture around joints
        let lineRadius: Float  = 16 * scale   // ≈ 16 pt capture along shafts
        let selectedID = scene.selectedBoneID

        struct Candidate {
            let id: UUID
            let score: Float
            /// Raw screen distance, untouched by the scoring. The score decides
            /// WHICH bone; this says how near the click really was.
            let distance: Float
        }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(4)

        for (index, entry) in segments.enumerated() {
            let (bone, start, end) = entry
            let startScreen = camera?.worldToScreen(start, viewSize: viewSize) ?? (start + viewSize * 0.5)
            let endScreen   = camera?.worldToScreen(end,   viewSize: viewSize) ?? (end   + viewSize * 0.5)

            let jointDistance = min(simd_distance(screenPoint, startScreen),
                                    simd_distance(screenPoint, endScreen))
            let lineDistance = distancePointToSegment(point: screenPoint, a: startScreen, b: endScreen)

            let isJointHit = jointDistance <= jointRadius
            let isLineHit  = lineDistance <= lineRadius
            guard isJointHit || isLineHit else { continue }

            // Base score: normalised distance in [0, 1] — smaller is better.
            var score: Float
            if isJointHit {
                score = jointDistance / jointRadius
                score -= 0.35   // joints are the intended grab points
            } else {
                score = lineDistance / lineRadius
            }

            // Small bones are harder to hit — give them the benefit of the
            // doubt over long shafts passing through the same touch area.
            let screenLength = simd_distance(startScreen, endScreen)
            if screenLength < 44 * scale {
                score -= 0.18
            }

            // Bones drawn later sit visually on top; nudge them ahead.
            score -= Float(index) / Float(max(segments.count, 1)) * 0.05

            // Never let the current selection out-compete a clearly intended
            // tap on a neighbouring bone.
            if bone.id == selectedID {
                score += 0.22
            }

            candidates.append(Candidate(id: bone.id, score: score,
                                        distance: min(jointDistance, lineDistance)))
        }

        guard let best = candidates.min(by: { $0.score < $1.score }) else { return nil }
        return (best.id, best.distance)
#else
        let jointRadius: Float = 12
        let lineRadius: Float = 9
        var bestID: UUID?
        var bestDistance = Float.greatestFiniteMagnitude

        for (bone, start, end) in segments {
            let startScreen = camera?.worldToScreen(start, viewSize: viewSize) ?? (start + viewSize * 0.5)
            let endScreen = camera?.worldToScreen(end, viewSize: viewSize) ?? (end + viewSize * 0.5)
            let jointDistance = min(simd_distance(screenPoint, startScreen), simd_distance(screenPoint, endScreen))
            if jointDistance <= jointRadius, jointDistance < bestDistance {
                bestDistance = jointDistance
                bestID = bone.id
                continue
            }
            let lineDistance = distancePointToSegment(point: screenPoint, a: startScreen, b: endScreen)
            if lineDistance <= lineRadius, lineDistance < bestDistance {
                bestDistance = lineDistance
                bestID = bone.id
            }
        }

        guard let bestID else { return nil }
        return (bestID, bestDistance)
#endif
    }

    /// Whether a click in MESH mode may move the selection to the sprite it
    /// landed on.
    ///
    /// In Mesh mode a click is an EDIT — add a node, grab a vertex, drop a hull
    /// point — and it lands wherever the node has to go, which is often on a
    /// sprite drawn in front of the one being meshed. Re-picking on every click
    /// made it impossible to mesh anything with another PNG over it: the first
    /// node went to the sprite on top. So a single click never changes the
    /// selection here. A DOUBLE click does — that is the one gesture that
    /// cannot be an edit — and a click when nothing is selected picks, because
    /// there is nothing to protect. The sprite already selected stays
    /// re-selectable, so `selectMeshLayer` can still flip it into mesh-layer
    /// selection.
    ///
    /// One rule for `MeshTool.onMouseDown` and for `ToolManager`'s selection
    /// block on iPadOS, which otherwise switches on a single tap. Two copies is
    /// how one of them would keep switching.
    static func meshModeMayChangeSelection(to hitID: UUID,
                                           selectedID: UUID?,
                                           clickCount: Int) -> Bool {
        guard let selectedID else { return true }
        return clickCount >= 2 || hitID == selectedID
    }

    /// Whether a screen-space segment touches a rectangle.
    ///
    /// Liang-Barsky, because the cheap answer is wrong in a way that shows.
    /// Testing "do the x ranges overlap AND do the y ranges overlap" catches a
    /// diagonal bone that passes well OUTSIDE the near corner: both ranges
    /// overlap and the segment never comes near the box. In a rig that is a
    /// forearm two hand-widths away joining the selection because its bounding
    /// box happened to straddle the marquee.
    ///
    /// The other half matters as much: a bone whose BOTH joints are outside the
    /// box but whose shaft crosses it is caught. A spine or a thigh at working
    /// zoom is longer than the marquee, and an endpoint test misses exactly the
    /// bones a box is most often dragged over.
    static func segmentIntersectsRect(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ rect: CGRect) -> Bool {
        let minX = Float(rect.minX), maxX = Float(rect.maxX)
        let minY = Float(rect.minY), maxY = Float(rect.maxY)
        func contains(_ p: SIMD2<Float>) -> Bool {
            p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
        }
        if contains(a) || contains(b) { return true }

        let d = b - a
        var t0: Float = 0, t1: Float = 1
        let clips: [(Float, Float)] = [
            (-d.x, a.x - minX), (d.x, maxX - a.x),
            (-d.y, a.y - minY), (d.y, maxY - a.y)
        ]
        for (p, q) in clips {
            if p == 0 {
                if q < 0 { return false }   // parallel to this edge, and outside it
                continue
            }
            let r = q / p
            if p < 0 {
                if r > t1 { return false }
                t0 = max(t0, r)
            } else {
                if r < t0 { return false }
                t1 = min(t1, r)
            }
        }
        return t0 <= t1
    }

    /// The bones a marquee catches, in SKELETON order.
    ///
    /// The order is the point: it is what `setBoneSelection` turns into the
    /// selection order, so dragging the same box twice gives the same active
    /// bone and the same inspector. A Set of hits could not promise that.
    static func bonesIntersecting(rect: CGRect,
                                  viewSize: SIMD2<Float>,
                                  scene: SceneManager,
                                  camera: CameraState?) -> [UUID] {
        var hits: [UUID] = []
        for (bone, start, end) in scene.skeleton.worldLineSegments() {
            let startScreen = camera?.worldToScreen(start, viewSize: viewSize)
                ?? (start + viewSize * 0.5)
            let endScreen = camera?.worldToScreen(end, viewSize: viewSize)
                ?? (end + viewSize * 0.5)
            if segmentIntersectsRect(startScreen, endScreen, rect) {
                hits.append(bone.id)
            }
        }
        return hits
    }

    /// Whether a click on a bone may arm it for the weight brush.
    ///
    /// The same shape as the rule above, for the same reason. In weight paint a
    /// single click is an EDIT — it stamps the brush — and it lands wherever
    /// the weights have to go, which over a limb is directly on top of the very
    /// bones being painted. Arming on a single click would make the weights
    /// over every bone unpaintable: the dab would arm the bone under it
    /// instead. So a double click arms, being the one gesture that cannot be a
    /// stamp; and with nothing armed yet there is no stroke to protect, so a
    /// single click is enough.
    ///
    /// `bound` is the set the sprite is actually bound to. A bone with no
    /// binding has no colour and nothing to paint into, so it cannot be armed
    /// however it is clicked.
    static func weightPaintMayChangeBone(to hitID: UUID,
                                         armedBoneID: UUID?,
                                         boundBoneIDs: Set<UUID>,
                                         clickCount: Int) -> Bool {
        guard boundBoneIDs.contains(hitID) else { return false }
        guard let armedBoneID else { return true }
        return clickCount >= 2 || hitID == armedBoneID
    }

    static func hitTestSelectionTarget(
        screenPoint: SIMD2<Float>,
        worldPoint: SIMD2<Float>,
        viewSize: SIMD2<Float>,
        scene: SceneManager,
        assets: AssetManager,
        camera: CameraState?
    ) -> SelectionTarget? {
        // `worldPoint` is no longer consulted. It used to feed a bounding-quad
        // fallback that fired whenever the alpha test correctly said "no", which
        // meant the alpha test could never change an outcome. Kept in the
        // signature because every caller has it and removing it buys nothing.
        _ = worldPoint
        return CanvasPicking.target(screenPoint: screenPoint, viewSize: viewSize,
                                    scene: scene, assets: assets, camera: camera)
    }

    static func localCoordinates(for worldPoint: SIMD2<Float>, image: SceneImage) -> SIMD2<Float> {
        MatrixUtilities.shearedWorldInverse(
            world: worldPoint,
            position: image.position,
            rotation: image.rotation * 180 / Float.pi,
            shear: image.skew,
            scale: image.scale
        )
    }

    static func resolvedMesh(for image: SceneImage, assetSize: SIMD2<Float>) -> Mesh {
        if image.mesh.vertices.isEmpty || image.mesh.uvs.count != image.mesh.vertices.count || image.mesh.indices.isEmpty {
            return Mesh.makeQuad(name: "\(image.name) Mesh", size: assetSize)
        }
        return image.mesh.sanitizedForRender(size: assetSize)
    }

    /// The mesh the editing overlay should draw — never a fabricated one.
    ///
    /// `resolvedMesh` substitutes `Mesh.makeQuad` when a sprite has no triangle
    /// list. That is right for RENDERING, where the sprite must still appear,
    /// and wrong for the overlay: while the artist is drawing a new outline
    /// `indices` is legitimately empty, and the substitute painted a phantom
    /// four-corner contour with four selectable markers that exist nowhere in
    /// `image.mesh`. Clicking one selected a vertex that was not there, and the
    /// contour appeared at moments when there was nothing to contour.
    ///
    /// Returns nil when there is genuinely nothing to draw.
    static func overlayMesh(for image: SceneImage, assetSize: SIMD2<Float>) -> Mesh? {
        guard !image.mesh.vertices.isEmpty,
              image.mesh.uvs.count == image.mesh.vertices.count else { return nil }
        // Mid-creation the outline is still being placed: show exactly the
        // points that exist, with no sanitising to invent a hull for them.
        if image.mesh.indices.isEmpty { return image.mesh }
        return image.mesh.sanitizedForRender(size: assetSize)
    }

    static func editLocalVertices(for image: SceneImage, assetSize: SIMD2<Float>, showDeformed: Bool) -> [SIMD2<Float>] {
        editLocalVertices(for: image, assetSize: assetSize, showDeformed: showDeformed,
                          mesh: resolvedMesh(for: image, assetSize: assetSize))
    }

    /// Same, reusing a mesh the caller has already resolved.
    ///
    /// `resolvedMesh` runs `sanitizedForRender`, which rebuilds the hull, the
    /// triangle list and the skinning tables and copies every array. Callers
    /// that need both the mesh and its vertices were paying for that twice per
    /// sprite per frame.
    static func editLocalVertices(for image: SceneImage, assetSize: SIMD2<Float>,
                                  showDeformed: Bool, mesh: Mesh) -> [SIMD2<Float>] {
        if showDeformed, let deform = image.meshAnimationDeform,
           deform.count == mesh.vertices.count {
            return deform
        }
        // The bind mesh, never a re-derivation from the uvs.
        //
        // "Show deform off" used to return `uvs.map(localPosition)`, which is
        // only the same thing while position and uv agree. Editing pulled them
        // apart — a drag moves both, and anything that moved one alone left the
        // overlay drawing one answer while the renderer drew the other. There
        // is one array that means "where the mesh points are", and this is it.
        _ = assetSize
        return mesh.vertices
    }

    static func softSelectionWeights(
        for image: SceneImage,
        assetSize: SIMD2<Float>,
        selectedIndices: Set<Int>,
        showDeformed: Bool,
        radius: Float,
        feather: Float,
        excludeHull: Bool
    ) -> [Int: Float] {
        guard !selectedIndices.isEmpty else { return [:] }
        let mesh = resolvedMesh(for: image, assetSize: assetSize)
        let localVertices = editLocalVertices(for: image, assetSize: assetSize, showDeformed: showDeformed)
        guard !localVertices.isEmpty else { return [:] }

        let clampedRadius = max(radius, 0.0001)
        let clampedFeather = max(0, min(1, feather))
        let innerRadius = clampedRadius * (1 - clampedFeather)
        let falloffRange = max(clampedRadius - innerRadius, 0.0001)
        let hullSet = excludeHull ? Set(mesh.hullVertexIndices.map(Int.init)) : []
        let selectedPositions = selectedIndices.compactMap { index -> SIMD2<Float>? in
            guard localVertices.indices.contains(index) else { return nil }
            return localVertices[index]
        }
        guard !selectedPositions.isEmpty else { return [:] }

        var weights: [Int: Float] = [:]
        weights.reserveCapacity(localVertices.count)

        for (index, vertex) in localVertices.enumerated() {
            if selectedIndices.contains(index) {
                weights[index] = 1
                continue
            }
            if hullSet.contains(index) {
                continue
            }

            let minDistance = selectedPositions.reduce(Float.greatestFiniteMagnitude) { partial, selected in
                min(partial, simd_distance(vertex, selected))
            }
            guard minDistance <= clampedRadius else { continue }

            if minDistance <= innerRadius {
                weights[index] = 1
            } else {
                let normalized = 1 - ((minDistance - innerRadius) / falloffRange)
                let eased = normalized * normalized * (3 - 2 * normalized)
                if eased > 0.001 {
                    weights[index] = eased
                }
            }
        }

        return weights
    }

    static func boundsForImage(_ image: SceneImage, asset: TextureAsset) -> Bounds2D {
        let size = SIMD2<Float>(Float(asset.texture.width),
                                Float(asset.texture.height))
        let corners = transformedCorners(for: image, frame: localFrame(for: image, assetSize: size))
        var bounds = Bounds2D.empty()
        corners.forEach { bounds.include($0) }
        return bounds
    }

    static func boundsForScene(scene: SceneManager, assets: AssetManager) -> Bounds2D? {
        var bounds = Bounds2D.empty()
        var hasAny = false
        for image in scene.images where !image.isHidden {
            guard let asset = assets.asset(for: image.assetID) else { continue }
            let imageBounds = boundsForImage(image, asset: asset)
            if imageBounds.isValid {
                bounds.include(imageBounds.min)
                bounds.include(imageBounds.max)
                hasAny = true
            }
        }
        return hasAny ? bounds : nil
    }

    /// The sprite under a screen point. Delegates, so the tools that ask for
    /// an image and the selection that asks for "anything" agree by
    /// construction rather than by two transcriptions staying in step.
    ///
    /// What it used to do differently, and why none of it survived: it walked
    /// the hierarchy rather than the draw order, it let a 12pt near-miss on one
    /// sprite return before a later sprite's opaque pixel was ever considered,
    /// and it knew nothing about skins — so a sprite the active skin had
    /// displaced off screen was still selectable.
    static func hitTestScreen(screenPoint: SIMD2<Float>,
                              viewSize: SIMD2<Float>,
                              scene: SceneManager,
                              assets: AssetManager,
                              camera: CameraState?) -> UUID? {
        guard case .image(let id)? = CanvasPicking.imageHit(
            screenPoint: screenPoint, viewSize: viewSize,
            scene: scene, assets: assets, camera: camera
        )?.kind else { return nil }
        return id
    }

    /// Rubber-band selection, through the same shape a click tests.
    ///
    /// It used to intersect the sprite's full sheet, in hierarchy order, with
    /// no knowledge of skins — so dragging a band across empty canvas could
    /// sweep up an arm whose art was nowhere near it, and sprites a skin had
    /// displaced off screen came along too.
    ///
    /// The band tests the sprite's SILHOUETTE — its drawn triangles — rather
    /// than each texel under the band. That is the honest granularity for a
    /// sweep: a band is a coarse gesture over an area, and per-texel would mean
    /// rasterising every sprite against the rectangle for a result no artist
    /// could predict. For a traced sprite the silhouette IS the alpha outline;
    /// for an untraced one the opaque box is what bounds it, which is still the
    /// art rather than the sheet.
    static func hitTestRect(rect: CGRect,
                            viewSize: SIMD2<Float>,
                            scene: SceneManager,
                            assets: AssetManager,
                            camera: CameraState?) -> [UUID] {
        var hits: [UUID] = []
        for image in scene.renderOrderedImages where !image.isHidden {
            guard let asset = assets.asset(for: image.assetID) else { continue }
            // Entirely transparent art is not something a band can catch.
            guard assets.opaqueBounds(assetID: image.assetID) != nil else { continue }
            guard let geometry = CanvasPicking.screenGeometry(
                image: image, asset: asset, scene: scene,
                viewSize: viewSize, camera: camera
            ) else { continue }
            if geometryIntersectsRect(geometry, rect: rect) {
                hits.append(image.id)
            }
        }
        return hits
    }

    private static func geometryIntersectsRect(_ geometry: CanvasPicking.ScreenGeometry,
                                               rect: CGRect) -> Bool {
        let rectMin = SIMD2<Float>(Float(rect.minX), Float(rect.minY))
        let rectMax = SIMD2<Float>(Float(rect.maxX), Float(rect.maxY))

        // Any drawn vertex inside the band.
        for vertex in geometry.screenVertices {
            if vertex.x >= rectMin.x, vertex.x <= rectMax.x,
               vertex.y >= rectMin.y, vertex.y <= rectMax.y {
                return true
            }
        }
        // Or the band entirely inside the sprite — a small band dropped in the
        // middle of a large one catches no vertex at all.
        let centre = (rectMin + rectMax) * 0.5
        if CanvasPicking.uv(at: centre, geometry: geometry) != nil { return true }
        for corner in [rectMin, SIMD2<Float>(rectMax.x, rectMin.y),
                       rectMax, SIMD2<Float>(rectMin.x, rectMax.y)] {
            if CanvasPicking.uv(at: corner, geometry: geometry) != nil { return true }
        }
        return false
    }

    private static func pointNearSegment(point: SIMD2<Float>,
                                         start: SIMD2<Float>,
                                         end: SIMD2<Float>,
                                         radius: Float) -> Bool {
        let segment = end - start
        let lengthSquared = simd_length_squared(segment)
        guard lengthSquared > 0.0001 else {
            return simd_length(point - start) <= radius
        }

        let t = max(0, min(1, simd_dot(point - start, segment) / lengthSquared))
        let closest = start + segment * t
        return simd_length(point - closest) <= radius
    }

    // These three stopped being `private` when picking moved to
    // `CanvasPicking`: Swift's `private` is file-scoped, and the picker is a
    // different file. They are geometry, not policy — narrowing them again
    // would mean a second copy of point-in-quad, which is precisely the kind of
    // duplication that let picking and drawing disagree in the first place.
    static func pointInQuad(point: SIMD2<Float>, quad: [SIMD2<Float>]) -> Bool {
        guard quad.count == 4 else { return false }
        return pointInTriangle(point: point, a: quad[0], b: quad[1], c: quad[3])
            || pointInTriangle(point: point, a: quad[0], b: quad[3], c: quad[2])
    }

    private static func pointInTriangle(point: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>, c: SIMD2<Float>) -> Bool {
        let v0 = c - a
        let v1 = b - a
        let v2 = point - a
        let dot00 = simd_dot(v0, v0)
        let dot01 = simd_dot(v0, v1)
        let dot02 = simd_dot(v0, v2)
        let dot11 = simd_dot(v1, v1)
        let dot12 = simd_dot(v1, v2)
        let invDenom = 1 / max(0.0001, (dot00 * dot11 - dot01 * dot01))
        let u = (dot11 * dot02 - dot01 * dot12) * invDenom
        let v = (dot00 * dot12 - dot01 * dot02) * invDenom
        return u >= 0 && v >= 0 && (u + v) <= 1
    }

    static func distanceToQuad(point: SIMD2<Float>, quad: [SIMD2<Float>]) -> Float {
        guard quad.count == 4 else { return Float.greatestFiniteMagnitude }
        let d0 = distancePointToSegment(point: point, a: quad[0], b: quad[1])
        let d1 = distancePointToSegment(point: point, a: quad[1], b: quad[3])
        let d2 = distancePointToSegment(point: point, a: quad[3], b: quad[2])
        let d3 = distancePointToSegment(point: point, a: quad[2], b: quad[0])
        return min(d0, d1, d2, d3)
    }

    // Not `private`, for the same reason as `pointInQuad` above: `CanvasPicking`
    // measures the reach to a sprite's triangles with it, and Swift's `private`
    // is file-scoped.
    static func distancePointToSegment(point: SIMD2<Float>, a: SIMD2<Float>, b: SIMD2<Float>) -> Float {
        let ab = b - a
        let t = max(0, min(1, simd_dot(point - a, ab) / max(0.0001, simd_dot(ab, ab))))
        let proj = a + ab * t
        return simd_length(point - proj)
    }

    static func edgeMidpoints(from corners: [SIMD2<Float>]) -> [SIMD2<Float>] {
        guard corners.count == 4 else { return [] }
        return [
            (corners[0] + corners[1]) * 0.5,
            (corners[1] + corners[3]) * 0.5,
            (corners[2] + corners[3]) * 0.5,
            (corners[0] + corners[2]) * 0.5
        ]
    }

    static func defaultHandle(for tool: ActiveTool) -> GizmoHandle {
        switch tool {
        case .move, .select:
            return .moveCenter
        case .bone:
            return .moveCenter
        case .mesh:
            return .moveCenter
        case .rotate:
            return .rotateRing
        case .scale:
            return .scaleCorner(0)
        case .skew:
            return .skewEdge(0)
        case .physicsPreview:
            return .moveCenter
        }
    }

    private static func applySkewPerspective(point: SIMD2<Float>, center: SIMD2<Float>) -> SIMD2<Float> {
        let yaw = Float(30.0 * Double.pi / 180.0)
        let roll = Float(10.0 * Double.pi / 180.0)
        let rotation = MatrixUtilities.rotationZ(roll) * MatrixUtilities.rotationY(yaw)
        let perspective = MatrixUtilities.perspective(m34: -1.0 / 500.0)
        let matrix = perspective * rotation

        let local = SIMD3<Float>(point.x - center.x, point.y - center.y, 0)
        let projected = MatrixUtilities.transformPoint(local, with: matrix)
        return SIMD2<Float>(center.x + projected.x, center.y + projected.y)
    }

    static func project3DToScreen(point: SIMD2<Float>, center: SIMD2<Float>, rotationZ: Float, rotation3D: SIMD3<Float>, viewSize: SIMD2<Float>, camera: CameraState?) -> SIMD2<Float> {
        let screenPoint = camera?.worldToScreen(point, viewSize: viewSize) ?? (point + viewSize * 0.5)
        let centerScreen = camera?.worldToScreen(center, viewSize: viewSize) ?? (center + viewSize * 0.5)

        let pitch = rotation3D.x
        let yaw = rotation3D.y
        let rotation3DMatrix = MatrixUtilities.rotationY(yaw) * MatrixUtilities.rotationX(pitch)
        let perspective = MatrixUtilities.perspective(m34: -1.0 / 500.0)
        let matrix = perspective * rotation3DMatrix

        let local = SIMD3<Float>(screenPoint.x - centerScreen.x, screenPoint.y - centerScreen.y, 0)
        let projected = MatrixUtilities.transformPoint(local, with: matrix)
        return SIMD2<Float>(centerScreen.x + projected.x, centerScreen.y + projected.y)
    }

    private static func screenToWorld(_ lengthPt: Float, zoom: Float) -> Float {
        lengthPt / max(zoom, 0.0001)
    }

    private static func minDistance(point: SIMD2<Float>, polyline: [SIMD2<Float>]) -> Float {
        guard polyline.count > 1 else { return Float.greatestFiniteMagnitude }
        var minDist = Float.greatestFiniteMagnitude
        for i in 0..<(polyline.count - 1) {
            let d = distancePointToSegment(point: point, a: polyline[i], b: polyline[i + 1])
            minDist = min(minDist, d)
        }
        return minDist
    }
}
