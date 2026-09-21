#pragma once

// 1:1 port of `Data/PathSolver.swift`.

#include "umeshcore/Constraints/Constraint.h"
#include "umeshcore/Constraints/PathConstraint.h"

namespace umeshcore {

class Skeleton;

namespace PathSolver {

void solve(const PathConstraint& constraint, const Skeleton& skeleton, WorldMatrices& worldMatrices);

} // namespace PathSolver
} // namespace umeshcore
