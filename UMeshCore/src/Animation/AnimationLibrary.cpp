#include "umeshcore/Animation/AnimationLibrary.h"

#include <algorithm>

#include "umeshcore/Editor/EditorScene.h"

namespace umeshcore {

const NamedAnimation* AnimationLibrary::active() const {
    if (!activeID_.has_value()) return nullptr;
    for (const NamedAnimation& animation : animations_) {
        if (animation.id == *activeID_) return &animation;
    }
    return nullptr;
}

void AnimationLibrary::restore(std::vector<NamedAnimation> animations, std::optional<Uuid> activeID) {
    animations_ = std::move(animations);
    // An id that names nothing would leave the panel pointing at an entry
    // that is not there.
    const bool known =
        activeID.has_value() && std::any_of(animations_.begin(), animations_.end(), [&](const NamedAnimation& a) {
            return a.id == *activeID;
        });
    activeID_ = known ? activeID : std::nullopt;
}

void AnimationLibrary::createFromCurrentState(const std::string& name) {
    NamedAnimation animation = snapshotCurrent(name);
    // Persist current edits into the previously active animation so they
    // aren't lost.
    if (activeID_.has_value()) {
        for (NamedAnimation& existing : animations_) {
            if (existing.id == *activeID_) {
                existing = snapshotCurrent(existing.name, existing.id);
                break;
            }
        }
    }
    activeID_ = animation.id;
    animations_.push_back(std::move(animation));
}

void AnimationLibrary::switchTo(Uuid id) {
    // Saves the outgoing animation even when the target is already active
    // -- see this file's header.
    if (activeID_.has_value()) {
        for (NamedAnimation& existing : animations_) {
            if (existing.id == *activeID_) {
                existing = snapshotCurrent(existing.name, existing.id);
                break;
            }
        }
    }
    if (activeID_.has_value() && *activeID_ == id) return;

    const NamedAnimation* target = nullptr;
    for (const NamedAnimation& animation : animations_) {
        if (animation.id == id) {
            target = &animation;
            break;
        }
    }
    if (target == nullptr) return;

    applyToScene(*target);
    activeID_ = id;
}

void AnimationLibrary::rename(Uuid id, const std::string& newName) {
    for (NamedAnimation& animation : animations_) {
        if (animation.id == id) {
            animation.name = newName;
            return;
        }
    }
}

void AnimationLibrary::remove(Uuid id) {
    animations_.erase(
        std::remove_if(
            animations_.begin(), animations_.end(), [&](const NamedAnimation& a) { return a.id == id; }),
        animations_.end());
    if (activeID_.has_value() && *activeID_ == id) {
        activeID_ = animations_.empty() ? std::nullopt : std::optional<Uuid>(animations_.front().id);
    }
    if (const NamedAnimation* next = active()) applyToScene(*next);
}

NamedAnimation AnimationLibrary::snapshotCurrent(const std::string& name, std::optional<Uuid> id) const {
    NamedAnimation animation;
    if (id.has_value()) animation.id = *id;
    animation.name = name;

    int duration = 0;
    for (const Bone& bone : scene_.skeleton.orderedBones()) {
        animation.boneClips[bone.id] = bone.animationClip;
        duration = std::max(duration, bone.animationClip.durationInFrames);
    }
    for (const SceneImage& image : scene_.images) {
        animation.imageClips[image.id] = image.animationClip;
        duration = std::max(duration, image.animationClip.durationInFrames);
    }
    animation.sceneClip = scene_.sceneAnimationClip;
    duration = std::max(duration, animation.sceneClip.durationInFrames);

    animation.constraintSetupValues = scene_.constraintSetupValues;
    animation.duration = duration;
    return animation;
}

void AnimationLibrary::applyToScene(const NamedAnimation& animation) {
    for (const Bone& bone : scene_.skeleton.orderedBones()) {
        const auto it = animation.boneClips.find(bone.id);
        Bone updated = bone;
        updated.animationClip = it != animation.boneClips.end() ? it->second : AnimationClip(animation.name);
        scene_.skeleton.setBone(updated);
    }
    for (SceneImage& image : scene_.images) {
        const auto it = animation.imageClips.find(image.id);
        image.animationClip = it != animation.imageClips.end() ? it->second : AnimationClip(animation.name);
    }

    // Restore the constraints to their authored values BEFORE installing
    // the incoming timelines, so a property animated by the outgoing
    // animation but untouched by the incoming one does not keep a stale
    // value (`SceneManager.restoreAllConstraintSetupValues`).
    for (const auto& [constraintID, values] : scene_.constraintSetupValues) {
        if (!constraintKind(scene_.skeleton, constraintID).has_value()) continue;
        applyConstraintSetupValues(scene_.skeleton, constraintID, values);
    }

    scene_.sceneAnimationClip = animation.sceneClip;
    scene_.constraintSetupValues = animation.constraintSetupValues;
    scene_.applyAnimationsNow();
}

} // namespace umeshcore
