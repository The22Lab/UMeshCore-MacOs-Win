#include "umeshcore/Animation/SceneAnimator.h"

namespace umeshcore {

std::unordered_map<Uuid, Bone, UuidHash> clipSampledBones(
    const std::unordered_map<Uuid, Bone, UuidHash>& bones, float time) {
    std::unordered_map<Uuid, Bone, UuidHash> updated = bones;
    for (const auto& entry : bones) {
        const Uuid boneID = entry.first;
        Bone bone = entry.second;
        const SceneImageAnimationPose basePose{
            Vec2(bone.baseTransform.position.x, bone.baseTransform.position.y),
            Vec2(bone.baseTransform.scale.x, bone.baseTransform.scale.y),
            bone.baseTransform.rotation.z,
            bone.baseTransform.skew,
        };
        const SceneImageAnimationPose pose =
            bone.animationClip.poseAtTime(boneID, basePose, time, /*cyclicRotation=*/true);
        bone.localTransform.position.x = pose.position.x;
        bone.localTransform.position.y = pose.position.y;
        bone.localTransform.scale.x = pose.scale.x;
        bone.localTransform.scale.y = pose.scale.y;
        bone.localTransform.rotation.z = pose.rotation;
        bone.localTransform.skew = pose.skew;
        updated[boneID] = std::move(bone);
    }
    return updated;
}

} // namespace umeshcore
