#pragma once

// 1:1 port of `Data/Constraint.swift`.
//
// Generic constraint contract. Every constraint type (IK, Transform, Path,
// Physics) implements this interface so the skeleton can apply them
// uniformly.
//
// Lifecycle:
//   1. Skeleton computes the unconstrained world matrix tree from local
//      transforms.
//   2. For each enabled constraint, sorted by `order` ascending, `apply`
//      mutates the world-matrices map. The constraint is responsible for
//      re-propagating its changes to any descendant bones (via
//      ConstraintPropagation::cascade).
//   3. Downstream consumers (renderer, mesh deformer) read the final world
//      matrices.
//
// Constraints MUST NOT mutate the skeleton's local bone transforms -- they
// operate only on world-space matrices for the current evaluation pass.

#include <string>
#include <unordered_map>

#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Math/Mat4.h"

namespace umeshcore {

class Skeleton; // fwd decl, defined in Model/Skeleton.h

using WorldMatrices = std::unordered_map<Uuid, Mat4, UuidHash>;

class BoneConstraint {
public:
    virtual ~BoneConstraint() = default;

    virtual Uuid id() const = 0;
    virtual const std::string& name() const = 0;
    virtual bool enabled() const = 0;
    // Lower order runs first. Allows chaining (e.g. an IK solving a hand,
    // then a rotation constraint snapping the wrist).
    virtual int order() const = 0;
    // Blend strength 0..1 between unconstrained pose and the constraint's
    // full effect.
    virtual float mix() const = 0;

    virtual void apply(const Skeleton& skeleton, WorldMatrices& worldMatrices) const = 0;
};

} // namespace umeshcore
