#pragma once

// Port of the fly camera: `SceneViewCamera` (from
// `Data/Scene/SceneComposition.swift`) plus the parts of
// `Render/SceneViewProjection.swift` that are pure camera math.
//
// Why the two live in one file here: the Swift split puts the ORBIT in the
// Scene-composition model and the PROJECTION in Render, and the file's own
// header says why that split is dangerous -- `SceneViewProjection.basis`
// must produce "the SAME vectors `SceneViewCamera.eye` and
// `SceneViewCamera.pan` already use, so the eye the orbit computes is the
// eye this projects from; two transcriptions of 'forward' is how the pivot
// would end up somewhere other than the middle of the screen". In this port
// there is exactly one transcription: `cameraBasis` in SceneProjection.h,
// which `eye()` reads too.
//
// What this camera is FOR (from the Swift header, and worth keeping in
// mind when Phase 5 lands the shot camera): `SceneProjection` is the SHOT
// -- flat cards, one scale per layer, a rotation model that foreshortens
// an axis rather than turning the camera. It is what the export renders
// and what the runtime reproduces. Orbit that model and every card squashes
// by the same cosine whatever its depth, so the layers never fan out and
// the canvas cannot show that one card is behind another. The EDITOR view
// therefore gets a real 3D camera; it is never exported. Front-on -- pitch
// and yaw zero -- the two agree to floating point on every pixel of an
// untilted card: same focal-length formula, same `focal / depth` scale,
// same offset, which is why `projection()` below builds a plain
// `SceneProjection` rather than a second copy of the math.
//
// NOT ported from `SceneViewProjection.swift`:
//   - `cardCorners` / `cardPoint`. They take a `SceneLayer` and call its
//     `planePoint` / `liftToWorld` / `worldOrigin` -- the Scene-compositing
//     model, which is Phase 5. Porting them now would mean inventing a
//     layer type here and re-transcribing that lift, which is the exact
//     "two transcriptions of a rotation" failure the Swift file warns
//     about. They come across with SceneLayer.
//   - The `init(camera:)` / `init(shot:)` convenience initializers, for the
//     same reason the ones on `SceneProjection` were left out: they are
//     one-line wrappers once those Phase 5 types exist. `projection()` here
//     IS the first of the two, for the type this file does port.
//
// `shotFrame` is ported, with the shot camera's fields passed explicitly
// rather than as a `SceneCamera` -- the "inject what's needed" rule. One
// transcription detail is preserved deliberately: it uses the UNCLAMPED
// focal length (`SceneCamera.focalLength(viewHeight:)` does not clamp the
// field of view, while `SceneViewProjection.init` clamps to 1..170). The
// two differ only outside that range, and matching Swift matters more here
// than being internally tidy, because the frustum gizmo this draws has to
// land on the frame the export actually renders.

#include "umeshcore/Math/Vec.h"
#include "umeshcore/Render/SceneProjection.h"

#include <vector>

namespace umeshcore {

struct SceneViewCamera {
    // What the view turns around. (The Mac's `F` key moves it to the
    // selected layer; that binding is shell, not core.)
    Vec3 pivot = Vec3::zero();
    // Distance from the pivot to the eye.
    float distance = 1800.0f;
    // Radians. Clamped away from straight up and straight down by `orbit`,
    // because at exactly the pole the horizon spins on its own and there is
    // no way back.
    float pitch = 0.0f;
    float yaw = 0.0f;
    float fieldOfView = 45.0f;

    static constexpr float kPitchLimit = 89.0f * 3.14159265358979323846f / 180.0f;
    static constexpr float kMinDistance = 10.0f;
    static constexpr float kMaxDistance = 500000.0f;

    // Anything nearer than this along the view axis is not drawn. One unit,
    // like the shot camera's default near plane; a point at the eye has no
    // projection and one just behind it would flip.
    static constexpr float kNearDistance = 1.0f;
    static constexpr float kFarDistance = 1000000.0f;

    // Where the eye actually sits, derived from the orbit. Looking along
    // +Z, so backing away from the pivot means going -Z.
    Vec3 eye() const;

    void orbit(float deltaYaw, float deltaPitch);

    // Multiplicative, so the step shrinks as you approach and a scroll
    // wheel feels the same at every scale. Clamped so the eye can never
    // cross the pivot and turn the view inside out.
    void dolly(float factor);

    // Move the pivot across the view plane, in world units per screen pixel.
    void pan(const Vec2& screenDelta, float viewHeight);

    // The same eye, expressed as the matrices everything projects through:
    // one projection serving the fly view and the shot is what stops the
    // preview and the render from drifting apart.
    SceneProjection projection(const Vec2& viewSize) const;
};

// The shot's frame at a distance in front of it: the rectangle that would
// exactly fill the render at that depth. Corners in the order
// `SceneViewProjection.cardCorners` uses -- top-left, top-right,
// bottom-right, bottom-left, as seen from the front.
//
// At the focal length for `renderSize.y` the rectangle is exactly
// `renderSize` world units -- the plane where one unit is one pixel, which
// is where a new layer is placed and where the frustum gizmo draws its
// frame.
std::vector<Vec3> shotFrame(
    const Vec3& shotEye, const Vec3& shotRotation3D, float shotFieldOfView, const Vec2& renderSize,
    float distance);

} // namespace umeshcore
