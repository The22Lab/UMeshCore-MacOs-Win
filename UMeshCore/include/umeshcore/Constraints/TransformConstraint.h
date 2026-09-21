#pragma once

// 1:1 port of `Data/TransformConstraint.swift`.

#include <string>
#include <vector>

#include "umeshcore/Constraints/Constraint.h"
#include "umeshcore/Core/Uuid.h"

namespace umeshcore {

class TransformConstraint : public BoneConstraint {
public:
    Uuid id_ = Uuid::generate();
    std::string name_;
    bool enabled_ = true;
    // Default 50 so Transform Constraints evaluate after IK/Path (order
    // 0..49 by convention) and before Physics (order >= 100).
    int order_ = 50;
    float mix_ = 1.0f;

    // Source bone. Its current world matrix supplies the values to copy.
    Uuid targetBoneID;
    // Bones receiving the copied transform components.
    std::vector<Uuid> affectedBones;

    bool copyPosition = false;
    bool copyRotation = true;
    bool copyScale = false;
    bool copyShear = false;

    // Per-channel blend strength (0..1). Effective amount = mix * channelMix.
    float positionMix = 1.0f;
    float rotationMix = 1.0f;
    float scaleMix = 1.0f;
    float shearMix = 1.0f;

    // Offsets added to the target's value before blending.
    float offsetPositionX = 0.0f;
    float offsetPositionY = 0.0f;
    float offsetRotation = 0.0f; // radians
    float offsetScaleX = 0.0f;
    float offsetScaleY = 0.0f;
    float offsetShear = 0.0f; // radians

    TransformConstraint() = default;
    TransformConstraint(std::string name, Uuid targetBoneID_, std::vector<Uuid> affectedBones_)
        : name_(std::move(name)), targetBoneID(targetBoneID_), affectedBones(std::move(affectedBones_)) {}

    Uuid id() const override { return id_; }
    const std::string& name() const override { return name_; }
    bool enabled() const override { return enabled_; }
    int order() const override { return order_; }
    float mix() const override { return mix_; }

    void apply(const Skeleton& skeleton, WorldMatrices& worldMatrices) const override;
};

} // namespace umeshcore
