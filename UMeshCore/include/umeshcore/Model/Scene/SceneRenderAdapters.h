#pragma once

// The seam between the Scene MODEL (this folder) and the Phase 4 RENDER
// math (`Render/`). Four small functions, each of which Phase 4
// deliberately left unwritten because the type it needed did not exist
// yet, and each of which its header named as "a one-line wrapper a caller
// writes once those types exist".
//
// WHY THEY LIVE HERE AND NOT IN `Render/`. Phase 4's whole scoping rule
// was that the render math takes camera parameters and world points, never
// a `SceneCamera` or a `SceneLayer` -- so a Metal or DirectX backend can
// consume it without dragging the composition model behind it. Putting
// these wrappers in `Render/` now would reverse that decision quietly.
// They point the other way: the model knows about the renderer, the
// renderer knows nothing about the model.

#include <vector>

#include "umeshcore/Model/Scene/SceneCamera.h"
#include "umeshcore/Model/Scene/SceneLayer.h"
#include "umeshcore/Render/SceneProjection.h"
#include "umeshcore/Render/SceneViewCamera.h"

namespace umeshcore {

// The shot camera as the matrices everything projects through -- Swift's
// `SceneProjection.init(camera:viewSize:)`.
//
// `viewSize` is the composition's RENDER SIZE for the shot, not the
// window: what the artist sees while flying must never change what comes
// out. The field of view is clamped to 1..170 inside the projection, as it
// always was.
SceneProjection sceneProjection(const SceneCamera& shot, const Vec2& viewSize);

// The shot camera seen as a 3D camera -- used to draw its frustum in the
// editor view and to look through it. Swift's
// `SceneViewProjection.init(shot:viewSize:)`, which differs from the above
// only in that it fixes the near plane at the fly camera's own and pushes
// the far plane out: it is a preview of the set, not the shot itself.
SceneProjection shotAsViewProjection(const SceneCamera& shot, const Vec2& viewSize);

// One point of a layer's card, layer-local (x right, y up, centred) to
// world.
//
// Scale, shear and roll in the card's own plane, then the tilt that lifts
// that plane into the world, then the layer's position. The lift is
// `SceneLayer::liftToWorld` rather than a copy of it, because the gizmo's
// frame needs the same lift WITHOUT the scale and shear, and two
// transcriptions of a rotation is how one of them ends up different.
Vec3 cardPoint(const SceneLayer& layer, const Vec2& local);

// A layer's card corners in world space, in a FIXED ORDER: top-left,
// top-right, bottom-right, bottom-left, as seen from the front. The same
// order `shotFrame` returns, so a caller can compare the two without
// remembering which is which.
//
// A true rotation, not the screen-space tilt the shot path uses for a card
// seen head-on: from the side, only a real corner in a real place can be
// drawn where it is.
std::vector<Vec3> cardCorners(const SceneLayer& layer, const Vec2& localMin, const Vec2& localMax);

// The shot's frame at a distance in front of it, from the camera itself --
// the parameters-only `shotFrame` in `Render/SceneViewCamera.h` is what
// does the work.
std::vector<Vec3> shotFrame(const SceneCamera& shot, const Vec2& renderSize, float distance);

} // namespace umeshcore
