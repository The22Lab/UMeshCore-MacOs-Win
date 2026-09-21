#pragma once

// 1:1 port of `ConstraintPropagation` from `Data/Constraint.swift`.
//
// Utility used by every constraint type to recompute world matrices for the
// descendants of an affected bone after the constraint has rewritten the
// bone's world matrix. Keeping this in one place guarantees every
// constraint type propagates changes the same way.

#include <optional>
#include <unordered_map>
#include <vector>

#include "umeshcore/Constraints/Constraint.h"
#include "umeshcore/Core/Uuid.h"

namespace umeshcore {

class Skeleton;

namespace ConstraintPropagation {

// Recompute world matrices for every descendant of `boneID` using each
// bone's existing local transform composed against the new parent world
// matrix.
// `skipID`: a child subtree to leave alone. A solver that has just written
// a world matrix for one of `boneID`'s children must skip it here, or this
// recomposes that child from its LOCAL transform and throws the solved
// result away -- exactly how two-bone IK once produced a straight limb
// with no joint bend.
void cascade(
    Uuid boneID, std::optional<Uuid> skipID, const Skeleton& skeleton, WorldMatrices& worldMatrices);

// Cascade against a children index the caller already built. A solver
// running several cascades in a row should build one and reuse it.
void cascade(
    Uuid boneID, std::optional<Uuid> skipID, const Skeleton& skeleton,
    const std::unordered_map<Uuid, std::vector<Uuid>, UuidHash>& childrenByParent,
    WorldMatrices& worldMatrices);

} // namespace ConstraintPropagation
} // namespace umeshcore
