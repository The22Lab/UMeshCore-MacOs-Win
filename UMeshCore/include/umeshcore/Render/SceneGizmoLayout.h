#pragma once

// 1:1 port of `Render/SceneGPU/SceneGizmoLayout.swift` -- the Scene
// gizmo's geometry for one frame, in world space: the CPU-only description
// of a shape that `SceneGizmoMeshBuilder` turns into triangles.
//
// NO screen types, NO view framework -- that is the point of the type on
// both sides. The Swift header records why it matters: the shape is built
// by the SAME `gizmoState()` the overlay hit-tests a drag against, "so the
// manipulator the GPU draws and the manipulator a drag is hit-tested
// against can never disagree about where an axis points, how long it is,
// or which one is highlighted".
//
// A few pieces of `SceneGizmoOverlay.swift` come across with it, because
// the builder reads them and they are pure geometry: `ringFrame`, the
// plane-quad placement, the view ring's scale and the away-facing alpha.
// That file is ROADMAP Risk #6 -- 1732 lines of real math inside SwiftUI
// view bodies -- and this is the first bite of the extraction CLAUDE.md
// calls for: take the math out into the core BEFORE the Windows UI needs
// an equivalent, rather than porting it later straight out of a view body.
// Nothing else of the overlay is touched here.
//
// What is deferred, and why:
//   - `SceneGizmoTarget` and the light handle's payload. Both name Phase 5
//     types (`SceneLayer`, `SceneLight`, `SceneLightGizmo.Handle`). The
//     builder never reads them: a light's handles reach it as positions in
//     `LightDiagram`, and the handle id only has to ORDER the buffer, so
//     `kLight` is a single case here rather than a wrapped payload.
//   - Everything that BUILDS a layout (`gizmoState`, `handleSet`,
//     `gizmoScale`, the drag math). That is the rest of Risk #6's
//     extraction and needs the Phase 5 model; this file is the handoff
//     shape between it and the mesh builder.

#include <cmath>
#include <optional>
#include <vector>

#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

// Four, and the same four the rig's toolbar offers, so the gesture an
// artist learns on a sprite is the gesture that moves a card.
enum class SceneGizmoTool { kTranslate, kRotate, kScale, kShear };

// The three axes serve twice: as arrows for translate, scale and shear,
// and as the RINGS that turn about them for rotate. One vocabulary, so a
// red handle means the x axis whatever tool is showing.
//
// THE VALUES ARE A FIXED EMIT ORDER, not decoration -- see
// `sceneGizmoSortKey`.
enum class SceneGizmoHandleId {
    kAxisX = 0,
    kAxisY = 1,
    kAxisZ = 2,
    kPlaneXY = 3,
    kPlaneXZ = 4,
    kPlaneYZ = 5,
    kFree = 6,
    kUniform = 7,
    // Rotation about the axis you are looking along -- the one turn no
    // world axis matches, so the one handle that is honestly screen-space.
    kViewRing = 8,
    // A light's own handle. Flattened to one case here: see the header.
    kLight = 9
};

// A FIXED order to build and emit in, for the reason every other fixed
// handle order in this feature exists: Swift's `Dictionary` seeds its
// order per process (and C++'s `unordered_map` gives no order worth
// relying on either), and a gizmo whose triangles came out in a different
// sequence on every launch is not a rendering bug today but is one nobody
// could ever reproduce. Two platforms emitting the same buffer is the
// stronger version of the same argument.
inline int sceneGizmoSortKey(SceneGizmoHandleId id) { return static_cast<int>(id); }

// ---- The pieces of `SceneGizmoOverlay` the builder reads ----------------

// An orthonormal pair spanning the plane perpendicular to `normal`.
//
// The helper axis switches at |y| = 0.9 so the cross product never runs
// against a near-parallel pair, and the guard returns a valid frame rather
// than a normalised zero: a degenerate frame here would come out as NaN
// vertices, which is a gizmo that silently fails to draw.
struct GizmoRingFrame {
    Vec3 u;
    Vec3 v;
};

inline GizmoRingFrame gizmoRingFrame(const Vec3& normal) {
    const Vec3 helper = std::fabs(normal.y) < 0.9f ? Vec3(0, 1, 0) : Vec3(1, 0, 0);
    Vec3 u = cross(normal, helper);
    const float len = length(u);
    if (!(len > 0.00001f)) return GizmoRingFrame{Vec3(1, 0, 0), Vec3(0, 1, 0)};
    u = u / len;
    return GizmoRingFrame{u, cross(normal, u)};
}

// Where the plane quad sits along its two axes, as a fraction of the
// gizmo's scale, and how big it is. Off the origin so it never covers the
// free-move handle, and short so it never reaches the arrowheads.
inline constexpr float kSceneGizmoPlaneOffset = 0.30f;
inline constexpr float kSceneGizmoPlaneSize = 0.26f;
// The view ring sits outside the three world rings so the two kinds never
// overlap.
inline constexpr float kSceneGizmoViewRingScale = 1.28f;
// Dimmed, never hidden -- an axis you cannot see is an axis you cannot
// use, and half the camera angles would lose one.
inline constexpr float kSceneGizmoAwayAlpha = 0.45f;

// ---- The layout itself -------------------------------------------------

struct SceneGizmoLayout {
    // Which cap the builder puts at an axis's tip.
    enum class AxisHead {
        // Translate: a cone, so the axis reads as a direction to slide
        // along.
        kArrow,
        // Scale and shear: a cube, so the handle reads as something to
        // grab and pull rather than a direction to travel. Generalised to
        // shear rather than reproducing the screen-space slanted bar the
        // SwiftUI version drew, which had no honest 3D equivalent -- it
        // was a 2D "slides sideways" affordance.
        kCube
    };

    // One axis arrow: a shaft plus a head, along `direction` from `origin`
    // for `scale` world units.
    struct AxisGeometry {
        Vec3 direction;
        Vec4 color;
        bool highlighted = false;
        // The far end's alpha: 1 when the axis comes toward the viewer,
        // dimmed when it points away.
        float awayAlpha = 1.0f;
        AxisHead head = AxisHead::kArrow;
    };

    // One rotation ring: a tube-shaded circle of radius `scale`, in the
    // plane whose normal is `normal`.
    struct RingGeometry {
        Vec3 normal;
        Vec4 color;
        bool highlighted = false;
        float awayAlpha = 1.0f;
    };

    // One plane handle: a small quad spanning `a`/`b`, offset from
    // `origin` and sized by the two constants above, both scaled by
    // `scale` at mesh-build time -- the same numbers the hit test's
    // plane-quad corners use.
    struct PlaneGeometry {
        Vec3 a;
        Vec3 b;
        Vec4 color;
        bool highlighted = false;
    };

    // The free-move / uniform-scale handle at the gizmo's own origin.
    // Absent for rotate and shear, which have no handle there.
    struct CenterHandle {
        Vec4 color;
        bool highlighted = false;
    };

    struct Segment {
        Vec3 from;
        Vec3 to;
    };

    struct LightHandle {
        Vec3 position;
        bool highlighted = false;
    };

    // A light's own diagram -- sphere of influence, a spot's cone, the aim
    // beam, and a dot at each of its own handles. Absent for anything that
    // is not a light.
    //
    // GPU-drawn for the same reason the shared manipulator is: this was a
    // SwiftUI `Canvas`, redrawn only on SwiftUI's own cadence, which is
    // exactly why a light's diagram and its already-GPU-drawn handles could
    // visibly separate from each other during a trackpad gesture. Placed
    // through the SAME stabilised projection as everything else here, so
    // the two can no longer disagree.
    struct LightDiagram {
        Vec3 centre;
        Vec4 tint;
        bool isEnabled = true;
        // The plane every camera-facing shape here lies in.
        Vec3 viewAxis;
        // 0 means no ring to draw.
        float influenceRadius = 0.0f;
        float innerRadius = 0.0f;
        std::optional<Segment> beam;
        std::vector<Segment> outerEdges;
        std::vector<Segment> innerEdges;
        std::vector<Vec3> outerArc;
        std::vector<Vec3> innerArc;
        std::vector<LightHandle> handles;
    };

    // Swift keys these by `HandleID` in a Dictionary and sorts on the way
    // out. Here they are vectors carrying their id, and the builder sorts
    // by the same fixed key -- same guarantee, one less thing whose
    // iteration order has to be argued about.
    template <typename Geometry>
    struct Entry {
        SceneGizmoHandleId id = SceneGizmoHandleId::kAxisX;
        Geometry geometry;
    };

    SceneGizmoTool tool = SceneGizmoTool::kTranslate;
    Vec3 origin;
    // The one uniform world length every axis, ring and plane is built at
    // -- `SceneProjection::worldLengthForPixels` at the pivot's depth, so
    // the whole manipulator holds a constant size on screen.
    float scale = 1.0f;

    std::vector<Entry<AxisGeometry>> axes;
    std::vector<Entry<RingGeometry>> rings;
    std::vector<Entry<PlaneGeometry>> planes;

    // The fourth, honestly-screen-space rotate ring -- turning about the
    // view axis, billboarded to face `forward` rather than lying in a
    // world plane.
    bool showViewRing = false;
    Vec4 viewRingColor;

    std::optional<CenterHandle> centerHandle;

    // The eye every axis/ring/plane's shading is lit relative to -- the
    // REAL camera's eye, not the stabilised one (they share the same eye,
    // so there is only one honest answer to "where is the viewer").
    Vec3 eye;
    // The stabilised gizmo camera's own forward -- what the view ring
    // billboards to face.
    Vec3 forward = Vec3(0, 0, 1);

    std::optional<LightDiagram> lightDiagram;

    // The stabilised, recentred projection's view-projection matrix.
    Mat4 viewProjection = Mat4::identity();
    // The rigid 2D slide, in clip-space units, that moves the stabilised
    // shape from screen centre onto the object's true screen position:
    // `clip.xy += screenOffsetNDC * clip.w` in the vertex shader, BEFORE
    // the perspective divide -- the exact GPU-side equivalent of the CPU's
    // `+ screenOffsetPx` after projecting.
    Vec2 screenOffsetNDC;
};

} // namespace umeshcore
