#pragma once

// 1:1 port of `Render/SceneCulling.swift` -- the frustum a frame decides
// with, and the whole-pixel region a layer is allowed to touch.
//
// Two things in this file are load-bearing and easy to "clean up" into
// bugs, so they are stated here as well as at their call sites.
//
// ## The planes come OUT OF the matrix, they are not rebuilt
//
// `SceneFrustum` is constructed from a view-projection matrix and pulls
// its six planes out of it (Gribb & Hartmann). That is the entire reason
// it can be trusted: the planes come from THE SAME matrix the drawing
// divides by -- `SceneProjection::viewProjection()`. Rebuilding them from
// the camera's field of view, aspect and near/far reads more clearly and
// is what the Swift header warns against: it gives a frustum that agrees
// with the projection only until somebody changes one of them, and the
// symptom when they drift is an object popping out at the edge of the
// screen while still visibly on it.
//
// That warning is sharper here than it was in Swift. This port exists so
// a Metal backend and a DirectX backend share one implementation; two
// backends each re-deriving a frustum from camera parameters is precisely
// the three-copies-of-world-to-screen failure `SceneProjection`'s header
// records (they had already diverged).
//
// ## A culler's error is allowed in ONE direction
//
// It may KEEP something that is not in fact visible -- wasted work, which
// the Swift harness measured at 1.3 % of 20 000 random cameras. It may
// never DISCARD something visible: that is an object vanishing, the bug
// the file exists because of.
//
// So `culls` is the conservative test: a hull is culled only when it lies
// entirely outside ONE plane. A hull straddling two planes is kept even
// when it really is outside the frustum, because deciding otherwise needs
// a separating-axis test and the cost of being wrong is not symmetric.
// `SceneCullingTests` asserts both halves: nothing `SceneProjection`
// projects into the viewport is ever culled, and the documented
// straddling case is kept.
//
// ## Near and far
//
// Both planes are extracted and both are honoured, because
// `SceneProjection::clipAndProject` cuts against both. In Swift the far
// plane predates that cut and for a while discarded cards the renderer
// would have drawn (51 layers out of 20 000, every one of them putting
// pixels on the canvas). A culler whose planes the renderer does not
// honour is not a culler; it is a way to lose objects. The C++ port has
// the far cut from the start, so the two agree by construction -- but the
// pairing is a requirement, not a coincidence, and breaking either side
// of it breaks the other.
//
// The Swift file cites `Editor/verify_scene_culling.py` for those
// measurements. That harness does NOT exist in this repository (see
// CLAUDE.md): the numbers are quoted as the record of a validation that
// was done, not one that can be re-run from here.

#include <vector>

#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

// The camera's frustum, as six planes in world space.
struct SceneFrustum {
    // Index into `planes`. Fixed order, so an index means the same plane
    // wherever it is read.
    enum Plane : int { Left = 0, Right = 1, Bottom = 2, Top = 3, Near = 4, Far = 5, Count = 6 };

    // Inward-facing and normalised: a point is inside a plane when
    // `dot(plane.xyz(), point) + plane.w >= 0`. Always `Count` entries.
    std::vector<Vec4> planes;

    // Takes the combined view-projection matrix -- i.e.
    // `projection.viewProjection()`, never a matrix assembled a second
    // time from the same camera parameters.
    explicit SceneFrustum(const Mat4& viewProjection);

    // Signed distance, in world units, thanks to the normalisation.
    static float distance(const Vec4& plane, const Vec3& point);

    // True when the whole hull is outside one plane and the layer can be
    // skipped. An empty hull is culled -- there is nothing to draw.
    //
    // `margin` pushes every plane outward. It is not a fudge factor for an
    // approximate bound (the bounds handed here are exact); it is there so
    // a caller with a genuinely uncertain hull can say by how much, in
    // world units, instead of inventing a scale factor.
    bool culls(const std::vector<Vec3>& hull, float margin = 0.0f) const;
};

// A whole-pixel rectangle of the frame, y DOWN -- `SceneProjection`'s
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
    // geometry is: the hulls this is given are exact, and a pad covering a
    // doubtful bound would be the arbitrary number this whole exercise
    // avoids.
    //
    // No points at all gives an empty region; a non-finite coordinate (or
    // pad) gives the WHOLE frame -- not knowing where something is means
    // drawing all of it, never skipping it, which is the same asymmetry
    // `SceneFrustum::culls` is written around.
    //
    // DIVERGENCE (documented, deliberate): "non-finite" is tested on
    // every point, not on the reduced box. Swift reduces first with
    // `simd_min`/`simd_max`, which are fmin/fmax-based and return the
    // OTHER operand for a NaN -- so a NaN corner sitting among finite ones
    // is quietly dropped there, and only an all-NaN set (or an infinity,
    // which does propagate) ever reaches the guard. Dropping a corner
    // shrinks the region, and a region too small clips pixels off a layer
    // that is on screen: the one direction this file may not fail in. The
    // guard's evident intent is the whole frame, so that is what a NaN
    // gets here too. `testNoPointsIsEmptyButNonFiniteIsTheWholeFrame`
    // pins it.
    //
    // DIVERGENCE (documented, behaviour-preserving): the clamp to the
    // frame happens in float, before the conversion to int, where Swift
    // converts first and clamps after. Swift's order traps on a coordinate
    // too large for `Int`; in C++ the same conversion is undefined. Every
    // in-range value gives the identical region, and the out-of-range ones
    // are empty or whole-frame either way -- only the arithmetic that
    // reaches the answer is safe here.
    static FrameRegion bounding(
        const std::vector<Vec2>& points, float pad, int frameWidth, int frameHeight);

    static constexpr FrameRegion whole(int width, int height) {
        return FrameRegion(0, 0, width, height);
    }
};

} // namespace umeshcore
