#pragma once

// 1:1 port of `Render/SceneCulling.swift` -- the camera frustum as six
// world-space planes, plus the integer frame rectangle a culled draw is
// confined to.
//
// Two things in the Swift header are load-bearing and are kept verbatim
// in behavior here:
//
//   1. The planes are EXTRACTED from the combined view-projection matrix
//      (Gribb & Hartmann), never rebuilt from the camera's field of view,
//      aspect and near/far. That is the whole reason a culler can be
//      trusted: the planes come from the same matrix the drawing divides
//      by, so they cannot drift from it. The rebuilt-from-camera version
//      reads more clearly and agrees with the projection only until
//      somebody changes one of the two; the symptom when they drift is an
//      object popping out at the edge of the screen while still visibly
//      on it.
//
//   2. The error is allowed in ONE direction. `culls` may KEEP something
//      that turns out to be invisible -- wasted work, measured at 1.3% of
//      cases over 20 000 random cameras by the Swift harness -- and may
//      NEVER discard something visible, which is an object vanishing.
//      Hence the conservative test: a hull is culled only when it lies
//      entirely outside ONE plane. A hull straddling two planes is kept
//      even when it is in fact outside the frustum, because deciding
//      otherwise needs a separating-axis test and the cost of being wrong
//      is not symmetric.
//
// Clip-space convention: z runs 0..w (Metal/Direct3D), which is what
// `SceneProjection`'s perspective matrix writes. So the NEAR plane is row
// 2 alone, not `w + z` as the OpenGL -w..w convention would have it --
// using the OpenGL form puts the near plane half a frustum too far back.
//
// Note on the far plane: it is honoured here AND by
// `SceneProjection::clipAndProject`, which grew a far cut for exactly this
// reason. Before that, the frustum's far plane discarded cards the
// renderer would have drawn (`farZ` went into the projection matrix and
// nothing ever read it back); the Swift harness measured 51 such layers
// out of 20 000, every one of them putting pixels on the canvas. A culler
// whose planes the renderer does not honour is not a culler, it is a way
// to lose objects.
//
// NOT ported: nothing. `SceneCulling.swift` is pure geometry -- it names
// no Scene-compositing type -- so it comes across whole.
//
// Caveat carried from CLAUDE.md: `Editor/verify_scene_culling.py`, which
// the Swift header cites for the 1.3% and 51-layer figures, does not
// exist in this repository. Those numbers are the best evidence that this
// math was validated, but they cannot be re-run from here.

#include <vector>

#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

class SceneFrustum {
public:
    // Index into `planes` means the same plane wherever it is read.
    enum PlaneIndex : int { kLeft = 0, kRight, kBottom, kTop, kNear, kFar, kPlaneCount };

    // Inward-facing and normalised: a point is inside a plane when
    // `dot(plane.xyz, point) + plane.w >= 0`.
    Vec4 planes[kPlaneCount];

    SceneFrustum() = default;

    // The six planes of a world-to-clip matrix. Pass
    // `SceneProjection::viewProjection()` -- the same matrix the drawing
    // divides by, which is the point.
    explicit SceneFrustum(const Mat4& viewProjection);

    static float distance(const Vec4& plane, const Vec3& point);

    // True when the whole hull lies outside one plane, so the layer can be
    // skipped. An empty hull culls (there is nothing to draw).
    //
    // `margin` pushes every plane outward. It is not a fudge for an
    // approximate bound -- the bounds handed here are exact -- it is there
    // so a caller with a genuinely uncertain hull can say by how much, in
    // world units, rather than by inventing a scale factor.
    bool culls(const std::vector<Vec3>& hull, float margin = 0.0f) const;
};

// A whole-pixel rectangle of the frame, y DOWN -- the projection's
// convention, so no flip lives in here.
//
// Integer because it addresses a bitmap. Rounded OUTWARD, never to
// nearest: a rectangle rounded inward loses the anti-aliased edge of
// whatever it bounds, and half a pixel of a sprite's outline going missing
// reads as the artwork being wrong rather than as a rounding rule.
struct FrameRegion {
    int minX = 0;
    int minY = 0;
    int maxX = 0;
    int maxY = 0;

    constexpr FrameRegion() = default;
    constexpr FrameRegion(int minX_, int minY_, int maxX_, int maxY_)
        : minX(minX_), minY(minY_), maxX(maxX_), maxY(maxY_) {}

    constexpr int width() const { return maxX - minX; }
    constexpr int height() const { return maxY - minY; }
    constexpr bool isEmpty() const { return width() <= 0 || height() <= 0; }

    constexpr bool operator==(const FrameRegion& o) const {
        return minX == o.minX && minY == o.minY && maxX == o.maxX && maxY == o.maxY;
    }
    constexpr bool operator!=(const FrameRegion& o) const { return !(*this == o); }

    // The outward-rounded box of some screen points, clipped to a frame.
    //
    // `pad` covers what RESAMPLING spills past the geometry -- a
    // perspective transform reads its source through a reconstruction
    // kernel, so the output reaches a little beyond the quad its corners
    // describe. It does NOT stand in for uncertainty about where the
    // geometry is: the hulls this is given are exact, and a pad covering
    // for a doubtful bound would be the arbitrary number this whole
    // exercise is meant to avoid.
    //
    // A non-finite coordinate falls back to the WHOLE frame rather than to
    // nothing: NaN reaching here means a degenerate projection, and
    // redrawing the frame is the conservative answer, consistent with the
    // culler's one-directional error rule.
    static FrameRegion bounding(
        const std::vector<Vec2>& points, float pad, int frameWidth, int frameHeight);

    static constexpr FrameRegion whole(int width, int height) {
        return FrameRegion(0, 0, width, height);
    }
};

} // namespace umeshcore
