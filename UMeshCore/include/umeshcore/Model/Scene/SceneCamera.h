#pragma once

// 1:1 port of `Data/Scene/SceneCamera.swift` -- the camera a Scene is
// rendered through: the one that gets keyframed and exported.
//
// Not to be confused with `SceneViewCamera` (ported in Phase 4, in
// `Render/SceneViewCamera.h`), which is the one the artist flies around
// with. Keeping them apart is the whole discipline of a 3D viewport --
// Unity calls them the Game camera and the Scene view camera, and mixing
// them up is how you spend an afternoon composing a shot that renders from
// somewhere else. This one is scene data and is saved with the project;
// the fly camera is editor state and never leaves the machine.

#include "umeshcore/Math/Vec.h"

namespace umeshcore {

struct SceneCamera {
    // Where the camera is, in the scene's world units.
    Vec2 position;
    // Depth. The camera looks along INCREASING Z, so a layer is in front
    // of it when `layer.positionZ > camera.positionZ`, and pushing a layer
    // back means raising its Z -- the same direction After Effects uses.
    float positionZ = -1200.0f;
    // Pitch, yaw and roll, in radians.
    Vec3 rotation3D;
    // Vertical field of view, in DEGREES. Vertical because that is how
    // every compositor and game engine states it, so a 45-degree Scene
    // camera frames what a 45-degree Unity camera frames.
    float fieldOfView = 45.0f;
    // Nothing nearer than this is drawn. It is what stops a layer
    // approaching the eye from being magnified without bound -- the
    // formula itself is correct all the way in, so the clamp belongs here
    // rather than hidden inside the projection as a fudge factor.
    float nearZ = 1.0f;
    float farZ = 100000.0f;

    bool operator==(const SceneCamera&) const = default;

    Vec3 world() const { return Vec3(position.x, position.y, positionZ); }

    // The distance at which one world unit covers one pixel of view
    // height. Scale is 1 at exactly this distance, which is what makes a
    // Scene with its layers on the focal plane land on precisely the
    // pixels the editor's existing 2D path produces: an artist who never
    // touches Z sees nothing move.
    //
    // NOTE the deliberate inconsistency carried over from Swift: this does
    // NOT clamp the field of view, while `SceneProjection` clamps it to
    // 1..170. They differ only outside that range, and `Render/
    // SceneViewCamera.h`'s `shotFrame` documents why matching Swift wins
    // over being internally tidy -- the frustum gizmo has to land on the
    // frame the export actually renders.
    float focalLength(float viewHeight) const;
};

} // namespace umeshcore
