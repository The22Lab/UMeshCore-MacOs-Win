#pragma once

// 1:1 port of `Data/Scene/SceneCamera.swift` -- the camera a Scene is
// RENDERED through: the one that gets keyframed and exported.
//
// Not to be confused with `SceneViewCamera` (in `Render/`), which is the
// one the artist flies around with. Keeping them apart is the whole
// discipline of a 3D viewport -- Unity calls them the Game camera and the
// Scene view camera -- and mixing them up is how you spend an afternoon
// composing a shot that renders from somewhere else entirely. This one is
// SCENE DATA and is saved with the project; the fly camera is editor state
// and never leaves the machine.
//
// This file also closes `SceneProjection`'s first deferred convenience
// initializer. Its header said the two `SceneCamera`/`SceneViewCamera`
// wrappers would become one-liners once those types existed, and
// `sceneProjection(camera, viewSize)` below is that one-liner. It lives
// HERE rather than on `SceneProjection` so the dependency points one way:
// Scene knows about Render, Render never learns about Scene. The fly
// camera's half is already `SceneViewCamera::projection()`.

#include <algorithm>
#include <cmath>

#include "umeshcore/Math/Vec.h"
#include "umeshcore/Render/SceneProjection.h"

namespace umeshcore {

struct SceneCamera {
    // Where the camera is, in the scene's world units.
    Vec2 position;
    // Depth. The camera looks along INCREASING Z, so a layer is in front
    // of it when `layer.positionZ > camera.positionZ`, and pushing a layer
    // back means RAISING its Z -- the same direction After Effects uses,
    // and the same one `SceneLayer::positionZ` and `SceneLight::positionZ`
    // use, so the three never need a sign flip between them.
    float positionZ = -1200.0f;
    // Pitch, yaw and roll, in radians.
    Vec3 rotation3D;
    // VERTICAL field of view, in degrees. Vertical because that is how
    // every compositor and game engine states it, so a 45-degree Scene
    // camera frames what a 45-degree Unity camera frames.
    float fieldOfView = 45.0f;
    // Nothing nearer than this is drawn. It is what stops a layer
    // approaching the eye being magnified without bound -- and the formula
    // itself is correct all the way in, so the clamp belongs HERE, as a
    // stated camera property, rather than hidden inside the projection as
    // a fudge factor.
    float nearZ = 1.0f;
    float farZ = 100000.0f;

    bool operator==(const SceneCamera&) const = default;

    // The distance at which one world unit covers one pixel of view
    // height. Scale is exactly 1 there, which is what makes a Scene with
    // its layers on the focal plane land on precisely the pixels the
    // editor's existing 2D path produces: an artist who never touches Z
    // sees nothing move.
    //
    // NOTE it does not clamp the field of view, while `SceneProjection`'s
    // angle constructor clamps to 1..170. The two differ only outside that
    // range, and `SceneViewCamera::shotFrame` deliberately uses THIS
    // unclamped one so the frustum gizmo lands on the frame the export
    // actually renders. Matching Swift matters more there than being
    // internally tidy.
    float focalLength(float viewHeight) const {
        const float half = fieldOfView * 3.14159265358979323846f / 180.0f * 0.5f;
        return (viewHeight * 0.5f) / std::max(std::tan(half), 0.000001f);
    }
};

// `SceneProjection.init(camera:viewSize:)`. The near/far guards are the
// Swift ones, kept verbatim: `nearZ` is floored at 0.01 and `farZ` is held
// at least one unit beyond it, so a camera saved with a degenerate depth
// range still produces a projection matrix that can be divided by.
inline SceneProjection sceneProjection(const SceneCamera& camera, const Vec2& viewSize) {
    return SceneProjection(
        Vec3(camera.position.x, camera.position.y, camera.positionZ), camera.rotation3D.x,
        camera.rotation3D.y, camera.rotation3D.z, camera.fieldOfView,
        std::max(camera.nearZ, 0.01f), std::max(camera.farZ, camera.nearZ + 1.0f), viewSize);
}

} // namespace umeshcore
