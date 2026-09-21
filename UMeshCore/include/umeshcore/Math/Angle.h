#pragma once

// 1:1 port of `shortestAngleDelta` from `Data/Constraint.swift`. Lives in
// Math/ (rather than Constraints/) because it has no dependency on
// Skeleton/BoneConstraint and is used by both the constraint solvers and
// AnimationClip's cyclic-rotation blending -- putting it here lets
// Animation be built and tested before Constraints without a forward
// reference.

#include <cmath>

#include "umeshcore/Math/MatrixUtilities.h"

namespace umeshcore {

// Shortest signed angular delta from `from` to `to` in radians, in (-pi,
// pi]. Crucial for stable IK/animation blending: prevents long-way-around
// rotations when the target moves through the +-pi boundary.
inline float shortestAngleDelta(float from, float to) {
    float delta = std::fmod(to - from, 2.0f * kPi);
    if (delta > kPi) delta -= 2.0f * kPi;
    if (delta < -kPi) delta += 2.0f * kPi;
    return delta;
}

} // namespace umeshcore
