#include "umeshcore/Render/SceneCulling.h"

#include <algorithm>
#include <cmath>

namespace umeshcore {

namespace {

// Scaled so `w` is a real distance. Only needed so a margin can be
// expressed in world units; the sign test works either way. A degenerate
// plane (zero normal, from a singular matrix) is left alone rather than
// divided by ~0 -- a NaN plane would cull everything, which is the one
// direction this file may not fail in.
Vec4 normalised(const Vec4& plane) {
    const float len = length(plane.xyz());
    return len > 1e-12f ? Vec4(plane.x / len, plane.y / len, plane.z / len, plane.w / len) : plane;
}

// Clip-space clamp, then convert. See FrameRegion::bounding's DIVERGENCE
// note: converting first (as Swift does) traps or is undefined for a
// coordinate outside `int`, and every in-range value is unaffected.
int toFrameCoordinate(float value, int limit) {
    const float clamped = std::min(std::max(value, 0.0f), static_cast<float>(limit));
    return static_cast<int>(clamped);
}

} // namespace

SceneFrustum::SceneFrustum(const Mat4& viewProjection) {
    // Columns are the stored vectors, so a ROW has to be gathered ACROSS
    // them. Reading `columns[0]` as if it were a row is the classic way to
    // get a transposed frustum that culls everything in front of you.
    const Mat4& m = viewProjection;
    const auto row = [&m](int r) {
        return Vec4(m.columns[0][r], m.columns[1][r], m.columns[2][r], m.columns[3][r]);
    };
    const Vec4 r0 = row(0), r1 = row(1), r2 = row(2), r3 = row(3);

    // Clip z runs 0...w here, not -w...w: this is the Metal/Direct3D
    // convention, which `SceneProjection`'s perspective matrix writes out
    // explicitly (`clip.z = far * (z - near) / (far - near)`, zero on the
    // near plane). So NEAR is row 2 ALONE, not `w + z` -- the OpenGL form
    // would put the near plane half a frustum too far back.
    planes.reserve(Count);
    planes.push_back(normalised(r3 + r0)); // Left
    planes.push_back(normalised(r3 - r0)); // Right
    planes.push_back(normalised(r3 + r1)); // Bottom
    planes.push_back(normalised(r3 - r1)); // Top
    planes.push_back(normalised(r2));      // Near
    planes.push_back(normalised(r3 - r2)); // Far
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
        // Entirely outside THIS plane is the only proof of invisibility
        // this test accepts. A hull outside two planes but inside each of
        // them separately is kept -- see the header.
        if (!anyInside) return true;
    }
    return false;
}

FrameRegion FrameRegion::bounding(
    const std::vector<Vec2>& points, float pad, int frameWidth, int frameHeight) {
    if (points.empty()) return FrameRegion(0, 0, 0, 0);

    // The finiteness test runs over every point BEFORE the reduction, and
    // `pad` with them, because it is added to every edge. See the header's
    // second DIVERGENCE note: reducing first would let a NaN coordinate be
    // swallowed by fmin/fmax and silently drop that corner from the box.
    if (!std::isfinite(pad)) return FrameRegion(0, 0, frameWidth, frameHeight);
    for (const Vec2& point : points) {
        if (!std::isfinite(point.x) || !std::isfinite(point.y)) {
            return FrameRegion(0, 0, frameWidth, frameHeight);
        }
    }

    Vec2 lo = points.front();
    Vec2 hi = points.front();
    for (std::size_t i = 1; i < points.size(); ++i) {
        lo = Vec2(std::min(lo.x, points[i].x), std::min(lo.y, points[i].y));
        hi = Vec2(std::max(hi.x, points[i].x), std::max(hi.y, points[i].y));
    }

    return FrameRegion(
        toFrameCoordinate(std::floor(lo.x - pad), frameWidth),
        toFrameCoordinate(std::floor(lo.y - pad), frameHeight),
        toFrameCoordinate(std::ceil(hi.x + pad), frameWidth),
        toFrameCoordinate(std::ceil(hi.y + pad), frameHeight));
}

} // namespace umeshcore
