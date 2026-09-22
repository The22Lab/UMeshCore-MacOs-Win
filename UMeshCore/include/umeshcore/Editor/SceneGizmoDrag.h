#pragma once

// The other half of the Scene gizmo, extracted from
// `SceneGizmoOverlay.swift`: which handle a point grabs, and what a drag
// on it does to a layer. `Editor/SceneGizmoState.h` is the shape this
// reads; together they are Risk #6's gizmo debt for layers.
//
// EVERY MEASUREMENT IS MADE WHERE THE QUESTION LIVES, and that is the
// whole of what this file is worth porting for. The Swift source replaced
// a screen-space implementation and recorded what it cost:
//
//   - An axis drag is the closest approach of the pointer's RAY to the
//     axis line, at the start of the drag and now. The screen-delta
//     alternative -- the pointer offset projected onto the axis's screen
//     direction, divided by a pixels-per-unit taken at the pivot -- is
//     right only where the projection is affine. Under perspective that
//     ratio changes along the axis and with depth, so a card lagged when
//     dragged away from the camera and overshot when dragged towards it.
//     Measured at 313 px between the grabbed point and the pointer at the
//     worst of nine camera angles; through the ray, 0.0000 px at all of
//     them.
//   - A rotation is read IN THE RING'S OWN PLANE, not as a screen angle
//     swept about the gizmo's projected centre. A screen angle is right
//     only for the ring facing the camera: at a slant the same sweep means
//     a bigger turn (39 degrees out on turns of 8 to 50), and near edge-on
//     very much bigger (104). In the ring's plane the error is zero at
//     every angle.
//   - A plane handle is ONE ray-plane intersection, not two axis
//     measurements run side by side inheriting both their errors.
//
// `Editor/verify_scene_gizmo_drag.py`, which those figures come from, is
// not in this repository (see CLAUDE.md). The tests assert the property it
// was measuring -- the grabbed point stays under the pointer -- and
// reproduce the screen-space method alongside to show it does not.
//
// ONE EXCEPTION, AND IT IS DELIBERATE. The shear tool's Z handle is a
// RATE, not a geometric quantity: "how much tip per how much drag". There
// is no world length for a ray to find, so it stays in pixels, and saying
// so beats dressing it up as geometry.

#include <optional>
#include <vector>

#include "umeshcore/Editor/SceneGizmoState.h"
#include "umeshcore/Editor/SceneLightGizmo.h"
#include "umeshcore/Scene/SceneCamera.h"
#include "umeshcore/Scene/SceneLayer.h"

namespace umeshcore {

// How much the shear tool's Z handle tips the card per pixel dragged.
inline constexpr float kSceneGizmoRadiansPerPixel = 0.008f;

// ---- The projected shape, as the hit test needs it ----------------------

// Everything `handleSet()` builds in one pass: the gizmo's origin and each
// handle's projected geometry. Built for EVERY tool, like the Swift, so a
// caller switching tools mid-frame cannot read a stale half-built set --
// the tool decides which parts are TESTED, not which parts exist.
struct SceneGizmoShape {
    Vec2 originPx;
    // Only the axes that survived `kSceneGizmoMinAxisPixels`.
    std::vector<std::pair<SceneGizmoHandleId, SceneGizmoScreenAxis>> axes;
    // Each axis's ring, already projected and CUT at the near plane.
    std::vector<std::pair<SceneGizmoHandleId, std::vector<std::vector<Vec2>>>> rings;
    // Each plane handle's quad, or nothing where it was withdrawn.
    std::vector<std::pair<SceneGizmoHandleId, std::vector<Vec2>>> planes;
    // The view ring's radius in pixels, which is what a radial test needs.
    float ringRadiusPx = kSceneGizmoHandlePixels;
    // A light's own dots, in `lightHandlesFor`'s fixed order. Empty for
    // anything that is not a light, so every other caller is untouched.
    //
    // Projected through the REAL camera, not the stabilised one: a light's
    // diagram is not part of the manipulator's stabilisation pass, and the
    // dots have to sit on the rings and arcs the GPU draws from the same
    // world geometry.
    std::vector<std::pair<SceneLightHandle, Vec2>> lightHandles;
};

// `lightGeometry` is optional: pass it when the gizmo's target is a light,
// and its handle positions are projected and added to the shape.
std::optional<SceneGizmoShape> buildGizmoShape(
    const SceneGizmoState& state, const LightWorldGeometry* lightGeometry = nullptr);

// ---- The hit test -------------------------------------------------------

struct SceneGizmoHit {
    SceneGizmoHandleId id = SceneGizmoHandleId::kAxisX;
    // Carried for the one handle that needs its screen direction while
    // dragging: the shear tool's Z, whose along/across split is measured
    // in pixels.
    std::optional<SceneGizmoScreenAxis> axis;
    // Set when `id` is `kLight`: which of the light's own handles it is.
    // `kLight` is one flat case precisely so this can carry the payload
    // without the buffer-ordering enum growing five more members.
    std::optional<SceneLightHandle> lightHandle;
};

// Which handle a point grabs. NO SIDE EFFECTS: a shell asks this to decide
// whether a finger is a tool or navigation, long before any undo state is
// pushed.
//
// The order is fixed and it matters twice over. Planes are tested before
// axes and at a smaller radius, because a quad is an AREA -- being inside
// it is the test -- and a plane that happens to lie near an arrow should
// not steal it. And within each kind the order is `sceneGizmoSortKey`,
// never a container's iteration order: two handles at exactly equal
// distance would otherwise be resolved by the run, and a gizmo that grabs
// a different axis on Tuesday is a gizmo nobody trusts.
//
// FINDING, CARRIED ACROSS RATHER THAN FIXED: that ordering makes the
// CENTRE handle (free move, and uniform scale) unreachable whenever any
// axis is drawn. Every axis segment STARTS at the gizmo's origin, so the
// distance to an axis is never greater than the distance to the centre --
// they are equal exactly when the nearest point on the axis is the origin
// itself -- and the tie goes to whoever was tested first, which is the
// axis. Measured here: over the 61x61 pixels around the origin, with the
// translate tool and two axes drawn, 2618 of the grabs land on a handle
// and NONE of them is the centre.
//
// It is left as it is, because this port's job is to be the same program
// on two platforms and a silent behaviour change is the one thing that
// cannot be told apart from a transcription bug. The test pins it, so
// whoever decides to change it (test the centre first, or start the axes
// a few pixels out from the origin) will be told exactly what they moved.
// A LIGHT'S OWN HANDLES ARE TESTED FIRST, and by NEAREST rather than by
// first match. They are dots, they sit close together -- at a narrow cone
// the two arc handles meet the rim within a few pixels of each other --
// and taking the first one in range would let the list's order decide
// which of two adjacent handles you got. They come before the axes because
// a dot sitting on top of an arrow is the thing you are reaching for: the
// arrow is long and easy to find elsewhere, while the dot is the only
// place that value can be changed at all.
std::optional<SceneGizmoHit> hitTestGizmo(
    const SceneGizmoShape& shape, const Vec2& pointPx, SceneGizmoTool tool,
    float lightGrabPx = kSceneLightGrabPixels);

// ---- The measurements ---------------------------------------------------

// World units this drag asks for along a world axis. Absent when the axis
// points straight at the eye -- there is no honest answer there, and
// refusing is what the minimum-axis-length guard reaches for by a
// different route.
std::optional<float> axisDragUnits(
    const SceneProjection& projection, const Vec2& startPx, const Vec2& nowPx, const Vec3& origin,
    const Vec3& direction);

// Where a drag has moved a point, within a world PLANE through the pivot.
std::optional<Vec3> planeDragDelta(
    const SceneProjection& projection, const Vec2& startPx, const Vec2& nowPx, const Vec3& pivot,
    const Vec3& normal);

// The turn a drag asks for about a world axis, measured in the ring's own
// plane and in the same frame `ringArcs` drew the ring in -- a different
// frame would offset every angle by a constant, invisible in a delta and
// wrong the moment anything reads an absolute.
std::optional<float> ringDragAngle(
    const SceneProjection& projection, const Vec2& startPx, const Vec2& nowPx, const Vec3& pivot,
    const Vec3& normal);

// The angle a drag sweeps about a point ON SCREEN. Used by the view ring
// alone, where it is not an approximation but the definition: that ring's
// plane IS the screen.
float screenAngleDelta(const Vec2& originPx, const Vec2& startPx, const Vec2& nowPx);

// ---- Applying a drag ----------------------------------------------------

struct SceneGizmoDrag {
    SceneGizmoHandleId handle = SceneGizmoHandleId::kAxisX;
    Vec2 startPx;
    // The grabbed axis's screen direction, for the shear tool's Z handle.
    std::optional<SceneGizmoScreenAxis> axis;
    // Which of a light's own handles, when `handle` is `kLight`.
    std::optional<SceneLightHandle> lightHandle;
};

// Move the layer to where this drag now points.
//
// ALWAYS FROM `start`, never from the layer's current value. The handles
// that end in a clamp -- a scale at 0.01 -- would otherwise ratchet: push
// a value past its limit and the delta that would bring it back was
// already swallowed by the clamp, so the card never comes home.
//
// `cardHalfExtent` is the card's own half size in layer-local units, which
// is what makes a shear of 1 mean "dragged by the card's own extent"
// whatever size the card is. It is INJECTED because deriving it needs the
// asset's pixel size or the shot's frame, neither of which belongs in the
// core -- the same "inject what's needed" rule the rest of the port uses.
//
// `projection` is the REAL camera, never the gizmo's stabilised one: the
// stabilised projection is a shape device, and measuring a drag through it
// would answer in a space the pointer does not live in.
void applyLayerDrag(
    SceneLayer& layer, const SceneLayer& start, SceneGizmoTool tool, const SceneGizmoDrag& drag,
    const Vec2& nowPx, const SceneProjection& projection, const Vec2& cardHalfExtent);

// What a drag does to a LIGHT.
//
// ALWAYS FROM `start`, and here the reason is sharper than for a card: the
// handles that end in a clamp -- a radius at zero, a cone at half a turn
// -- would otherwise RATCHET. Push a value past its limit and the delta
// that would bring it back was already swallowed by the clamp, so the
// light never comes home.
//
// Every one of a light's own handles is answered on the world plane
// through the light that FACES THE CAMERA, which is what keeps the grabbed
// point under the pointer at any camera angle. The one exception is the
// cone's two angle handles, read in the CONE'S OWN plane: the angle being
// read is the angle the arc was drawn at, and reading it anywhere else
// would answer a different question.
//
// The shared handles -- the arrows and the rings -- mean for a light what
// they mean for a card, so they go through the same measurements. Scale
// and shear do nothing at all: a light has no size to scale and no plane
// to slant. Its size IS its radius and its cone, and those have handles of
// their own that say what they change.
void applyLightDrag(
    SceneLight& light, const SceneLight& start, SceneGizmoTool tool, const SceneGizmoDrag& drag,
    const Vec2& nowPx, const SceneProjection& projection, const Vec2& originPx);

// What a drag does to the SHOT CAMERA. Translate and rotate only -- a
// camera has neither a size nor a slant.
void applyCameraDrag(
    SceneCamera& camera, const SceneCamera& start, SceneGizmoTool tool,
    const SceneGizmoDrag& drag, const Vec2& nowPx, const SceneProjection& projection,
    const Vec2& originPx);

// ---- The two screen predicates the hit test is built on -----------------

// Distance from a point to a segment, clamped to its ends.
float distanceToSegment(const Vec2& point, const Vec2& a, const Vec2& b);

// Whether a point is inside a convex polygon -- the test a plane handle
// wants, because a quad is an area and not a line to be near.
bool convexContains(const std::vector<Vec2>& polygon, const Vec2& point);

} // namespace umeshcore
