#pragma once

// 1:1 port of `Data/IKSolver.swift`.

#include "umeshcore/Constraints/Constraint.h"
#include "umeshcore/Constraints/IKConstraint.h"

namespace umeshcore {

class Skeleton;

namespace IKSolver {

void solve(const IKConstraint& constraint, const Skeleton& skeleton, WorldMatrices& worldMatrices);

} // namespace IKSolver
} // namespace umeshcore
