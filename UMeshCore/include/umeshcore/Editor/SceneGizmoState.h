#pragma once

// The Scene gizmo's SHAPE for one frame, extracted from
// `SceneGizmoOverlay.swift` (1732 L) -- ROADMAP Risk #6, and the item the
// handoff note calls the most urgent of the three.
//
// WHY THIS IS AN EXTRACTION AND NOT A PORT. The math below lives inside a
// SwiftUI view body on the Swift side: it reads the view's own stored
// properties, returns `CGPoint`s in view space, and is interleaved with
// drawing. None of that survives a move to Windows, but the arithmetic has
// to, and porting it later straight out of a view body is far riskier than
// taking it out on the Mac first -- which is the order CLAUDE.md commits
// to. This file is the first half of that: everything `handleSet()` (the
// CPU hit test) and `gizmoLayout()` (the GPU's input) BOTH start from. The
// drag math is the second half and is not here yet.
//
// ONE STATE, TWO CONSUMERS. The Swift source is explicit that this is the
// point: "there is one place 'what does the gizmo look like right now'
// gets answered, so the shape a drag is measured against and the shape the
// GPU draws cannot disagree". Two functions kept in step by hand is what
// this replaces.
//
// PIXELS, NOT VIEW POINTS -- the one deliberate divergence. Swift's
// `handleSet()` converts every result through `toView`, which maps the
// rendered image's pixels into the SwiftUI layout's fitted rectangle. That
// mapping is platform layout: it belongs to each shell, and baking it in
// here would make the core answer in a coordinate system Windows does not
// have. Everything below speaks the projection's own pixels, y down, and
// each shell applies its own fitted-rect transform on the way out.

#include <optional>
#include <vector>

#include "umeshcore/Render/SceneGizmoLayout.h"
#include "umeshcore/Render/SceneProjection.h"
#include "umeshcore/Scene/SceneCamera.h"
#include "umeshcore/Scene/SceneLayer.h"
#include "umeshcore/Scene/SceneLight.h"

namespace umeshcore {

// ---- The numbers the shape is built from --------------------------------

// The handle's length, in the REAL camera's pixels. A quarter of what it
// once was, which shrinks the whole manipulator proportionally because
// every mesh radius in `SceneGizmoMeshBuilder` is a fraction of the world
// length derived from this.
//
// IT IS NOT THE DRAWN LENGTH, and that surprised this port. The world
// scale is taken through the REAL projection and the handles are then
// drawn through the STABILISED one, whose focal length is far longer, so
// the manipulator comes out magnified by the ratio of the two. Measured on
// a 45-degree camera over a 900-pixel view: focal 1086 against 8587, a
// ratio of 7.9, so a nominal 19.5 px handle draws at 154 px.
//
// What the constant really buys is DEPTH INVARIANCE, which is what the
// Swift source claims for it and what an artist relies on to grab a
// handle: measured at z = 0, 800 and 3000 with the same camera, the drawn
// length is 154.122 px every time. Off the view axis it shrinks a little
// (122 px at 600 units off, at that same depth), because the real
// projection's depth is measured ALONG ITS FORWARD while the gizmo
// camera's is the true distance to the pivot. Both behaviours are the
// Swift's; neither is changed here, and the test pins them so a future
// change to either projection cannot move the gizmo without saying so.
inline constexpr float kSceneGizmoHandlePixels = 19.5f;

// An axis drawn shorter than this is not drawn at all: the card is turned
// edge-on, so the axis has no direction worth trusting, and refusing the
// handle beats dividing a pointer delta by almost nothing and throwing the
// card off the set.
//
// SCALED WITH `kSceneGizmoHandlePixels`, at the same ~1/3 ratio it always
// had (it was 26 against a length of 78). Left at the old absolute value
// it would exceed the new, shorter handle length outright, and an axis
// facing the camera reasonably square-on would never draw -- a worse fault
// than the deformed arrowhead the constant was introduced to fix.
//
// Compared in the STABILISED camera's pixels, like the length above, so
// the effective floor is this number divided by the same 7.9 -- under one
// real pixel. That is generous rather than wrong: the case it exists for
// is an axis pointing almost exactly at the eye, where the span collapses
// to nothing and a drag would divide by it.
inline constexpr float kSceneGizmoMinAxisPixels = 6.5f;

// How near the pointer has to be to grab a handle. NOT scaled down with
// the gizmo's smaller size: a smaller target is exactly the case a
// generous grab radius is for.
inline constexpr float kSceneGizmoGrabPixels = 22.0f;

// The gizmo's own camera is nearly orthographic -- 3 degrees half-angle --
// so the shape it produces is undistorted wherever the object sits in the
// real frame.
inline constexpr float kSceneGizmoHalfFieldOfView = 3.0f * 3.14159265358979323846f / 180.0f;

// Samples around a projected ring.
inline constexpr int kSceneGizmoRingSamples = 64;

// How far past the near plane a cut point is pushed so a strict `>` guard
// still answers for it. A hair, in world units scaled by nothing: the
// plane is at 1 unit and this is four orders below it.
inline constexpr float kSceneGizmoNearNudge = 0.0001f;

// How square-on a plane must be seen before its handle is offered. Below
// this the quad is a sliver to aim at AND the ray-plane intersection
// behind it is ill-conditioned, so it is withdrawn on the same fact that
// makes it useless rather than drawn and then failing under the finger.
inline constexpr float kSceneGizmoMinPlaneFacing = 0.25f;

// ---- The basis ----------------------------------------------------------

// The three directions a gizmo's handles are built along, plus where they
// start.
//
// This is what makes the handles turn with the camera the way a 3D
// editor's do: every arrow, ring and plane handle is built from these and
// then PROJECTED, so orbiting foreshortens them, leans them and turns the
// rings into ellipses -- all of it for free, because it is what a real
// projection does to a real direction.
struct SceneGizmoBasis {
    Vec3 origin;
    Vec3 x = Vec3(1, 0, 0);
    Vec3 y = Vec3(0, 1, 0);
    Vec3 z = Vec3(0, 0, 1);

    // The axis a handle id names, or nothing for the handles that are not
    // axes.
    std::optional<Vec3> direction(SceneGizmoHandleId id) const;
};

// A card's X and Y are its OWN plane axes, so a rotated or sheared card's
// handles lie along the card, and its Z is the card's normal.
//
// THE ELEMENT'S ROTATION, AND NOTHING ELSE: `SceneLayer::orientation()`,
// never a frame differenced out of the card's own transform. Differencing
// runs a point through `planePoint` -- scale, then SHEAR, then roll -- and
// normalising the results fixes their lengths while doing nothing about
// the angle between them, so a sheared card hands back a frame that is not
// a rotation, and a frame like that shears every arrow it multiplies.
SceneGizmoBasis layerBasis(const SceneLayer& layer);

// The layer's MOVE axes, fixed to the world rather than to its rotation.
//
// Rotate, scale and shear all want `layerBasis` -- that is the whole point
// of it. But it would mean the translate arrows visibly spin with the
// card's own roll and tilt, which is not what an artist reaching for
// "move" expects: the handle that answers "where is X" should not change
// answer because the card turned. So translate alone gets literal world
// axes, with the card's origin as the only thing carried over.
SceneGizmoBasis worldBasis(const SceneLayer& layer);

// The ONE place "which basis does this tool draw and drag from" is decided
// for a layer. Both the hit test and the drag call this rather than each
// making the choice, so the arrows on screen and the axes a drag moves
// along can never disagree.
SceneGizmoBasis translateBasis(const SceneLayer& layer, SceneGizmoTool tool);

// A point light gets the WORLD axes: it has no orientation, and handles
// along an invented one would turn with nothing. Spots and directionals
// get a frame built on their BEAM -- z is where they point, x and y across
// it -- so translating a spot along z walks it up its own beam and the
// rings about x and y aim it. There is no roll ring that does anything,
// and that is correct rather than missing: a cone is round, and a light
// stores where it points, not a full orientation.
SceneGizmoBasis lightBasis(const SceneLight& light);

SceneGizmoBasis cameraBasis(const SceneCamera& camera);

// ---- The stabilised projection ------------------------------------------

// The gizmo's OWN camera, for SHAPE only: same eye as the real one,
// recentred on `origin` with a narrow fixed field of view, so the handles
// are built as though the object sat in the middle of a near-orthographic
// frame -- no wide-FOV skew -- and then slide back onto the object's true
// screen position by a rigid 2D offset.
//
// Falls back to the real projection when the eye sits exactly on the
// origin: there is no direction to look along, and dividing by zero would
// put NaNs into every handle.
SceneProjection gizmoProjection(
    const Vec3& origin, const SceneProjection& real, const Vec2& viewSize);

// Everything the gizmo looks like THIS pass, before any drawing or hit
// testing: which basis is in play, the one uniform scale, the real
// projection, and the stabilised pair.
struct SceneGizmoState {
    SceneGizmoBasis basis;
    // ONE world length for the whole manipulator, from the REAL pivot
    // depth -- the gizmo's own narrow FOV must not change the constant
    // on-screen size the artist relies on to grab a handle.
    //
    // One number, so the arrow mesh scales UNIFORMLY. Each axis used to
    // measure itself against the screen and take its own length, which
    // gave one gizmo three differently sized arrows -- and the more
    // foreshortened an axis was, the longer its world length became, so
    // its head grew as it turned away. Foreshortening is the projection's
    // job; it is not the mesh's.
    float scale = 0.0f;
    SceneProjection realProjection;
    // Shape only -- never read by drag math.
    SceneProjection projection;
    Vec2 screenOffsetPx;

    // A world point, in the pixels the manipulator is drawn in.
    std::optional<Vec2> map(const Vec3& world) const;
};

// Absent when the pivot cannot be projected at all, or when the scale
// comes back non-positive -- a gizmo with no size is not drawn and not
// grabbed, rather than drawn at a size that means nothing.
std::optional<SceneGizmoState> sceneGizmoState(
    const SceneGizmoBasis& basis, const SceneProjection& real, const Vec2& viewSize);

// ---- The shape ----------------------------------------------------------

// One axis of the gizmo, in pixels: where it starts, where its tip lands,
// and the unit direction between them.
struct SceneGizmoScreenAxis {
    Vec2 origin;
    Vec2 tip;
    Vec2 direction;
};

// The direction is the element's, the length is the gizmo's own uniform
// scale, and the projection is what shortens it when it points away. No
// part of the element's scale or shear is anywhere in this chain.
//
// Absent when either end fails to project, or when the projected span is
// under `kSceneGizmoMinAxisPixels`.
std::optional<SceneGizmoScreenAxis> projectAxis(
    const SceneGizmoState& state, const Vec3& direction);

// How solid an axis is drawn: full strength for the end coming toward the
// viewer, dimmed for the one pointing away. Read off the REAL camera --
// "which end is nearer the eye" does not need the stabilised one to
// answer. Dimmed, never hidden: an axis you cannot see is one you cannot
// grab, and half the camera angles would lose one.
float axisDepthAlpha(const SceneGizmoState& state, const Vec3& direction);

// A circle about `normal`, projected: an ellipse once the camera is
// anywhere but square on to it, and a line when it is edge-on.
//
// ARCS, PLURAL, and this is the one place the CPU path does something the
// GPU path does not have to. A ring crossing the near plane must be CUT --
// a polyline has no notion of clip-space clipping, so joining the pieces
// back up would draw a chord straight across the gap. The GPU's own ring
// is a torus of triangles and the rasteriser clips it exactly, for free,
// which is why `SceneGizmoMeshBuilder` deliberately has no equivalent of
// this function.
std::vector<std::vector<Vec2>> ringArcs(
    const SceneGizmoState& state, const Vec3& normal, float radius);

// The two axes a plane handle spans, and the normal it is seen through.
std::optional<Vec3> planeNormal(SceneGizmoHandleId id, const SceneGizmoBasis& basis);
struct PlaneAxes {
    Vec3 a;
    Vec3 b;
};
PlaneAxes planeAxes(SceneGizmoHandleId id, const SceneGizmoBasis& basis);

// The four corners of a plane handle's quad, in pixels, or nothing when
// the plane is turned too far edge-on to be worth offering (see
// `kSceneGizmoMinPlaneFacing`) or when a corner will not project.
std::optional<std::vector<Vec2>> planeQuad(
    const SceneGizmoState& state, SceneGizmoHandleId id);

} // namespace umeshcore
