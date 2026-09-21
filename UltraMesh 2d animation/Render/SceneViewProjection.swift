import Foundation
import simd

/// True perspective for the Scene EDITOR view — the one the artist flies.
///
/// `SceneProjection` is the shot: flat cards, one scale per layer, a rotation
/// model that foreshortens an axis rather than turning the camera. It is what
/// the export renders and what the Unity runtime reproduces, it is verified
/// against both, and it is not touched here.
///
/// It is also not a view of the SET. Orbit that model and every card squashes
/// by the same cosine whatever its depth, so the layers never fan out: the
/// canvas cannot show that one card is behind another, and free movement shows
/// nothing that the front view did not. The reference the artist gave is a
/// real 3D viewport — cards receding toward a vanishing point, the near one
/// swinging further than the far one when the eye moves — and only a real
/// camera does that.
///
/// So the editor view gets one. It is never exported: what comes out of a Scene
/// is still the shot, through `SceneProjection`. What this buys is the set seen
/// from the side, which is the one thing the artist needs while placing cards
/// in depth and cannot get any other way.
///
/// Front-on — pitch and yaw zero — the two agree to floating point on every
/// pixel of an untilted card: same focal length formula, same `focal / depth`
/// scale, same offset. `verify_scene_view.py` pins that, so flying back to
/// "Front" lands exactly on the picture the shot camera would render from the
/// same place.
struct SceneViewProjection {
    let eye: SIMD3<Float>
    let right: SIMD3<Float>
    let up: SIMD3<Float>
    let forward: SIMD3<Float>
    let viewSize: SIMD2<Float>
    let focalLength: Float

    /// Anything nearer than this along the view axis is not drawn. One unit,
    /// like the shot camera's default near plane; a point at the eye has no
    /// projection and one just behind it would flip.
    static let nearDistance: Float = 1

    init(camera: SceneViewCamera, viewSize: SIMD2<Float>) {
        let basis = Self.basis(pitch: camera.pitch, yaw: camera.yaw, roll: 0)
        self.init(eye: camera.eye, basis: basis,
                  fieldOfView: camera.fieldOfView, viewSize: viewSize)
    }

    /// The shot camera, seen as a 3D camera — used to draw its frustum in the
    /// editor view and to look through it.
    init(shot: SceneCamera, viewSize: SIMD2<Float>) {
        let basis = Self.basis(pitch: shot.rotation3D.x, yaw: shot.rotation3D.y,
                               roll: shot.rotation3D.z)
        self.init(eye: SIMD3<Float>(shot.position.x, shot.position.y, shot.positionZ),
                  basis: basis, fieldOfView: shot.fieldOfView, viewSize: viewSize)
    }

    init(eye: SIMD3<Float>,
         basis: (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>),
         fieldOfView: Float,
         viewSize: SIMD2<Float>) {
        self.eye = eye
        self.right = basis.right
        self.up = basis.up
        self.forward = basis.forward
        self.viewSize = viewSize
        let half = min(max(fieldOfView, 1), 170) * .pi / 180 * 0.5
        self.focalLength = (viewSize.y * 0.5) / max(tan(half), 0.000001)
    }

    /// The camera frame from its angles. The SAME vectors `SceneViewCamera.eye`
    /// and `SceneViewCamera.pan` already use, so the eye the orbit computes is
    /// the eye this projects from — two transcriptions of "forward" is how the
    /// pivot would end up somewhere other than the middle of the screen.
    ///
    /// World: x right, y up, z away from the viewer (the camera looks along +Z,
    /// as `SceneCamera` documents). Yaw turns about world Y, pitch tips the
    /// view, roll turns the image plane about the view axis.
    static func basis(pitch: Float, yaw: Float, roll: Float)
        -> (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
        let cp = cos(pitch), sp = sin(pitch)
        let cy = cos(yaw), sy = sin(yaw)
        let forward = SIMD3<Float>(sy * cp, -sp, cy * cp)
        var right = SIMD3<Float>(cy, 0, -sy)
        var up = simd_cross(forward, right)
        if abs(roll) > 0.000001 {
            let cr = cos(roll), sr = sin(roll)
            let rolledRight = right * cr + up * sr
            let rolledUp = up * cr - right * sr
            right = rolledRight
            up = rolledUp
        }
        return (right, up, forward)
    }

    /// World point to pixels (y down), or nil when it is at or behind the eye.
    ///
    /// Through `SceneProjection`'s matrices, not a second copy of the maths: the
    /// fly view and the shot are two CAMERAS, and one projection between them is
    /// what stops the preview and the render from drifting apart. The basis
    /// vectors above stay because the card geometry and the orbit are written in
    /// them, and because `SceneCameraView.eye` has to be the eye this projects
    /// from.
    func project(_ point: SIMD3<Float>) -> SIMD2<Float>? {
        matrices.project(point)
    }

    /// Depth of a point along the view axis — what decides draw order in a
    /// view that is not front-on.
    func depth(of point: SIMD3<Float>) -> Float {
        simd_dot(point - eye, forward)
    }

    /// The same eye, expressed as the matrices everything projects through.
    var matrices: SceneProjection {
        SceneProjection(eye: eye, right: right, up: up, forward: forward,
                        focalLength: focalLength,
                        nearZ: Self.nearDistance, farZ: 1_000_000,
                        viewSize: viewSize)
    }

    // MARK: - The set, in 3D

    /// A layer's card corners in world space, in a fixed order: top-left,
    /// top-right, bottom-right, bottom-left — as seen from the front.
    ///
    /// The card is rotated in its own plane by `rotation`, tipped by
    /// `rotation3D` (pitch about its x axis, then yaw about its y axis), scaled,
    /// and placed. A true rotation, not the screen-space tilt the shot path uses
    /// for a card seen head-on: from the side, only a real corner in a real
    /// place can be drawn where it is.
    static func cardCorners(layer: SceneLayer,
                            localMin: SIMD2<Float>,
                            localMax: SIMD2<Float>) -> [SIMD3<Float>] {
        let corners = [
            SIMD2<Float>(localMin.x, localMax.y),
            SIMD2<Float>(localMax.x, localMax.y),
            SIMD2<Float>(localMax.x, localMin.y),
            SIMD2<Float>(localMin.x, localMin.y),
        ]
        return corners.map { cardPoint(layer: layer, local: $0) }
    }

    /// One point of a layer's card, layer-local (x right, y up, centred) to world.
    static func cardPoint(layer: SceneLayer, local: SIMD2<Float>) -> SIMD3<Float> {
        // Scale, shear and roll in the card's own plane, then the tilt that
        // lifts that plane into the world, then the layer's position. The lift
        // is `SceneLayer.liftToWorld` rather than a copy of it here, because the
        // gizmo's frame needs the same lift WITHOUT the scale and shear, and two
        // transcriptions of a rotation is how one of them ends up different.
        layer.worldOrigin + layer.liftToWorld(layer.planePoint(local))
    }

    /// The shot's frame at a distance in front of it: the rectangle that would
    /// exactly fill the render at that depth. Corners in the same order as
    /// `cardCorners`.
    ///
    /// At `shot.focalLength(viewHeight: renderSize.y)` the rectangle is exactly
    /// `renderSize` world units — the plane where one unit is one pixel, which
    /// is where a new layer is placed and where the frustum gizmo draws its
    /// frame.
    static func shotFrame(shot: SceneCamera, renderSize: SIMD2<Float>,
                          atDistance distance: Float) -> [SIMD3<Float>] {
        let basis = basis(pitch: shot.rotation3D.x, yaw: shot.rotation3D.y, roll: shot.rotation3D.z)
        let eye = SIMD3<Float>(shot.position.x, shot.position.y, shot.positionZ)
        let focal = shot.focalLength(viewHeight: renderSize.y)
        // Height grows linearly with distance; width keeps the render aspect.
        let halfH = renderSize.y * 0.5 * distance / max(focal, 0.000001)
        let halfW = halfH * renderSize.x / max(renderSize.y, 1)
        let centre = eye + basis.forward * distance
        return [
            centre - basis.right * halfW + basis.up * halfH,
            centre + basis.right * halfW + basis.up * halfH,
            centre + basis.right * halfW - basis.up * halfH,
            centre - basis.right * halfW - basis.up * halfH,
        ]
    }
}
