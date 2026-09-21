#pragma once

// 1:1 port of `Data/PathConstraint.swift`.

#include <string>
#include <vector>

#include "umeshcore/Constraints/Constraint.h"
#include "umeshcore/Core/Uuid.h"

namespace umeshcore {

enum class PathRotateMode { Tangent, Chain, ChainScale };
enum class PathSpacingMode { Length, Percent, Proportional, Fixed };

class PathConstraint : public BoneConstraint {
public:
    Uuid id_ = Uuid::generate();
    std::string name_;
    bool enabled_ = true;
    int order_ = 0;
    // Master blend -- multiplied into positionMix and rotateMix.
    float mix_ = 1.0f;

    // Bones whose world-root positions define the Catmull-Rom control
    // points. Minimum 2 required for a valid spline.
    std::vector<Uuid> pathBones;
    // Bones placed along the spline, ordered from path start toward end.
    std::vector<Uuid> bones;
    // Where the first bone is placed: 0 = path start, 1 = path end.
    float position = 0.0f;
    float spacing = 60.0f;
    PathSpacingMode spacingMode = PathSpacingMode::Length;
    float positionMix = 1.0f;
    float rotateMix = 1.0f;
    // Radians.
    float offsetRotation = 0.0f;
    bool closed = false;
    bool reversed = false;
    PathRotateMode rotateMode = PathRotateMode::Tangent;

    PathConstraint() = default;
    PathConstraint(std::string name, std::vector<Uuid> pathBones_, std::vector<Uuid> bones_)
        : name_(std::move(name)), pathBones(std::move(pathBones_)), bones(std::move(bones_)) {}

    Uuid id() const override { return id_; }
    const std::string& name() const override { return name_; }
    bool enabled() const override { return enabled_; }
    int order() const override { return order_; }
    float mix() const override { return mix_; }

    void apply(const Skeleton& skeleton, WorldMatrices& worldMatrices) const override;
};

} // namespace umeshcore
