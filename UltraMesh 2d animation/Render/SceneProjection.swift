import Foundation
import simd

/// The one way a Scene turns world coordinates into pixels: a view matrix, a
/// perspective projection matrix, and a divide by w.
///
/// One, deliberately and load-bearingly. The rig side of the editor already has
/// three copies of world-to-screen — `MetalRenderer.project3DToScreen`,
/// `ToolUtilities.project3DToScreen`, and an inline expression inside
/// `CoreGraphicsFrameSource` — and they already disagree: the exporter has no
/// `rotation3D` term at all, so a sprite rotated in 3D exports differently from
/// how it looks on the canvas. A Scene is composed on one canvas and delivered
/// as a video rendered somewhere else; if those two disagree, the artist finds
/// out after rendering.
///
/// ## What this replaces, and why
///
/// This used to collapse the perspective divide into a single number per layer:
///
///     scale  = focal / (layerZ - camera.positionZ)
///     screen = centre + (world - cameraXY) * scale
///
/// A uniform scale chosen from Z. It gave correct parallax BETWEEN flat cards,
/// which is why it survived, and it was wrong in three ways that show:
///
///  * A card was scaled by ONE number, so a card tilted out of its plane could
///    not have a near edge wider than its far edge. Its tilt had to be faked
///    separately, as a screen-space `m34` trick applied AFTER the projection.
///  * Camera pitch and yaw were applied as `x *= cos(yaw)`, `y *= cos(pitch)` —
///    an axis-aligned squash, not a rotation. Turning the camera squashed the
///    picture uniformly at every depth instead of swinging near things past far
///    ones, and parallel lines never converged.
///  * Nothing had a per-vertex depth, so there was no perspective WITHIN a
///    layer at all.
///
/// Now a card's corners are world points — scale, shear, roll and tilt all
/// resolved in world space by `SceneLayer.planePoint` and
/// `SceneViewProjection.cardPoint` — and each one goes through the matrices and
/// is divided by its own w. The parallax is not computed anywhere. It is what
/// the divide does.
///
/// Verified by `Editor/verify_scene_perspective.py`, whose foil is the scale
/// per layer this replaces: it fails on the tilted card, on the yawed camera,
/// and on convergence.
struct SceneProjection {

    /// World to camera: undo the camera's rotation, then its position.
    let viewMatrix: simd_float4x4
    /// Camera to clip. A real perspective matrix — the w it writes is what
    /// every point is divided by.
    let projectionMatrix: simd_float4x4
    /// Pixel size of the surface being drawn into. For the render camera this is
    /// the composition's `renderSize`, NOT the window: what the artist sees while
    /// flying must never change what comes out.
    let viewSize: SIMD2<Float>
    /// Nothing closer than this along the view axis is drawn. A point at the eye
    /// has no projection and one just behind it would flip.
    let nearZ: Float
    let eye: SIMD3<Float>
    /// Pixels a world unit covers at unit depth, perpendicular to the view axis.
    ///
    /// One number, the same for every direction, because the projection is
    /// uniform: `pixels = focalLength * length / depth`. It is what sizes a
    /// gizmo to a constant number of pixels without measuring each of its axes
    /// separately — measuring per axis is what gave one gizmo three different
    /// arrows.
    let focalLength: Float

    /// The SHOT camera — the one that renders.
    init(camera: SceneCamera, viewSize: SIMD2<Float>) {
        self.init(eye: SIMD3<Float>(camera.position.x, camera.position.y, camera.positionZ),
                  pitch: camera.rotation3D.x, yaw: camera.rotation3D.y,
                  roll: camera.rotation3D.z,
                  fieldOfView: camera.fieldOfView,
                  nearZ: max(camera.nearZ, 0.01), farZ: max(camera.farZ, camera.nearZ + 1),
                  viewSize: viewSize)
    }

    /// The FLY camera — where the artist is standing. Same projection, other
    /// eye: two cameras and one set of maths is what keeps the preview and the
    /// render from drifting apart.
    init(view: SceneViewCamera, viewSize: SIMD2<Float>) {
        // Through the basis the orbit already computes, so the eye this
        // projects from is the eye `SceneViewCamera.eye` places.
        let basis = SceneViewProjection.basis(pitch: view.pitch, yaw: view.yaw, roll: 0)
        let half = min(max(view.fieldOfView, 1), 170) * .pi / 180 * 0.5
        self.init(eye: view.eye, right: basis.right, up: basis.up, forward: basis.forward,
                  focalLength: (viewSize.y * 0.5) / max(tan(half), 0.000001),
                  nearZ: 1, farZ: 1_000_000, viewSize: viewSize)
    }

    init(eye: SIMD3<Float>,
         pitch: Float, yaw: Float, roll: Float,
         fieldOfView: Float,
         nearZ: Float, farZ: Float,
         viewSize: SIMD2<Float>) {
        self.eye = eye
        self.viewSize = viewSize
        self.nearZ = nearZ
        let clampedHalf = min(max(fieldOfView, 1), 170) * .pi / 180 * 0.5
        let focal = (viewSize.y * 0.5) / max(tan(clampedHalf), 0.000001)
        self.focalLength = focal

        // Yaw about world Y, then pitch, then roll about the view axis — the
        // same order `SceneViewProjection.basis` builds its vectors in, because
        // the eye the orbit computes has to be the eye this projects from.
        let rotation = MatrixUtilities.rotationY(yaw)
            * MatrixUtilities.rotationX(pitch)
            * MatrixUtilities.rotationZ(roll)
        // A view matrix is the camera's transform INVERTED, and for a rotation
        // plus a translation the inverse is the transpose and the negated,
        // rotated offset — exact, where a general inverse would not be.
        self.viewMatrix = rotation.transpose * MatrixUtilities.translation(-eye)

        // From the LOCAL `focal`, not `self.focalLength`: reading a stored
        // property back mid-initialiser is a corner of definite initialisation
        // this file has no reason to stand in.
        let f = 2 * focal / max(viewSize.y, 0.000001)
        let aspect = viewSize.x / max(viewSize.y, 0.000001)
        let far = max(farZ, nearZ + 1)
        // Column-major, and the camera looks along +Z — so the row that writes
        // w reads z with a +1, not the -1 a right-handed look-down-minus-Z
        // convention would use.
        self.projectionMatrix = simd_float4x4(columns: (
            SIMD4<Float>(f / aspect, 0, 0, 0),
            SIMD4<Float>(0, f, 0, 0),
            SIMD4<Float>(0, 0, far / (far - nearZ), 1),
            SIMD4<Float>(0, 0, -far * nearZ / (far - nearZ), 0)
        ))
    }

    /// From an orthonormal camera frame rather than from angles.
    ///
    /// `SceneViewProjection` keeps its basis because the orbit and the card
    /// geometry are written in those vectors, and re-deriving angles from them
    /// to build the same matrices would be a second transcription of the camera
    /// — which is the failure this whole type exists to prevent. So the frame
    /// comes across directly: a view matrix IS a basis in its rows and the
    /// negated, rotated eye in its last column.
    init(eye: SIMD3<Float>,
         right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>,
         focalLength: Float,
         nearZ: Float, farZ: Float,
         viewSize: SIMD2<Float>) {
        self.eye = eye
        self.viewSize = viewSize
        self.nearZ = nearZ
        self.focalLength = focalLength

        let t = SIMD3<Float>(-simd_dot(right, eye), -simd_dot(up, eye), -simd_dot(forward, eye))
        self.viewMatrix = simd_float4x4(columns: (
            SIMD4<Float>(right.x, up.x, forward.x, 0),
            SIMD4<Float>(right.y, up.y, forward.y, 0),
            SIMD4<Float>(right.z, up.z, forward.z, 0),
            SIMD4<Float>(t.x, t.y, t.z, 1)
        ))

        // `focalLength` is half the view height over tan(fov/2), so the
        // projection's f — one over that tangent — is twice it over the height.
        let f = 2 * focalLength / max(viewSize.y, 0.000001)
        let aspect = viewSize.x / max(viewSize.y, 0.000001)
        let far = max(farZ, nearZ + 1)
        self.projectionMatrix = simd_float4x4(columns: (
            SIMD4<Float>(f / aspect, 0, 0, 0),
            SIMD4<Float>(0, f, 0, 0),
            SIMD4<Float>(0, 0, far / (far - nearZ), 1),
            SIMD4<Float>(0, 0, -far * nearZ / (far - nearZ), 0)
        ))
    }

    /// A world point, in pixels (y down). Nil when it is at or behind the near
    /// plane.
    ///
    /// Nil rather than a clamped number on purpose: a point behind the eye has
    /// no honest projection, and answering with a large or mirrored one puts
    /// garbage on screen that reads as a rendering bug rather than as a layer in
    /// the wrong place.
    func project(_ world: SIMD3<Float>) -> SIMD2<Float>? {
        let clip = projectionMatrix * (viewMatrix * SIMD4<Float>(world, 1))
        let w = clip.w
        guard w > nearZ else { return nil }
        let ndc = SIMD2<Float>(clip.x / w, clip.y / w)
        return SIMD2<Float>(viewSize.x * 0.5 * (1 + ndc.x),
                            viewSize.y * 0.5 * (1 - ndc.y))
    }

    // MARK: - The near plane, cut rather than rejected

    /// A world point carrying whatever has to survive being cut in half.
    ///
    /// The attribute is the card's LOCAL point, which is what a UV is read
    /// from. It rides along so that a vertex invented on the near plane knows
    /// which part of the texture belongs there — without it the cut edge
    /// samples the wrong pixels, and a card that draws the wrong thing is a
    /// worse bug than one that vanishes.
    struct AttributedVertex {
        var world: SIMD3<Float>
        var attribute: SIMD2<Float>
    }

    /// Pixels (y down) and the attribute, interpolated to wherever the cut fell.
    struct ProjectedVertex {
        var screen: SIMD2<Float>
        var attribute: SIMD2<Float>
    }

    /// A convex polygon, cut to the near plane and projected. Empty when none
    /// of it is in front of the eye.
    ///
    /// This is the fix for layers vanishing as the camera closes on them. Every
    /// drawing path used to ask `project` for each corner and give up the whole
    /// primitive when one came back nil — `guard let topLeft = map(...)`, and a
    /// comment saying "a corner behind the eye: the card is not drawable". That
    /// is false. A quad with one corner behind the eye is PARTLY visible, and
    /// the visible part is a polygon. Since the nearest corner crosses long
    /// before the centre does, and the gizmo projects the centre, the card went
    /// while its handles stayed — which is exactly how it was reported.
    ///
    /// ## Why the cut happens in clip space
    ///
    /// Before the divide, not after, and not in world space. A vertex made by
    /// cutting here has `clip.z == 0` and `clip.w == nearZ` BY CONSTRUCTION, so
    /// the divide that follows cannot fail and the vertex cannot land a hair on
    /// the wrong side of the very guard it was made to satisfy. Cutting in
    /// world space and re-projecting would do exactly that, and would come back
    /// as a one-pixel flicker along the cut edge.
    ///
    /// `clip.z` is the near test: the projection writes
    /// `z_clip = far * (z_cam - nearZ) / (far - nearZ)`, which is zero exactly
    /// on the plane and positive in front of it.
    ///
    /// Verified in `Editor/verify_scene_near_clipping.py`, whose foil is the
    /// all-or-nothing rule this replaces: it reproduces the card going from 89%
    /// of the canvas to nothing in one two-unit step of camera movement, with
    /// the centre still projecting.
    func clipAndProject(_ polygon: [AttributedVertex]) -> [ProjectedVertex] {
        guard polygon.count >= 2 else { return [] }
        var homogeneous: [(SIMD4<Float>, SIMD2<Float>)] = []
        homogeneous.reserveCapacity(polygon.count)
        for vertex in polygon {
            homogeneous.append((projectionMatrix * (viewMatrix * SIMD4<Float>(vertex.world, 1)),
                                vertex.attribute))
        }

        // NEAR, then FAR. Two half-spaces, one clipper — and the far one is not
        // decoration: without it the frustum's far plane discarded cards this
        // renderer would happily have drawn, because `farZ` went into the
        // projection matrix and then nothing ever read it back.
        // `verify_scene_culling.py` measures that disagreement at 51 layers out
        // of 20 000 random cameras, every one of them putting pixels on the
        // canvas. A culler whose planes the renderer does not honour is not a
        // culler; it is a way to lose objects.
        var kept = Self.clip(homogeneous, by: Self.nearSide)
        if !kept.isEmpty { kept = Self.clip(kept, by: Self.farSide) }

        // Named rather than destructured in the closure head, and not `clip`:
        // that is the array being read, and shadowing it here would leave two
        // different things called the same word one line apart.
        return kept.compactMap { entry -> ProjectedVertex? in
            let point = entry.0
            guard point.w > 0, point.w.isFinite else { return nil }
            let ndc = SIMD2<Float>(point.x / point.w, point.y / point.w)
            guard ndc.x.isFinite, ndc.y.isFinite else { return nil }
            return ProjectedVertex(
                screen: SIMD2<Float>(viewSize.x * 0.5 * (1 + ndc.x),
                                     viewSize.y * 0.5 * (1 - ndc.y)),
                attribute: entry.1)
        }
    }

    /// Sutherland-Hodgman against one clip-space half-space.
    ///
    /// `side` is >= 0 inside. IN CLIP SPACE, before the divide, because a
    /// vertex made by the cut then has `clip.z == 0` (near) or
    /// `clip.z == clip.w` (far) BY CONSTRUCTION — the divide that follows
    /// cannot fail, and the vertex cannot land a hair on the wrong side of the
    /// very guard it was made to satisfy.
    static func clip(_ verts: [(SIMD4<Float>, SIMD2<Float>)],
                     by side: (SIMD4<Float>) -> Float) -> [(SIMD4<Float>, SIMD2<Float>)] {
        guard verts.count >= 2 else { return [] }
        var out: [(SIMD4<Float>, SIMD2<Float>)] = []
        out.reserveCapacity(verts.count + 2)
        for index in verts.indices {
            let (c0, a0) = verts[index]
            let (c1, a1) = verts[(index + 1) % verts.count]
            let d0 = side(c0), d1 = side(c1)
            let in0 = d0 >= 0, in1 = d1 >= 0
            if in0 { out.append((c0, a0)) }
            guard in0 != in1 else { continue }
            let denominator = d0 - d1
            guard abs(denominator) > 1e-12 else { continue }
            let t = d0 / denominator
            out.append((c0 + (c1 - c0) * t, a0 + (a1 - a0) * t))
        }
        return out
    }

    /// `clip.z = far * (z - near) / (far - near)`: zero exactly on the near
    /// plane, positive in front of it.
    static let nearSide: (SIMD4<Float>) -> Float = { $0.z }
    /// `clip.w - clip.z`: zero exactly on the far plane.
    static let farSide: (SIMD4<Float>) -> Float = { $0.w - $0.z }

    /// True when the whole polygon is between the near and far planes, so the
    /// cut would return it unchanged and the fast drawing paths still apply.
    ///
    /// Cheap on purpose: this runs for every card of every frame, and the
    /// answer is yes for all of them until the artist flies in close.
    ///
    /// It used to ask only about the near plane, under the name
    /// `isWhollyInFront`. That was right while far did nothing; now that far
    /// clips, a card poking through it has to take the cutting path like any
    /// other, so the question and the name both grew the second half.
    func isWhollyVisible(_ worlds: [SIMD3<Float>]) -> Bool {
        worlds.allSatisfy { world in
            let clip = projectionMatrix * (viewMatrix * SIMD4<Float>(world, 1))
            return Self.nearSide(clip) >= 0 && Self.farSide(clip) >= 0
        }
    }

    /// World straight to clip. What the frustum's planes are pulled out of.
    var viewProjection: simd_float4x4 { projectionMatrix * viewMatrix }

    /// The four screen points a card's corners project to, INCLUDING any that
    /// are behind the eye, as the homography that maps the card's texture.
    ///
    /// A card is a plane, so layer-local to screen is a homography, and a
    /// homography is fixed by four point correspondences. A corner behind the
    /// eye divides by a negative w and lands at the antipode — which is not an
    /// error to be guarded away but the correct projective image of that
    /// corner, and the homography through the four is the true map. That is
    /// what lets the visible part be drawn with real perspective instead of
    /// being approximated: the card is mapped whole and the near-plane cut
    /// becomes a CLIP on the destination.
    ///
    /// Measured in `verify_scene_near_clipping.py` against the true projection
    /// at ten distances with up to two corners behind the eye: agreement to
    /// 1.4e-08 px. The one degenerate case is a corner within `wEpsilon` of the
    /// plane through the eye, where the divide is meaningless and no homography
    /// exists — nil, and the caller falls back.
    func projectiveQuad(_ worlds: [SIMD3<Float>]) -> [SIMD2<Float>]? {
        guard worlds.count == 4 else { return nil }
        var out: [SIMD2<Float>] = []
        out.reserveCapacity(4)
        for world in worlds {
            let clip = projectionMatrix * (viewMatrix * SIMD4<Float>(world, 1))
            guard abs(clip.w) > Self.wEpsilon else { return nil }
            let ndc = SIMD2<Float>(clip.x / clip.w, clip.y / clip.w)
            guard ndc.x.isFinite, ndc.y.isFinite else { return nil }
            out.append(SIMD2<Float>(viewSize.x * 0.5 * (1 + ndc.x),
                                    viewSize.y * 0.5 * (1 - ndc.y)))
        }
        return out
    }

    /// How close to the plane through the eye a corner may come before its
    /// divide stops meaning anything. The harness measures the closest any
    /// corner gets over a full approach at 6.7 units, so this is a genuine
    /// degeneracy and not a threshold standing in for the fix.
    static let wEpsilon: Float = 1e-4

    /// The world length that projects to `pixels` at this depth.
    ///
    /// The inverse of `pixels = focalLength * length / depth`, and the one
    /// number a gizmo needs to be a constant size on screen: ONE scale for all
    /// three of its axes, so the arrow mesh is scaled uniformly and keeps its
    /// proportions from every angle.
    func worldLength(forPixels pixels: Float, atDepth depth: Float) -> Float? {
        guard depth > nearZ, focalLength > 0.000001 else { return nil }
        return pixels * depth / focalLength
    }

    /// How far a world point is along the view axis.
    func depth(of world: SIMD3<Float>) -> Float {
        (viewMatrix * SIMD4<Float>(world, 1)).z
    }

    // MARK: - Screen back to world: what a manipulator drag actually asks

    /// The world ray through a pixel: the eye, and a unit direction.
    ///
    /// Every gizmo drag is a question about WORLD space asked with a SCREEN
    /// position, so every one of them starts here. The alternative the gizmo
    /// used — project the pointer's screen delta onto the handle's screen
    /// direction and divide by a pixels-per-unit measured at the pivot — is
    /// only right when the projection is affine. Under perspective that ratio
    /// changes along the axis and with depth, and
    /// `Editor/verify_scene_gizmo_drag.py` measures the handle sliding up to
    /// 313 px out from under the pointer because of it.
    func ray(through screen: SIMD2<Float>) -> (origin: SIMD3<Float>, direction: SIMD3<Float>) {
        let f = projectionMatrix.columns.1.y
        let aspect = viewSize.x / max(viewSize.y, 0.000001)
        let ndc = SIMD2<Float>(2 * screen.x / max(viewSize.x, 1) - 1,
                               1 - 2 * screen.y / max(viewSize.y, 1))
        let inCamera = SIMD3<Float>(ndc.x * aspect / max(abs(f), 0.000001),
                                    ndc.y / max(abs(f), 0.000001), 1)
        // The view matrix's rotation, transposed, takes camera space back to
        // the world. Transposed rather than inverted because it IS a rotation,
        // so the two are the same answer and only one of them can go wrong.
        let rotation = simd_float3x3(
            SIMD3<Float>(viewMatrix.columns.0.x, viewMatrix.columns.0.y, viewMatrix.columns.0.z),
            SIMD3<Float>(viewMatrix.columns.1.x, viewMatrix.columns.1.y, viewMatrix.columns.1.z),
            SIMD3<Float>(viewMatrix.columns.2.x, viewMatrix.columns.2.y, viewMatrix.columns.2.z)
        )
        let direction = rotation.transpose * inCamera
        let length = simd_length(direction)
        return (eye, length > 0.000001 ? direction / length : SIMD3<Float>(0, 0, 1))
    }

    /// Where the ray through a pixel meets an arbitrary plane. Nil when it runs
    /// parallel to it, or meets it behind the eye.
    ///
    /// This is what a PLANE handle is, and what a rotation ring is read in.
    /// `unproject(_:ontoPlaneZ:)` below answers the same question for the one
    /// plane that is perpendicular to world Z; this answers it for the plane a
    /// handle actually lies in, which after any rotation is not that one.
    func hit(screen: SIMD2<Float>, plane point: SIMD3<Float>, normal: SIMD3<Float>)
        -> SIMD3<Float>? {
        let r = ray(through: screen)
        let denominator = simd_dot(r.direction, normal)
        guard abs(denominator) > 0.000001 else { return nil }
        let t = simd_dot(point - r.origin, normal) / denominator
        guard t > 0, t.isFinite else { return nil }
        return r.origin + r.direction * t
    }

    /// How far along `direction` from `point` the closest approach to the ray
    /// through a pixel lies.
    ///
    /// The classic closest approach of two skew lines, and what makes an AXIS
    /// handle track the pointer at any angle and any depth: the answer is a
    /// world distance along the axis, not a screen distance rescaled by a
    /// number measured somewhere else. Nil when the ray and the axis are
    /// parallel on screen, which is the axis seen end-on — the one case where
    /// there is no honest answer, and where the gizmo already refuses the drag.
    func axisParameter(screen: SIMD2<Float>,
                       origin point: SIMD3<Float>, direction: SIMD3<Float>) -> Float? {
        let r = ray(through: screen)
        let w0 = point - r.origin
        let a = simd_dot(direction, direction)
        let b = simd_dot(direction, r.direction)
        let c = simd_dot(r.direction, r.direction)
        let d = simd_dot(direction, w0)
        let e = simd_dot(r.direction, w0)
        let denominator = a * c - b * b
        guard abs(denominator) > 0.000001 else { return nil }
        let t = (b * e - c * d) / denominator
        return t.isFinite ? t : nil
    }

    /// Pixels back to the world point on the plane `z = planeZ`.
    ///
    /// A ray from the eye through the pixel, met with the plane. Placing and
    /// dragging a layer needs it, and it has to be the exact inverse of
    /// `project` or the cursor and the card it is holding drift apart — by more
    /// the further away the card is, so it presents as a different bug at every
    /// depth.
    func unproject(_ screen: SIMD2<Float>, ontoPlaneZ planeZ: Float) -> SIMD2<Float>? {
        let ndc = SIMD2<Float>(2 * screen.x / max(viewSize.x, 1) - 1,
                               1 - 2 * screen.y / max(viewSize.y, 1))
        let f = projectionMatrix.columns.1.y
        guard abs(f) > 0.000001 else { return nil }
        let aspect = viewSize.x / max(viewSize.y, 0.000001)
        // The direction through that pixel, in camera space, then rotated back
        // into the world by the view matrix's own rotation.
        let inCamera = SIMD3<Float>(ndc.x * aspect / f, ndc.y / f, 1)
        let rotation = simd_float3x3(
            SIMD3<Float>(viewMatrix.columns.0.x, viewMatrix.columns.0.y, viewMatrix.columns.0.z),
            SIMD3<Float>(viewMatrix.columns.1.x, viewMatrix.columns.1.y, viewMatrix.columns.1.z),
            SIMD3<Float>(viewMatrix.columns.2.x, viewMatrix.columns.2.y, viewMatrix.columns.2.z)
        )
        let direction = rotation.transpose * inCamera
        guard abs(direction.z) > 0.000001 else { return nil }
        let t = (planeZ - eye.z) / direction.z
        guard t > 0 else { return nil }
        let hit = eye + direction * t
        return SIMD2<Float>(hit.x, hit.y)
    }
}
