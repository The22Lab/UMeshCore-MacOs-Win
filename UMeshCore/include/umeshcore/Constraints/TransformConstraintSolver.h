#pragma once

// 1:1 port of `TransformConstraintSolver` from `Data/TransformConstraint.swift`.

#include "umeshcore/Constraints/Constraint.h"
#include "umeshcore/Constraints/TransformConstraint.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

class Skeleton;

namespace TransformConstraintSolver {

// Decomposed 2D transform: T * Rz * Sk(skewX, skewY) * S(scaleX, scaleY).
// Matches Transform3D2D::matrix()'s composition order, so recomposing this
// reproduces the original matrix when skewY is zero (the usual convention).
struct Decomposed2D {
    Vec2 position;
    float rotation = 0.0f; // radians
    float scaleX = 1.0f;
    float scaleY = 1.0f;
    // Angular deviation of the Y-axis from perpendicular, radians.
    float skewX = 0.0f;
    // Only meaningful when explicitly composed; matrix decomposition cannot
    // separate it from `rotation` uniquely.
    float skewY = 0.0f;
};

Decomposed2D decompose(const Mat4& m);
Mat4 compose(const Decomposed2D& d);

void solve(const TransformConstraint& constraint, const Skeleton& skeleton, WorldMatrices& worldMatrices);

} // namespace TransformConstraintSolver
} // namespace umeshcore
