#pragma once

// 1:1 port of `Render/SceneProjection.swift` -- the ONE way a scene turns
// world coordinates into pixels: a view matrix, a perspective projection
// matrix, and a divide by w.
//
// One, deliberately and load-bearingly. The Swift file's own header
// records why: the rig side already had three copies of world-to-screen
// (`MetalRenderer.project3DToScreen`, `ToolUtilities.project3DToScreen`,
// and an inline expression in the exporter) and they already DISAGREED --
// the exporter had no `rotation3D` term, so a sprite rotated in 3D
// exported differently from how it looked on the canvas. A scene is
// composed on one canvas and delivered as video rendered somewhere else;
// when those disagree the artist finds out after rendering.
//
// That is also why this is the first piece of Phase 4 and why it lives in
// the shared core: ROADMAP's Phase 2 note already committed to picking and
// rendering sharing ONE projection implementation, never two. A Metal
// backend and a DirectX backend that each re-derived this would reproduce
// the exact class of bug the file exists to prevent.
//
// Takes camera parameters directly (eye, pitch/yaw/roll, field of view,
// near/far) rather than a `SceneCamera`, which belongs to Phase 5's
// Scene-compositing model and is not ported. Same "inject what's needed"
// scoping the rest of this port uses; the two Swift convenience
// initializers that take a `SceneCamera` or a `SceneViewCamera` are
// one-line wrappers a caller writes once those types exist, and the
// `fromFrame` factory below is exactly what the fly-camera one needs.
//
// Conventions worth stating because they are easy to get backwards:
//   - The camera looks along +Z, so the projection row that writes w reads
//     z with a +1, not the -1 a look-down-minus-Z convention would use.
//   - Screen coordinates are PIXELS with y DOWN.
//   - `project` returns nullopt for a point at or behind the near plane
//     rather than a clamped number: a point behind the eye has no honest
//     projection, and answering with a large or mirrored one puts garbage
//     on screen that reads as a rendering bug rather than as a layer in
//     the wrong place.

#include <optional>
#include <vector>

#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

// An orthonormal camera frame. Kept as its own type because the orbit and
// the card geometry are written in these vectors, and re-deriving angles
// from them to rebuild the same matrices would be a second transcription
// of the camera -- the failure this whole file exists to prevent.
struct CameraBasis {
    Vec3 right;
    Vec3 up;
    Vec3 forward;
};

// Port of `SceneViewProjection.basis(pitch:yaw:roll:)`. Yaw about world Y,
// then pitch, then roll about the view axis.
CameraBasis cameraBasis(float pitch, float yaw, float roll);

class SceneProjection {
public:
    // World to camera: undo the camera's rotation, then its position.
    Mat4 viewMatrix = Mat4::identity();
    // Camera to clip. A real perspective matrix -- the w it writes is what
    // every point is divided by.
    Mat4 projectionMatrix = Mat4::identity();
    // Pixel size of the surface being drawn into. For the render camera
    // this is the composition's render size, NOT the window: what the
    // artist sees while flying must never change what comes out.
    Vec2 viewSize;
    // Nothing closer than this along the view axis is drawn.
    float nearZ = 1.0f;
    Vec3 eye;
    // Pixels a world unit covers at unit depth, perpendicular to the view
    // axis. ONE number for every direction, because the projection is
    // uniform: `pixels = focalLength * length / depth`. It is what sizes a
    // gizmo to a constant pixel size without measuring each of its axes
    // separately -- measuring per axis is what gave one gizmo three
    // different arrows.
    float focalLength = 1.0f;

    SceneProjection() = default;

    // From angles and a field of view (degrees), clamped to 1..170.
    SceneProjection(
        const Vec3& eye, float pitch, float yaw, float roll, float fieldOfView, float nearZ, float farZ,
        const Vec2& viewSize);

    // From an orthonormal frame rather than from angles -- see CameraBasis.
    static SceneProjection fromFrame(
        const Vec3& eye, const CameraBasis& basis, float focalLength, float nearZ, float farZ,
        const Vec2& viewSize);

    // A world point, in pixels (y down). nullopt at or behind the near plane.
    std::optional<Vec2> project(const Vec3& world) const;

    // World straight to clip. What a frustum's planes are pulled out of.
    Mat4 viewProjection() const { return projectionMatrix * viewMatrix; }

    // How far a world point is along the view axis.
    float depth(const Vec3& world) const;

    // The world length that projects to `pixels` at this depth -- the
    // inverse of `pixels = focalLength * length / depth`, and the one
    // number a gizmo needs to hold a constant size on screen.
    std::optional<float> worldLengthForPixels(float pixels, float depth) const;

    // ---- The near plane, cut rather than rejected ----

    // A world point carrying whatever has to survive being cut in half.
    // The attribute is the card's LOCAL point, which is what a UV is read
    // from. It rides along so a vertex invented on the near plane knows
    // which part of the texture belongs there -- without it the cut edge
    // samples the wrong pixels, and a card that draws the WRONG thing is a
    // worse bug than one that vanishes.
    struct AttributedVertex {
        Vec3 world;
        Vec2 attribute;
    };

    struct ProjectedVertex {
        Vec2 screen;
        Vec2 attribute;
    };

    // A convex polygon, cut to the near and far planes and projected.
    // Empty when none of it is inside.
    //
    // This is the fix for layers vanishing as the camera closes on them.
    // Every drawing path used to ask `project` for each corner and give up
    // the whole primitive when one came back nil. That is false: a quad
    // with one corner behind the eye is PARTLY visible, and the visible
    // part is a polygon. Since the nearest corner crosses long before the
    // centre does, and the gizmo projects the centre, the card went while
    // its handles stayed -- exactly how it was reported.
    //
    // The cut happens in CLIP space, before the divide, so a vertex made
    // by cutting has `clip.z == 0` (near) or `clip.z == clip.w` (far) BY
    // CONSTRUCTION: the divide that follows cannot fail, and the vertex
    // cannot land a hair on the wrong side of the very guard it was made
    // to satisfy. Cutting in world space and re-projecting would do
    // exactly that, and would show up as a one-pixel flicker along the cut.
    std::vector<ProjectedVertex> clipAndProject(const std::vector<AttributedVertex>& polygon) const;

    // True when the whole polygon is between the near and far planes, so
    // the cut would return it unchanged and the fast drawing paths still
    // apply. Cheap on purpose: this runs for every card of every frame,
    // and the answer is yes for all of them until the artist flies close.
    bool isWhollyVisible(const std::vector<Vec3>& worlds) const;

    // The four screen points a card's corners project to, INCLUDING any
    // behind the eye, as the homography that maps the card's texture.
    //
    // A card is a plane, so layer-local to screen is a homography, and a
    // homography is fixed by four point correspondences. A corner behind
    // the eye divides by a negative w and lands at the antipode -- not an
    // error to guard away but the correct projective image of that corner.
    // That is what lets the visible part be drawn with real perspective
    // rather than approximated. nullopt only for the genuine degeneracy: a
    // corner within `wEpsilon` of the plane through the eye, where the
    // divide is meaningless and no homography exists.
    std::optional<std::vector<Vec2>> projectiveQuad(const std::vector<Vec3>& worlds) const;

    // ---- Screen back to world: what a manipulator drag actually asks ----

    struct Ray {
        Vec3 origin;
        Vec3 direction; // unit length
    };

    // The world ray through a pixel. Every gizmo drag is a question about
    // WORLD space asked with a SCREEN position, so every one starts here.
    // The alternative -- project the screen delta onto the handle's screen
    // direction and divide by pixels-per-unit measured at the pivot -- is
    // only right when the projection is affine; under perspective that
    // ratio changes along the axis and with depth, and the Swift source's
    // harness measured the handle sliding up to 313 px out from under the
    // pointer because of it.
    Ray rayThrough(const Vec2& screen) const;

    // Where the ray through a pixel meets an arbitrary plane. nullopt when
    // it runs parallel to it, or meets it behind the eye. This is what a
    // PLANE handle is, and what a rotation ring is read in.
    std::optional<Vec3> hitPlane(const Vec2& screen, const Vec3& point, const Vec3& normal) const;

    // How far along `direction` from `point` the closest approach to the
    // ray through a pixel lies -- the classic closest approach of two skew
    // lines, and what makes an AXIS handle track the pointer at any angle
    // and depth: a world distance along the axis, not a screen distance
    // rescaled by a number measured somewhere else. nullopt when the ray
    // and the axis are parallel on screen, which is the axis seen end-on --
    // the one case with no honest answer, and where the gizmo already
    // refuses the drag.
    std::optional<float> axisParameter(const Vec2& screen, const Vec3& point, const Vec3& direction) const;

    // Pixels back to the world point on the plane `z = planeZ`. Has to be
    // the exact inverse of `project`, or the cursor and the card it is
    // holding drift apart -- by more the further away the card is, so it
    // presents as a different bug at every depth.
    std::optional<Vec2> unprojectOntoPlaneZ(const Vec2& screen, float planeZ) const;

    // How close to the plane through the eye a corner may come before its
    // divide stops meaning anything.
    static constexpr float kWEpsilon = 1e-4f;
};

} // namespace umeshcore
