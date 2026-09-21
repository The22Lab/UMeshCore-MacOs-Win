import Foundation
import simd

/// The camera a Scene is rendered through — the one that gets keyframed and
/// exported.
///
/// Not to be confused with `SceneViewCamera`, which is the one the artist flies
/// around with. Keeping them apart is the whole discipline of a 3D viewport:
/// Unity calls them the Game camera and the Scene view camera, and mixing them
/// up is how you spend an afternoon composing a shot that renders from
/// somewhere else entirely. This one is scene data and is saved with the
/// project; the fly camera is editor state and never leaves the machine.
struct SceneCamera: Equatable {
    /// Where the camera is, in the scene's world units.
    var position: SIMD2<Float>
    /// Depth. The camera looks along INCREASING Z, so a layer is in front of it
    /// when `layer.positionZ > camera.positionZ`, and pushing a layer back means
    /// raising its Z — the same direction After Effects uses.
    var positionZ: Float
    /// Pitch, yaw and roll, in radians.
    var rotation3D: SIMD3<Float>
    /// Vertical field of view, in degrees. Vertical because that is how every
    /// compositor and game engine states it, so a 45° Scene camera frames what a
    /// 45° Unity camera frames.
    var fieldOfView: Float
    /// Nothing nearer than this is drawn. It is what stops a layer approaching
    /// the eye from being magnified without bound — the formula itself is
    /// correct all the way in, so the clamp belongs here rather than hidden
    /// inside the projection as a fudge factor.
    var nearZ: Float
    var farZ: Float

    init(
        position: SIMD2<Float> = .zero,
        positionZ: Float = -1200,
        rotation3D: SIMD3<Float> = .zero,
        fieldOfView: Float = 45,
        nearZ: Float = 1,
        farZ: Float = 100_000
    ) {
        self.position = position
        self.positionZ = positionZ
        self.rotation3D = rotation3D
        self.fieldOfView = fieldOfView
        self.nearZ = nearZ
        self.farZ = farZ
    }

    /// The distance at which one world unit covers one pixel of view height.
    ///
    /// Scale is 1 at exactly this distance, which is what makes a Scene with its
    /// layers on the focal plane land on precisely the pixels the editor's
    /// existing 2D path produces. An artist who never touches Z sees nothing
    /// move.
    func focalLength(viewHeight: Float) -> Float {
        let half = fieldOfView * .pi / 180 * 0.5
        return (viewHeight * 0.5) / max(tan(half), 0.000001)
    }
}
