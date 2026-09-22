#include "umeshcore/Scene/SceneLayer.h"

#include <algorithm>
#include <cmath>

namespace umeshcore {

namespace {

// Swift's `Int(x.rounded())` traps on a value outside Int's range, and the
// same conversion is undefined in C++. Saturating instead, the way
// `SceneCulling.cpp` already does for frame coordinates: a NaN speed out
// of a hand-edited file would otherwise reach the cast. The clamp that
// follows in `rigFrame` puts any saturated value back inside the clip, so
// no in-range input is affected.
int saturatingInt(float value) {
    if (!std::isfinite(value)) return 0;
    const double v = static_cast<double>(value);
    return static_cast<int>(std::min(std::max(v, -1e9), 1e9));
}

} // namespace

Vec2 SceneLayer::planePoint(const Vec2& local) const {
    // THE ORDER IS THE DEFINITION: scale, then shear, then roll. Shear
    // after the scale means it is expressed in the card's scaled units --
    // the same order `SceneImage` applies skew in -- so a scaled card
    // slants by the amount the number says rather than by that amount
    // times its scale.
    const float sx = local.x * scale.x;
    const float sy = local.y * scale.y;
    const float hx = sx + sy * shear.x;
    const float hy = sy + sx * shear.y;
    const float c = std::cos(rotation);
    const float s = std::sin(rotation);
    return Vec2(hx * c - hy * s, hx * s + hy * c);
}

Vec3 SceneLayer::liftToWorld(const Vec2& planePoint) const {
    const float cp = std::cos(rotation3D.x);
    const float sp = std::sin(rotation3D.x);
    const float cy = std::cos(rotation3D.y);
    const float sy = std::sin(rotation3D.y);
    const float y1 = planePoint.y * cp;
    const float z1 = planePoint.y * sp;
    return Vec3(planePoint.x * cy + z1 * sy, y1, -planePoint.x * sy + z1 * cy);
}

SceneLayerOrientation SceneLayer::orientation() const {
    // Roll, then the tilt. Built by lifting two unit vectors of the card's
    // own plane rather than by differencing `planePoint`, because
    // `planePoint` carries the shear and a sheared frame is not a
    // rotation -- see the header.
    const float c = std::cos(rotation);
    const float s = std::sin(rotation);
    const Vec3 x = liftToWorld(Vec2(c, s));
    const Vec3 y = liftToWorld(Vec2(-s, c));
    return SceneLayerOrientation{x, y, cross(x, y)};
}

SceneLayer::Plane SceneLayer::lightingPlane() const {
    return Plane{worldOrigin(), orientation().z};
}

SceneLayer::Tangent SceneLayer::lightingTangent() const {
    const SceneLayerOrientation axes = orientation();
    // `sign` of zero is zero, and a frame multiplied by zero is not a
    // frame. A degenerate axis keeps the unmirrored reading, which is what
    // the card looked like before it was flattened.
    const float sx = scale.x < 0.0f ? -1.0f : 1.0f;
    const float sy = scale.y < 0.0f ? -1.0f : 1.0f;
    return Tangent{axes.x * sx, sx * sy};
}

std::optional<int> SceneLayer::rigFrame(int sceneFrame, int clipDuration) const {
    const SceneRigContent* rig = std::get_if<SceneRigContent>(&content);
    if (rig == nullptr) return std::nullopt;
    if (clipDuration <= 0) return rig->startFrame;

    const int advanced =
        rig->startFrame + saturatingInt(std::round(static_cast<float>(sceneFrame) * rig->speed));
    if (!rig->loops) return std::min(std::max(advanced, 0), clipDuration - 1);

    // C++ `%` truncates towards zero and keeps the sign of the dividend,
    // exactly as Swift's does, so a negative start frame or a negative
    // speed would index backwards off the clip without this.
    const int wrapped = advanced % clipDuration;
    return wrapped < 0 ? wrapped + clipDuration : wrapped;
}

} // namespace umeshcore
