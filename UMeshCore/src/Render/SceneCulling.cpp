#include "umeshcore/Render/SceneCulling.h"

#include <algorithm>
#include <cmath>

namespace umeshcore {

namespace {

// A ROW of a column-major matrix has to be gathered across the columns.
// Reading `columns[r]` as a row is the classic way to get a frustum that
// is transposed and culls everything behind you.
Vec4 row(const Mat4& m, int r) {
    return Vec4(m.columns[0][r], m.columns[1][r], m.columns[2][r], m.columns[3][r]);
}

// Scaled so `w` is a real distance. Only needed so a margin can be
// expressed in world units; the sign test works either way.
Vec4 normalised(const Vec4& plane) {
    const float len = length(plane.xyz());
    return len > 1e-12f ? plane * (1.0f / len) : plane;
}

// Swift's `Int(x.rounded(.down))` traps on a value outside Int's range;
// here the caller clamps into the frame anyway, so saturate rather than
// invoke undefined behavior on the cast.
int saturatingInt(float value) {
    const double v = static_cast<double>(value);
    constexpr double lo = -1e9;
    constexpr double hi = 1e9;
    return static_cast<int>(std::min(std::max(v, lo), hi));
}

} // namespace

SceneFrustum::SceneFrustum(const Mat4& viewProjection) {
    const Vec4 r0 = row(viewProjection, 0);
    const Vec4 r1 = row(viewProjection, 1);
    const Vec4 r2 = row(viewProjection, 2);
    const Vec4 r3 = row(viewProjection, 3);
    // left, right, bottom, top, near, far -- near is row 2 alone because
    // clip z runs 0..w here (see the header).
    planes[kLeft] = normalised(r3 + r0);
    planes[kRight] = normalised(r3 - r0);
    planes[kBottom] = normalised(r3 + r1);
    planes[kTop] = normalised(r3 - r1);
    planes[kNear] = normalised(r2);
    planes[kFar] = normalised(r3 - r2);
}

float SceneFrustum::distance(const Vec4& plane, const Vec3& point) {
    return dot(plane.xyz(), point) + plane.w;
}

bool SceneFrustum::culls(const std::vector<Vec3>& hull, float margin) const {
    if (hull.empty()) return true;
    for (const Vec4& plane : planes) {
        bool anyInside = false;
        for (const Vec3& point : hull) {
            if (distance(plane, point) >= -margin) {
                anyInside = true;
                break;
            }
        }
        if (!anyInside) return true; // wholly outside THIS plane: safe to skip.
    }
    return false;
}

FrameRegion FrameRegion::bounding(
    const std::vector<Vec2>& points, float pad, int frameWidth, int frameHeight) {
    if (points.empty()) return FrameRegion(0, 0, 0, 0);
    // The non-finite test runs over every point BEFORE the reduction, and
    // over `pad` with them. Testing the reduced box instead is
    // order-dependent and fails in the direction this file may not fail
    // in: `std::min(finite, NaN)` returns the finite operand, so a NaN
    // point anywhere but FIRST is swallowed by the reduction and the
    // guard never sees it. Measured on the reduce-first form: the points
    // {(10,10), (NaN,20)} gave (10,10)-(10,20) -- an EMPTY region, i.e.
    // the layer skipped entirely -- while the same two points in the
    // other order gave the whole frame. And a non-finite `pad`, which
    // lands on all four edges, reached the cast and came back INT_MIN.
    // One answer for all of them: an unknown means redraw everything.
    if (!std::isfinite(pad)) return FrameRegion::whole(frameWidth, frameHeight);
    for (const Vec2& point : points) {
        if (!std::isfinite(point.x) || !std::isfinite(point.y)) {
            return FrameRegion::whole(frameWidth, frameHeight);
        }
    }
    Vec2 lo = points.front();
    Vec2 hi = points.front();
    for (std::size_t i = 1; i < points.size(); ++i) {
        lo = Vec2(std::min(lo.x, points[i].x), std::min(lo.y, points[i].y));
        hi = Vec2(std::max(hi.x, points[i].x), std::max(hi.y, points[i].y));
    }
    return FrameRegion(
        std::max(saturatingInt(std::floor(lo.x - pad)), 0),
        std::max(saturatingInt(std::floor(lo.y - pad)), 0),
        std::min(saturatingInt(std::ceil(hi.x + pad)), frameWidth),
        std::min(saturatingInt(std::ceil(hi.y + pad)), frameHeight));
}

} // namespace umeshcore
