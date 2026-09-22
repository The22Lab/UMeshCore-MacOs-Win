#pragma once

// 1:1 port of `Render/SceneLightGizmo.swift` (253 L), plus
// `lightWorldGeometry` lifted out of `SceneGizmoOverlay.swift` -- where a
// light's handles are in WORLD space, and what a drag on one means.
//
// PURE GEOMETRY, on both sides. The Swift header opens by saying so:
// nothing here draws, nothing here knows about pixels. The overlay
// projects what this returns and hit-tests the result exactly as it does
// for a card's arrows, so a light's handles foreshorten, lean and turn
// into ellipses for free -- because that is what a real projection does to
// a real direction. It is the least SwiftUI-entangled file of the gizmo
// debt, and the most reusable.
//
// THE PLANE A FLAT VISUALISATION LIES IN, and why it faces the camera. A
// point light's influence is a SPHERE -- the attenuation is a 3D distance
// -- and the silhouette of a sphere is a circle facing the eye, so the
// ring is drawn in the plane through the light whose normal is the view
// axis. That is not a screen-space cheat, it is the correct world plane
// for that shape.
//
// The same plane answers the DRAGS, and the reason is a counting argument
// rather than a preference: a pointer gives two numbers, a radius wants
// one and a direction wants two, so the map from pointer to value is a
// bijection only once the missing degree of freedom is pinned. Pinning it
// to the plane the artist is looking at is what keeps the grabbed point
// under the pointer; pinning it anywhere else moves the handle away from
// the finger.
//
// `lightWorldGeometry` comes across with it because it is the SINGLE
// source both consumers read: the hit test takes its handle positions, and
// the GPU diagram (`SceneGizmoLayout::LightDiagram`, ported in Phase 4 and
// until now unfilled) takes its rings, edges and arcs. Two functions
// building the same light two ways is the failure this port keeps
// recording.

#include <optional>
#include <vector>

#include "umeshcore/Render/SceneGizmoLayout.h"
#include "umeshcore/Render/SceneProjection.h"
#include "umeshcore/Scene/SceneLight.h"

namespace umeshcore {

// Which of a light's own handles this is.
//
// Deliberately NOT "scale". A light has no size to scale: it has a radius,
// a cone, a fade band. Scaling a light by a factor would be a control
// whose meaning nobody could state, so each quantity gets a handle that
// says what it changes.
enum class SceneLightHandle {
    // The outer edge of the light's influence.
    kRadius,
    // Where the fade begins -- the inner edge of the band `softness` sets.
    kSoftness,
    // The far end of the beam. Drag it to aim the light.
    kDirection,
    // The cone's inner half-angle: full strength inside it.
    kInnerAngle,
    // The cone's outer half-angle: nothing outside it.
    kOuterAngle
};

// How near the pointer has to be to grab one of a light's dots. They are
// small and they sit close together, so the radius is generous -- and
// larger again for touch, where there is no cursor to aim with.
inline constexpr float kSceneLightGrabPixels = 16.0f;
inline constexpr float kSceneLightGrabTouchPixels = 24.0f;

// The handles a kind of light actually has, in a FIXED order.
//
// Fixed because hit testing walks it to break ties, and a tie broken by a
// container's iteration order would grab a different handle on a different
// run. For a spot the angles come BEFORE the radius: the two arcs sit ON
// the radius ring at the cone's edge, so where they overlap the more
// specific handle wins.
std::vector<SceneLightHandle> lightHandlesFor(SceneLightKind kind);

// Two orthonormal world vectors spanning the plane through the light that
// faces the camera. `u` is the camera's right and `v` its up, taken from
// the view matrix's own rows, so the frame IS the camera's and cannot
// drift from it.
GizmoRingFrame lightFacingFrame(const SceneProjection& projection);

// The camera's view axis, pointing away from the eye.
Vec3 lightViewAxis(const SceneProjection& projection);

// A circle of `radius` about the light, in the plane facing the camera.
std::vector<Vec3> lightRing(
    const Vec3& centre, float radius, const GizmoRingFrame& frame, int samples = 64);

// The plane a spot's cone is DRAWN in: it contains the beam axis and is
// turned as far towards the camera as it can be. Seen down the beam that
// degenerates -- every direction across the axis is equally side-on -- and
// the fallback is any perpendicular, which is honest: there is no widest
// view of a cone pointing at you.
Vec3 lightConePlane(const Vec3& axis, const SceneProjection& projection);

struct ConeRim {
    Vec3 a;
    Vec3 b;
};

// The two rim points of a cone of `halfAngle`, at `distance` from the
// light, in the cone's drawing plane.
ConeRim lightConeRim(
    const Vec3& centre, const Vec3& axis, const Vec3& across, float halfAngle, float distance);

// An arc of the cone's rim, swept between the two rim points through the
// axis -- the curve an artist reads as "the edge of the beam".
std::vector<Vec3> lightConeArc(
    const Vec3& centre, const Vec3& axis, const Vec3& across, float halfAngle, float distance,
    int samples = 24);

// Where a handle sits in the world. Absent when the light has no such
// handle -- a directional light has no radius, and asking for one should
// give nothing rather than a number derived from something else.
std::optional<Vec3> lightHandlePosition(
    SceneLightHandle handle, const SceneLight& light, const SceneProjection& projection,
    float directionLength);

// ---- What a drag means --------------------------------------------------

// The radius a pointer is asking for: how far the ray's hit on the facing
// plane is from the light.
//
// A DISTANCE, not a delta. The handle is on the rim, so the rim goes where
// the pointer is and the grabbed point stays under it -- which a delta
// added to the starting radius does not do once the camera is anywhere but
// square on.
float lightRadiusForHit(const Vec3& hit, const Vec3& centre);

// The cone half-angle a pointer is asking for, measured at the light.
// Absent when the hit is at the light itself, where there is no angle to
// read.
std::optional<float> lightHalfAngleForHit(const Vec3& hit, const Vec3& centre, const Vec3& axis);

// The softness a pointer is asking for, from where it put the inner edge.
// `softness` is the fraction of the radius the fade occupies, so an inner
// edge at distance `d` means `1 - d / radius`, clamped where it is read
// because a pointer dragged past the rim would otherwise ask for a
// negative band.
float lightSoftnessForHit(const Vec3& hit, const Vec3& centre, float radius);

// Point a light along a world direction, as azimuth and elevation -- the
// exact inverse of `SceneLight::direction()`, with the one case that has
// no inverse handled rather than left to produce a number.
//
// GIMBAL. A light pointing straight along Z has no azimuth: every azimuth
// gives the same direction, and `atan2(0, 0)` is 0. Taking that answer
// would silently snap the stored azimuth to zero, so tilting the light
// back out of the pole would swing it somewhere it was never pointed. The
// azimuth is left alone there instead, which makes aiming through the pole
// continuous.
void aimLight(SceneLight& light, const Vec3& direction);

// Turn a direction about a world axis by an angle (Rodrigues). This is
// what the rotate rings do to a light: a light stores where it POINTS, not
// a full orientation, so a turn is applied to the direction vector and
// re-expressed -- and a turn about the beam itself comes back as no
// change, which is correct, because a cone has nothing to roll.
Vec3 rotatedAbout(const Vec3& direction, const Vec3& axis, float angle);

// ---- The one geometry both consumers read -------------------------------

struct LightWorldGeometry {
    Vec3 centre;
    Vec3 viewAxis;
    // 0 when there is no ring to draw.
    float influenceRadius = 0.0f;
    float innerRadius = 0.0f;
    std::optional<SceneGizmoLayout::Segment> beam;
    std::vector<SceneGizmoLayout::Segment> outerEdges;
    std::vector<SceneGizmoLayout::Segment> innerEdges;
    std::vector<Vec3> outerArc;
    std::vector<Vec3> innerArc;
    // In `lightHandlesFor`'s fixed order, so a tie is broken the same way
    // on every run and on both platforms.
    std::vector<std::pair<SceneLightHandle, Vec3>> handlePositions;
};

// The beam is drawn a fixed number of PIXELS long for a directional light,
// which has no radius to borrow, and to the rim for the others -- so a
// spot's aim handle sits where its light actually stops.
LightWorldGeometry lightWorldGeometry(const SceneLight& light, const SceneProjection& projection);

// The same geometry as the GPU's diagram, so the shape the artist grabs
// and the shape the GPU draws are one description. Fills the
// `SceneGizmoLayout::LightDiagram` that Phase 4 defined and left unfilled.
SceneGizmoLayout::LightDiagram lightDiagram(
    const LightWorldGeometry& geometry, const SceneLight& light,
    const std::optional<SceneLightHandle>& highlighted);

} // namespace umeshcore
