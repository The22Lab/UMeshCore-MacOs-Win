#pragma once

// 1:1 port of `Data/IKConstraint.swift`.

#include <string>
#include <vector>

#include "umeshcore/Constraints/Constraint.h"
#include "umeshcore/Core/Uuid.h"

namespace umeshcore {

class IKConstraint : public BoneConstraint {
public:
    Uuid id_ = Uuid::generate();
    std::string name_;
    bool enabled_ = true;
    int order_ = 0;
    float mix_ = 1.0f;

    // Bones from root to effector. The effector tip is what we try to put
    // on the target. Must contain at least 1 bone.
    std::vector<Uuid> boneChain;
    // The bone whose WORLD TIP position defines where the IK should reach.
    Uuid targetBoneID;
    // Sign of the elbow bend for 2-bone IK; a preferred-side hint for FABRIK.
    bool bendPositive = true;
    bool stretch = false;
    bool compress = false;
    bool uniformScale = false;
    // Soft-IK damping window in world units.
    float softness = 0.0f;

    IKConstraint() = default;
    IKConstraint(std::string name, std::vector<Uuid> boneChain_, Uuid targetBoneID_)
        : name_(std::move(name)), boneChain(std::move(boneChain_)), targetBoneID(targetBoneID_) {}

    Uuid id() const override { return id_; }
    const std::string& name() const override { return name_; }
    bool enabled() const override { return enabled_; }
    int order() const override { return order_; }
    float mix() const override { return mix_; }

    void apply(const Skeleton& skeleton, WorldMatrices& worldMatrices) const override;
};

} // namespace umeshcore
