#include "umeshcore/Constraints/ConstraintPropagation.h"

#include "umeshcore/Model/Skeleton.h"

namespace umeshcore::ConstraintPropagation {

namespace {

void recompose(
    Uuid childID, const Mat4& parentWorld, const Skeleton& skeleton,
    const std::unordered_map<Uuid, std::vector<Uuid>, UuidHash>& childrenByParent,
    WorldMatrices& worldMatrices) {
    const Bone* bone = skeleton.bone(childID);
    if (bone == nullptr) return;
    const Mat4 newWorld = parentWorld * bone->localTransform.matrix();
    worldMatrices[childID] = newWorld;
    auto it = childrenByParent.find(childID);
    if (it == childrenByParent.end()) return;
    for (Uuid grandchildID : it->second) {
        recompose(grandchildID, newWorld, skeleton, childrenByParent, worldMatrices);
    }
}

} // namespace

void cascade(
    Uuid boneID, std::optional<Uuid> skipID, const Skeleton& skeleton, WorldMatrices& worldMatrices) {
    cascade(boneID, skipID, skeleton, skeleton.childrenIndexForPropagation(), worldMatrices);
}

void cascade(
    Uuid boneID, std::optional<Uuid> skipID, const Skeleton& skeleton,
    const std::unordered_map<Uuid, std::vector<Uuid>, UuidHash>& childrenByParent,
    WorldMatrices& worldMatrices) {
    auto parentIt = worldMatrices.find(boneID);
    if (parentIt == worldMatrices.end()) return;
    auto childrenIt = childrenByParent.find(boneID);
    if (childrenIt == childrenByParent.end()) return;
    for (Uuid childID : childrenIt->second) {
        if (skipID.has_value() && childID == *skipID) continue;
        recompose(childID, parentIt->second, skeleton, childrenByParent, worldMatrices);
    }
}

} // namespace umeshcore::ConstraintPropagation
