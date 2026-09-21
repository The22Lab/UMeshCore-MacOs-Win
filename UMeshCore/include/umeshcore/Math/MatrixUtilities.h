#pragma once

// 1:1 port of `UltraMesh 2d animation/Core/MatrixUtilities.swift`.
//
// This is the single source of truth for the app's affine sprite
// convention (rotation + non-orthogonal shear + scale, angles in degrees
// for the `sheared*` family) as well as the bone TRS matrix builders
// (angles in radians) used by `Transform3D2D`. Every formula here must stay
// byte-for-byte identical to the Swift source — do not "simplify" the
// trigonometry, since callers (hit-testing, skinning, gizmo placement) are
// tuned against these exact expressions.

#include <cmath>
#include <optional>

#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

constexpr float kPi = 3.14159265358979323846f;

namespace MatrixUtilities {

inline Mat4 identity() { return Mat4::identity(); }

inline Mat4 translation(const Vec3& t) {
    Mat4 m = identity();
    m.columns[3] = Vec4(t.x, t.y, t.z, 1.0f);
    return m;
}

inline Mat4 scale(const Vec3& s) {
    Mat4 m = identity();
    m.columns[0].x = s.x;
    m.columns[1].y = s.y;
    m.columns[2].z = s.z;
    return m;
}

inline Mat4 rotationX(float radians) {
    const float c = std::cos(radians);
    const float s = std::sin(radians);
    return Mat4(
        Vec4(1, 0, 0, 0),
        Vec4(0, c, s, 0),
        Vec4(0, -s, c, 0),
        Vec4(0, 0, 0, 1));
}

inline Mat4 rotationY(float radians) {
    const float c = std::cos(radians);
    const float s = std::sin(radians);
    return Mat4(
        Vec4(c, 0, -s, 0),
        Vec4(0, 1, 0, 0),
        Vec4(s, 0, c, 0),
        Vec4(0, 0, 0, 1));
}

inline Mat4 rotationZ(float radians) {
    const float c = std::cos(radians);
    const float s = std::sin(radians);
    return Mat4(
        Vec4(c, s, 0, 0),
        Vec4(-s, c, 0, 0),
        Vec4(0, 0, 1, 0),
        Vec4(0, 0, 0, 1));
}

inline Mat4 skew(const Vec2& skewAngles) {
    const float sx = std::tan(skewAngles.x);
    const float sy = std::tan(skewAngles.y);
    return Mat4(
        Vec4(1, sy, 0, 0),
        Vec4(sx, 1, 0, 0),
        Vec4(0, 0, 1, 0),
        Vec4(0, 0, 0, 1));
}

inline Mat4 perspective(float m34) {
    Mat4 m = identity();
    m.columns[2].w = m34;
    return m;
}

inline Vec3 transformPoint(const Vec3& point, const Mat4& matrix) {
    const Vec4 v(point.x, point.y, point.z, 1.0f);
    const Vec4 r = matrix * v;
    const float w = std::abs(r.w) < 0.0001f ? 1.0f : r.w;
    return Vec3(r.x / w, r.y / w, r.z / w);
}

struct Decomposed {
    float rotationRadians;
    Vec2 scale;
    Vec2 skewDegrees;
};

// Exact inverse of `shearedAxes`: recovers rotation / scale / skew from a
// pair of basis axes. `preservedSkewYDegrees` pins the skew.y component so
// the decomposition is unique and a rigid composition reproduces the
// sprite's authored values bit-for-bit. Returns nullopt for degenerate
// (zero-length) axes.
inline std::optional<Decomposed> decomposeTransform(
    const Vec2& xAxis, const Vec2& yAxis, float preservedSkewYDegrees) {
    const float xLength = length(xAxis);
    const float yLength = length(yAxis);
    if (!(xLength > 0.000001f) || !(yLength > 0.000001f)) {
        return std::nullopt;
    }
    const float xAngleDeg = std::atan2(xAxis.y, xAxis.x) * 180.0f / kPi;
    const float yAngleDeg = std::atan2(yAxis.y, yAxis.x) * 180.0f / kPi;
    const float rotationDeg = xAngleDeg - preservedSkewYDegrees;
    float skewX = yAngleDeg - 90.0f - rotationDeg;
    skewX = std::fmod(skewX, 360.0f);
    if (skewX > 180.0f) skewX -= 360.0f;
    if (skewX <= -180.0f) skewX += 360.0f;
    return Decomposed{
        rotationDeg * kPi / 180.0f,
        Vec2(xLength, yLength),
        Vec2(skewX, preservedSkewYDegrees)};
}

struct Axes {
    Vec2 x;
    Vec2 y;
};

// The two world-space basis axes produced by a rotation + shear + scale
// (rotation and shear in degrees). This is the single source of truth for
// the sprite affine convention: every forward transform, inverse transform,
// and decomposition derives from these axes so they can never drift apart.
inline Axes shearedAxes(float rotationDegrees, const Vec2& shear, const Vec2& scale) {
    const float xAxisAngle = (rotationDegrees + shear.y) * (kPi / 180.0f);
    const float yAxisAngle = (rotationDegrees + 90.0f + shear.x) * (kPi / 180.0f);
    const Vec2 xAxis = Vec2(std::cos(xAxisAngle), std::sin(xAxisAngle)) * scale.x;
    const Vec2 yAxis = Vec2(std::cos(yAxisAngle), std::sin(yAxisAngle)) * scale.y;
    return {xAxis, yAxis};
}

// 2D shear transform for local points (degrees).
inline Vec2 shearedWorldTransform(
    const Vec2& local, const Vec2& position, float rotation, const Vec2& shear,
    const Vec2& scale) {
    const Axes axes = shearedAxes(rotation, shear, scale);
    return position + axes.x * local.x + axes.y * local.y;
}

// Exact inverse of `shearedWorldTransform`: maps a world point back to the
// local space of a sprite pose. Returns {0,0} for degenerate (zero-area)
// transforms, mirroring the Swift hit-testing behavior.
inline Vec2 shearedWorldInverse(
    const Vec2& world, const Vec2& position, float rotation, const Vec2& shear,
    const Vec2& scale) {
    const Axes axes = shearedAxes(rotation, shear, scale);
    const Vec2 relative = world - position;
    const float determinant = axes.x.x * axes.y.y - axes.x.y * axes.y.x;
    if (!(std::abs(determinant) > 0.000001f)) {
        return Vec2::zero();
    }
    const float invDeterminant = 1.0f / determinant;
    return Vec2(
        (relative.x * axes.y.y - relative.y * axes.y.x) * invDeterminant,
        (axes.x.x * relative.y - axes.x.y * relative.x) * invDeterminant);
}

// `shearedWorldTransform` as a 4x4, for FOLDING rather than applying.
//
// Affine, not linear -- it sends (0,0) to `position` -- so the translation
// is a column of its own rather than something the basis images carry.
//
// SHEAR HERE IS AN ANGLE IN DEGREES, because `shearedAxes` adds it to an
// axis' direction. `SceneLayer.shear` is a raw SLOPE and goes through
// `SceneLayer.planePoint` instead (ported separately in the Scene module).
// Both fields are spelled `shear`, both are `Vec2`, and the two are not
// interchangeable: feeding one to the other's formula compiles, runs, and
// is invisible until something is actually sheared.
inline Mat4 shearedMatrix(
    const Vec2& position, float rotationDegrees, const Vec2& shear, const Vec2& scale) {
    const Axes axes = shearedAxes(rotationDegrees, shear, scale);
    Mat4 m = identity();
    m.columns[0] = Vec4(axes.x.x, axes.x.y, 0, 0);
    m.columns[1] = Vec4(axes.y.x, axes.y.y, 0, 0);
    m.columns[3] = Vec4(position.x, position.y, 0, 1);
    return m;
}

// The inverse of `shearedMatrix`, or nullopt when the basis encloses no
// area.
//
// NULLOPT RATHER THAN A ZERO MATRIX. `shearedWorldInverse` answers a
// degenerate transform with {0,0}, which is the honest answer to a point
// query and the wrong one for a fold: a palette built on it skins the
// entire sprite onto the origin, which reads as the artwork collapsing
// rather than as a sprite that could not be inverted. A caller that gets
// nullopt drops the sprite.
inline std::optional<Mat4> shearedMatrixInverse(
    const Vec2& position, float rotationDegrees, const Vec2& shear, const Vec2& scale) {
    const Axes axes = shearedAxes(rotationDegrees, shear, scale);
    const float determinant = axes.x.x * axes.y.y - axes.x.y * axes.y.x;
    if (!(std::abs(determinant) > 0.000001f)) {
        return std::nullopt;
    }
    const float inv = 1.0f / determinant;
    const float m00 = axes.y.y * inv;
    const float m01 = -axes.y.x * inv;
    const float m10 = -axes.x.y * inv;
    const float m11 = axes.x.x * inv;
    Mat4 m = identity();
    m.columns[0] = Vec4(m00, m10, 0, 0);
    m.columns[1] = Vec4(m01, m11, 0, 0);
    m.columns[3] = Vec4(
        -(m00 * position.x + m01 * position.y), -(m10 * position.x + m11 * position.y), 0, 1);
    return m;
}

} // namespace MatrixUtilities
} // namespace umeshcore
