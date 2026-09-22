#pragma once

// 1:1 port of `Render/SceneGPU/SceneGizmoMeshBuilder.swift` -- turns a
// `SceneGizmoLayout` into triangles: shaded cones and cylinders for the
// move/scale/shear arrows, tube-shaded tori for the rotate rings,
// translucent quads for the plane handles, and a light's own diagram.
//
// EVERYTHING IN WORLD SPACE. The vertex shader carries each vertex through
// the layout's `viewProjection` and slides it by `screenOffsetNDC` itself;
// nothing here knows about the screen.
//
// NO NEAR-PLANE CUTTING HERE, unlike the overlay's `ringArcs`. That
// function hand-rolls a cut because a SwiftUI `Canvas` stroke is a
// polyline with no notion of clip-space clipping -- a segment crossing the
// near plane has to be cut by hand or it closes the ring across the gap. A
// triangle handed to the GPU has no such problem: the rasteriser clips
// every primitive against the frustum, near plane included, exactly and
// for free. Reproducing the CPU workaround here would be solving a problem
// the hardware already solves, worse. (Note the contrast with
// `SceneProjection::clipAndProject`, which DOES cut: that one feeds CPU
// picking and the export path, where there is no rasteriser.)

#include <vector>

#include "umeshcore/Render/SceneGizmoLayout.h"
#include "umeshcore/Render/SceneGizmoTypes.h"

namespace umeshcore {

namespace SceneGizmoMeshBuilder {

// ---- Tuning ------------------------------------------------------------

// Radial segments for a cylinder or cone's round cross-section. Low enough
// that a gizmo redrawn every frame costs nothing worth measuring, high
// enough that the facets do not read as facets at handle size.
inline constexpr int kAxisSides = 12;
// Segments around the rotate ring's own circle, and around its tube.
inline constexpr int kRingSegments = 64;
inline constexpr int kTubeSides = 10;

// Fractions of `layout.scale` -- the one world length every handle is
// built at -- that lay out an arrow: most of the length is shaft, the rest
// is the head, and the head is visibly wider than the shaft the way every
// 3D editor's arrow is.
//
// GIRTH BUMPED UP FROM WHAT PURE PROPORTION WOULD GIVE, because the
// overlay's handle length is a quarter of what it once was. Scaled down by
// the same factor as the length, a shaft's radius lands under a pixel on
// screen at ordinary zoom -- a hairline that aliases away rather than a
// handle. Only the LENGTH took the 75% reduction.
inline constexpr float kShaftFraction = 0.78f;
inline constexpr float kShaftRadiusFraction = 0.06f;
inline constexpr float kHeadRadiusFraction = 0.14f;
inline constexpr float kCubeHalfExtentFraction = 0.075f;
inline constexpr float kTubeRadiusFraction = 0.026f;
inline constexpr float kPlaneQuadColorAlpha = 0.5f;

// A highlighted handle reads THICKER, not merely brighter -- the same idea
// the SwiftUI overlay carried as a stroke width.
inline constexpr float kHighlightedThicknessScale = 1.6f;

// A light's own diagram, as fractions of `layout.scale` like everything
// above. `layout.scale` is built at the GIZMO'S ORIGIN, which for a light
// target IS the light, so it is already "how many world units make a
// constant number of pixels at THIS light's own depth" -- the same
// screen-constant reference the axes use, reused rather than re-derived.
// The influence ring's and the cone's own RADIUS is not scaled by it at
// all: those come straight from the light, whatever size the artist set.
inline constexpr float kLightTubeRadiusFraction = 0.02f;
inline constexpr float kLightHandleSphereRadiusFraction = 0.06f;
inline constexpr float kLightCentreSphereRadiusFraction = 0.05f;
inline constexpr float kLightBeamHeadRadiusFraction = 0.09f;
// How much of the beam's own length its arrowhead occupies.
inline constexpr float kLightBeamHeadLengthFraction = 0.18f;

// ---- Build -------------------------------------------------------------

// The whole manipulator, as a triangle list.
//
// Emit order is load-bearing: the light's diagram first and UNDER the
// manipulator (it says what the light DOES, the arrows say what a drag
// would do, and a handle an artist is reaching for should never be hidden
// behind a ring), then planes, axes and rings, so nearly coincident
// translucent surfaces read the way they always did. Within each kind the
// order is `sceneGizmoSortKey`, whatever order the caller filled the
// layout in.
std::vector<SceneGizmoVertexIn> build(const SceneGizmoLayout& layout);

// ---- Primitives --------------------------------------------------------
//
// Exposed because the tests assert their properties directly (a torus's
// points all lie within a tube of its ring; a degenerate input emits
// nothing rather than NaNs) and because the Windows shell will want the
// same primitives for chrome of its own. They are pure geometry: no state,
// no layout.

// A round tube between two points, radial normals, NO CAPS -- a shaft
// meets its head or the origin square, and neither end is ever seen.
std::vector<SceneGizmoVertexIn> cylinder(
    const Vec3& base, const Vec3& tip, float radius, int sides, const Vec4& color);

// An arrowhead: a base ring, capped, coming to a point.
std::vector<SceneGizmoVertexIn> cone(
    const Vec3& base, const Vec3& apex, float radius, int sides, const Vec4& color);

// A small cube centred at `center`, aligned to `along` -- the scale/shear
// cap. Six faces, flat-shaded, each its own four corners.
std::vector<SceneGizmoVertexIn> cube(
    const Vec3& center, float halfExtent, const Vec3& along, const Vec4& color);

// A circle of `radius` swept by a tube of `tubeRadius`, in the plane whose
// normal is `normal`.
std::vector<SceneGizmoVertexIn> torus(
    const Vec3& center, const Vec3& normal, float radius, float tubeRadius, int ringSegments,
    int tubeSides, const Vec4& color);

// A low-poly UV sphere -- the light's centre marker and its handle dots.
// Rotationally symmetric, so unlike every other primitive here it needs no
// frame derived from a direction: the poles are just (0, 1, 0), and
// nothing about a sphere cares which way that points.
std::vector<SceneGizmoVertexIn> sphere(
    const Vec3& center, float radius, const Vec4& color, int latSegments = 6,
    int lonSegments = 10);

// A tube of constant radius following a polyline -- one cylinder per pair
// of consecutive points. Used for a cone's rim arc, which is a genuine
// PARTIAL circle and so cannot reuse `torus`, built for a full one.
std::vector<SceneGizmoVertexIn> tubeAlongPolyline(
    const std::vector<Vec3>& points, float radius, int sides, const Vec4& color);

} // namespace SceneGizmoMeshBuilder

} // namespace umeshcore
