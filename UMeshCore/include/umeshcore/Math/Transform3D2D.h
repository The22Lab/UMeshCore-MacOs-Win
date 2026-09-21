#pragma once

// 1:1 port of `UltraMesh 2d animation/Core/Transform3D2D.swift`.
//
// The bone TRS transform: position/rotation/scale are SIMD3 (rotation in
// radians, Euler ZYX composed as Rz*Ry*Rx), skew is a SIMD2 tangent-shear
// applied between rotation and scale. Note this is a DIFFERENT convention
// from `MatrixUtilities::shearedAxes` (which is degrees and used for
// sprite/mesh-bind poses) -- bones use this struct, sprites use
// shearedAxes. Do not conflate the two.

#include "umeshcore/Math/Mat4.h"
#include "umeshcore/Math/MatrixUtilities.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

struct Transform3D2D {
    Vec3 position = Vec3::zero();
    Vec3 rotation = Vec3::zero();
    Vec3 scale = Vec3::one();
    Vec2 skew = Vec2::zero();

    constexpr Transform3D2D() = default;
    constexpr Transform3D2D(const Vec3& position_, const Vec3& rotation_, const Vec3& scale_,
                             const Vec2& skew_)
        : position(position_), rotation(rotation_), scale(scale_), skew(skew_) {}

    Mat4 matrix() const {
        const Mat4 t = MatrixUtilities::translation(position);
        const Mat4 rz = MatrixUtilities::rotationZ(rotation.z);
        const Mat4 ry = MatrixUtilities::rotationY(rotation.y);
        const Mat4 rx = MatrixUtilities::rotationX(rotation.x);
        const Mat4 sk = MatrixUtilities::skew(skew);
        const Mat4 sc = MatrixUtilities::scale(scale);
        return t * rz * ry * rx * sk * sc;
    }

    bool operator==(const Transform3D2D& o) const {
        return position == o.position && rotation == o.rotation && scale == o.scale &&
               skew == o.skew;
    }
};

} // namespace umeshcore
