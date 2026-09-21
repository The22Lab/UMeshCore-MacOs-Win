import Foundation
import CoreGraphics
import simd

/// What is under the cursor — one answer, one route.
///
/// Picking was spread across `hitTest`, `hitTestScreen` and
/// `hitTestSelectionTarget`, and the three disagreed in ways that added up to
/// "clicking selects the wrong thing":
///
///  * **The alpha test was cancelled by its own fallback.** `hitTestScreen`
///    read the sprite's alpha and skipped transparent pixels — and then
///    `hitTestSelectionTarget` fell back to `hitTest`, which is a plain
///    bounding-quad test. So a click on the empty corner of an arm's 512×512
///    sheet missed on the accurate path and was caught by the inaccurate one.
///    The alpha test could never change an outcome.
///
///  * **A near miss beat a direct hit.** The slop that lets a finger grab a
///    thin sprite (12pt, ~22pt on touch) was checked INSIDE the per-sprite
///    loop and returned immediately. A sprite merely *near* the click won over
///    one whose opaque pixel was *under* it, purely by coming first.
///
///  * **Picking order was not draw order.** Hit-testing walked
///    `displayHierarchyIDs()` — the structural tree — while drawing walks
///    `renderOrderedImages`. Where two sprites overlap, the one you clicked
///    was not reliably the one you saw on top.
///
///  * **Invisible sprites were selectable.** The loop skipped `isHidden` but
///    knew nothing about skins or attachment keys, so a sprite displaced by
///    the active skin — not on screen at all — could be picked.
///
///  * **A bone always won.** `hitTestSelectionTarget` tried bones first and
///    returned on any hit, so a bone 25pt away beat a sprite whose opaque
///    pixel was exactly under the cursor.
///
/// The rule here is evidence, not order: a hit ON something beats a hit NEAR
/// something, whatever kind of thing it is, and ties are broken by what is
/// drawn in front.
enum CanvasPicking {

    /// Alpha at or below this is not the sprite.
    ///
    /// Forwarded rather than restated. `AssetManager.opaqueBounds` scans for
    /// the same thing when it measures the opaque box, and two copies of 0.05
    /// would mean the box could include a texel the click then rejects — a
    /// sprite reachable by the broad phase and unselectable by the exact one.
    static var opaqueThreshold: Float { AssetManager.opaqueCutoffFraction }

    /// How near a bone has to be before it is treated as a direct hit rather
    /// than a near miss. Deliberately much tighter than the capture radius:
    /// the capture radius exists so a bone is easy to grab when nothing else
    /// is there, and this exists so it does not steal a click that plainly
    /// landed on a sprite.
    static var boneDirectRadius: Float { 6 * ToolUtilities.touchHitScale }

    struct Hit {
        enum Kind { case image(UUID), bone(UUID) }
        let kind: Kind
        /// True when the point is ON the thing: an opaque pixel of the sprite,
        /// or within `boneDirectRadius` of the bone. False when it was caught
        /// by the slop that makes thin things grabbable.
        let isDirect: Bool
        /// Screen-space distance in points. Zero for a direct image hit.
        let distance: Float

        var target: ToolUtilities.SelectionTarget {
            switch kind {
            case .image(let id): return .image(id)
            case .bone(let id):  return .bone(id)
            }
        }
    }

    // MARK: - Images

    /// The sprite under `screenPoint`, in draw order, decided by alpha alone.
    ///
    /// Three passes, and the middle one is the whole point.
    ///
    ///  * **Broad phase.** Reject anything whose OPAQUE box — not its sheet —
    ///    is out of reach. An arm traced from a 512×512 sheet stops being a
    ///    candidate once the cursor leaves the arm's neighbourhood, instead of
    ///    the sheet's.
    ///  * **Exact.** Point in a deformed screen-space TRIANGLE, then the UV by
    ///    barycentric interpolation, then the alpha at that UV. Not the affine
    ///    inverse: for a sprite moved by bones or by a deform key the affine
    ///    says nothing about where the art ended up, so the old lookup sampled
    ///    the wrong texel on every skinned sprite in Animator. Going through
    ///    the triangles is also what makes a 3D-rotated sprite alpha-accurate,
    ///    since its vertices are already projected.
    ///  * **Reach.** The small distance that keeps a thin sprite grabbable,
    ///    measured to the triangles, so it hugs the art rather than the sheet.
    static func imageHit(screenPoint: SIMD2<Float>,
                         viewSize: SIMD2<Float>,
                         scene: SceneManager,
                         assets: AssetManager,
                         camera: CameraState?) -> Hit? {
        // Draw order, front first. `renderOrderedImages` is what the renderer
        // draws (reversed, so index 0 lands on top) and it already excludes
        // what a skin or an attachment key has displaced.
        let candidates = scene.renderOrderedImages.filter { !$0.isHidden }
        guard !candidates.isEmpty else { return nil }

        var nearest: (id: UUID, distance: Float)?

        for image in candidates {
            guard let asset = assets.asset(for: image.assetID) else { continue }

            // A sprite with no opaque texels at all is not something a click
            // can land on, whatever its geometry says.
            guard let opaque = assets.opaqueBounds(assetID: image.assetID) else { continue }

            guard let geometry = screenGeometry(image: image, asset: asset, scene: scene,
                                                viewSize: viewSize, camera: camera) else { continue }

            // BROAD PHASE, from the DRAWN vertices.
            //
            // It used to be the opaque box put through the sprite's affine —
            // which describes where the art would be if nothing had moved it.
            // A sprite dragged by a bone leaves that box entirely, so the first
            // version of this rejected art that was plainly under the cursor.
            // Bounding the vertices that were actually drawn cannot be wrong
            // about where the sprite is, because it IS where the sprite is.
            guard withinReach(screenPoint, of: geometry.screenVertices) else { continue }

            if let uv = uv(at: screenPoint, geometry: geometry) {
                if assets.alphaAt(assetID: image.assetID, u: uv.x, v: uv.y) > opaqueThreshold {
                    // Front-most opaque texel. Nothing behind it can beat this.
                    return Hit(kind: .image(image.id), isDirect: true, distance: 0)
                }
                // Inside the art's triangles but on a transparent texel: the
                // click goes straight through. NOT a reach candidate — the
                // distance would be zero and every transparent texel of every
                // sprite would become a zero-distance near miss, which is the
                // bounding-box behaviour this file exists to remove.
                continue
            }

            // REACH. Near the silhouette AND near the opaque region, because
            // neither alone is enough:
            //
            //  * An UNTRACED sprite's silhouette is its sheet, so silhouette
            //    distance alone puts the reach back on the empty corner — the
            //    bug this file was written for.
            //  * A TRACED sprite's opaque box is a rectangle around a shape, so
            //    box distance alone would reach into the notch of a crescent.
            //
            // Whichever is farther decides, which is the conservative reading
            // and the one that hugs the art in both cases.
            let toSilhouette = distanceToGeometry(screenPoint, geometry: geometry)
            let toOpaque = distanceToOpaqueRegion(screenPoint, opaque: opaque, geometry: geometry)
            let distance = max(toSilhouette, toOpaque)
            if distance <= slopRadius, distance < (nearest?.distance ?? .greatestFiniteMagnitude) {
                nearest = (image.id, distance)
            }
        }

        guard let nearest else { return nil }
        return Hit(kind: .image(nearest.id), isDirect: false, distance: nearest.distance)
    }

    /// The reach that makes a thin sprite grabbable. The number is unchanged;
    /// what changed is what it is measured FROM.
    static var slopRadius: Float { 12 * ToolUtilities.touchHitScale }

    // MARK: - Geometry

    struct ScreenGeometry {
        let mesh: Mesh
        /// One screen position per mesh vertex, skinned and deformed exactly as
        /// the renderer draws it.
        let screenVertices: [SIMD2<Float>]
    }

    /// The sprite's drawn shape, in screen space.
    ///
    /// The same four steps `MetalRenderer.drawSceneImages` takes, in the same
    /// order, through the same functions — resolve the mesh, skin it, transform
    /// it, project it. Picking that walks a different path from drawing is how
    /// clicking and seeing came to disagree.
    static func screenGeometry(image: SceneImage,
                               asset: TextureAsset,
                               scene: SceneManager,
                               viewSize: SIMD2<Float>,
                               camera: CameraState?) -> ScreenGeometry? {
        // The frame that was on screen when the click happened. Not an
        // optimisation dressed up as correctness — it IS the more correct
        // answer: the artist clicked what they could see, and re-deriving a
        // fresher pose would test something they were never shown.
        //
        // A missing entry means "compute it", never "no sprite here", so this
        // can only make picking faster. The guard is what keeps that true: a
        // vertex count that does not match the mesh is a half-written or stale
        // entry and is ignored rather than trusted.
        if let cached = scene.lastDrawnGeometry[image.id],
           cached.screenVertices.count == cached.mesh.uvs.count,
           !cached.mesh.indices.isEmpty {
            return cached
        }

        // Through the memo. This is the fallback path for a sprite that was
        // not in the last drawn frame, and it is reached on every hover
        // sample; sanitising walks every triangle and every vertex.
        let mesh = scene.renderMeshCache.resolvedMesh(for: image, assetSize: asset.size)
        guard mesh.indices.count >= 3, !mesh.uvs.isEmpty else { return nil }
        let localVertices = scene.skinnedLocalVertices(
            for: image, assetSize: asset.size,
            showDeformed: scene.isMeshOverlayDeformed, mesh: mesh
        )
        guard localVertices.count == mesh.uvs.count else { return nil }
        let worldVertices = ToolUtilities.transformedVertices(for: image, localVertices: localVertices)
        let has3DRotation = simd_length(image.rotation3D) > 0.0001
        let screenVertices: [SIMD2<Float>] = worldVertices.map { world in
            guard let camera else { return world + viewSize * 0.5 }
            if has3DRotation {
                return ToolUtilities.project3DToScreen(
                    point: world, center: image.position,
                    rotationZ: image.rotation, rotation3D: image.rotation3D,
                    viewSize: viewSize, camera: camera
                )
            }
            return camera.worldToScreen(world, viewSize: viewSize)
        }
        return ScreenGeometry(mesh: mesh, screenVertices: screenVertices)
    }

    /// The texture coordinate under a screen point, or nil if the point is not
    /// on the sprite's drawn shape at all.
    ///
    /// Barycentric, so it is exact for a stretched, sheared or 3D-flipped
    /// triangle — which is the case the affine inverse got wrong.
    static func uv(at point: SIMD2<Float>, geometry: ScreenGeometry) -> SIMD2<Float>? {
        let vertices = geometry.screenVertices
        let uvs = geometry.mesh.uvs
        let indices = geometry.mesh.indices
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            i += 3
            guard a < vertices.count, b < vertices.count, c < vertices.count else { continue }
            let p0 = vertices[a], p1 = vertices[b], p2 = vertices[c]
            let v0 = p1 - p0, v1 = p2 - p0, v2 = point - p0
            let denominator = v0.x * v1.y - v1.x * v0.y
            guard abs(denominator) > 1e-7 else { continue }   // degenerate sliver
            let inverse = 1 / denominator
            let beta = (v2.x * v1.y - v1.x * v2.y) * inverse
            let gamma = (v0.x * v2.y - v2.x * v0.y) * inverse
            let alpha = 1 - beta - gamma
            guard alpha >= 0, beta >= 0, gamma >= 0 else { continue }
            return uvs[a] * alpha + uvs[b] * beta + uvs[c] * gamma
        }
        return nil
    }

    /// Distance from a screen point to the sprite's drawn shape.
    private static func distanceToGeometry(_ point: SIMD2<Float>,
                                           geometry: ScreenGeometry) -> Float {
        var best = Float.greatestFiniteMagnitude
        let vertices = geometry.screenVertices
        let indices = geometry.mesh.indices
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            i += 3
            guard a < vertices.count, b < vertices.count, c < vertices.count else { continue }
            for (s, e) in [(vertices[a], vertices[b]), (vertices[b], vertices[c]), (vertices[c], vertices[a])] {
                best = min(best, ToolUtilities.distancePointToSegment(point: point, a: s, b: e))
                if best == 0 { return 0 }
            }
        }
        return best
    }

    /// Cheap reject: is the point anywhere near the drawn vertices at all?
    private static func withinReach(_ point: SIMD2<Float>,
                                    of vertices: [SIMD2<Float>]) -> Bool {
        guard var minimum = vertices.first else { return false }
        var maximum = minimum
        for vertex in vertices.dropFirst() {
            minimum = simd_min(minimum, vertex)
            maximum = simd_max(maximum, vertex)
        }
        let dx = max(minimum.x - point.x, 0, point.x - maximum.x)
        let dy = max(minimum.y - point.y, 0, point.y - maximum.y)
        return dx * dx + dy * dy <= slopRadius * slopRadius
    }

    /// Distance from a screen point to the sprite's OPAQUE region, measured
    /// through the drawn geometry.
    ///
    /// The box is in UV, so its corners are mapped to screen the same way the
    /// alpha lookup goes the other way — barycentrically, through the triangles
    /// that were drawn. That is what makes it follow a bone: the affine version
    /// of this described where the art would be if nothing had moved it.
    private static func distanceToOpaqueRegion(_ point: SIMD2<Float>,
                                               opaque: SIMD4<Float>,
                                               geometry: ScreenGeometry) -> Float {
        let corners = [
            SIMD2<Float>(opaque.x, opaque.y), SIMD2<Float>(opaque.z, opaque.y),
            SIMD2<Float>(opaque.z, opaque.w), SIMD2<Float>(opaque.x, opaque.w),
        ].compactMap { screenPosition(forUV: $0, geometry: geometry) }

        // A corner can fall outside every triangle — a traced mesh does not
        // cover the whole UV square. With fewer than three mapped corners there
        // is no polygon to measure, and refusing to guess is the safe answer:
        // the silhouette distance still applies, and `max` of the two means
        // returning zero here can only make the reach MORE permissive, never
        // less. It cannot invent a hit, because the exact test has already run.
        guard corners.count >= 3 else { return 0 }

        var best = Float.greatestFiniteMagnitude
        for index in corners.indices {
            let a = corners[index]
            let b = corners[(index + 1) % corners.count]
            best = min(best, ToolUtilities.distancePointToSegment(point: point, a: a, b: b))
        }
        return pointInPolygon(point, corners) ? 0 : best
    }

    /// The screen position of a texture coordinate — the inverse of `uv(at:)`,
    /// found by walking the same triangles in UV space.
    static func screenPosition(forUV uv: SIMD2<Float>,
                               geometry: ScreenGeometry) -> SIMD2<Float>? {
        let vertices = geometry.screenVertices
        let uvs = geometry.mesh.uvs
        let indices = geometry.mesh.indices
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]), b = Int(indices[i + 1]), c = Int(indices[i + 2])
            i += 3
            guard a < vertices.count, b < vertices.count, c < vertices.count,
                  a < uvs.count, b < uvs.count, c < uvs.count else { continue }
            let t0 = uvs[a], t1 = uvs[b], t2 = uvs[c]
            let v0 = t1 - t0, v1 = t2 - t0, v2 = uv - t0
            let denominator = v0.x * v1.y - v1.x * v0.y
            guard abs(denominator) > 1e-9 else { continue }
            let inverse = 1 / denominator
            let beta = (v2.x * v1.y - v1.x * v2.y) * inverse
            let gamma = (v0.x * v2.y - v2.x * v0.y) * inverse
            let alpha = 1 - beta - gamma
            guard alpha >= 0, beta >= 0, gamma >= 0 else { continue }
            return vertices[a] * alpha + vertices[b] * beta + vertices[c] * gamma
        }
        return nil
    }

    private static func pointInPolygon(_ point: SIMD2<Float>, _ polygon: [SIMD2<Float>]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > point.y) != (b.y > point.y) {
                let t = (point.y - a.y) / (b.y - a.y)
                if point.x < a.x + t * (b.x - a.x) { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    // MARK: - Arbitration

    /// A bone or a sprite, whichever the click actually landed on.
    static func target(screenPoint: SIMD2<Float>,
                       viewSize: SIMD2<Float>,
                       scene: SceneManager,
                       assets: AssetManager,
                       camera: CameraState?) -> ToolUtilities.SelectionTarget? {
        let bone = ToolUtilities.hitTestBoneDetailed(
            screenPoint: screenPoint, viewSize: viewSize, scene: scene, camera: camera
        )
        let image = imageHit(screenPoint: screenPoint, viewSize: viewSize,
                             scene: scene, assets: assets, camera: camera)

        switch (bone, image) {
        case (nil, nil):
            return nil
        case (let bone?, nil):
            return .bone(bone.id)
        case (nil, let image?):
            return image.target

        case (let bone?, let image?):
            let boneIsDirect = bone.distance <= boneDirectRadius
            // Both direct, or neither: the bone wins, which is the behaviour
            // this app has always had and what a rigger expects when a bone is
            // drawn over the art it drives.
            if boneIsDirect || !image.isDirect { return .bone(bone.id) }
            // The click is on an opaque pixel and the bone is merely nearby.
            return image.target
        }
    }
}
