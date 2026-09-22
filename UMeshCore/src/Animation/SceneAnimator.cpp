#include "umeshcore/Animation/SceneAnimator.h"

#include <algorithm>
#include <cmath>
#include <unordered_set>

#include "umeshcore/Math/MatrixUtilities.h"

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

Vec2 convertPosition(
    const Skeleton& skeleton, Vec2 position, std::optional<Uuid> sourceBoneID,
    std::optional<Uuid> targetBoneID) {
    Vec2 worldPosition = position;
    if (sourceBoneID.has_value()) {
        if (const auto worldMatrix = skeleton.worldMatrix(*sourceBoneID)) {
            const Vec3 worldPoint =
                MatrixUtilities::transformPoint(Vec3(position.x, position.y, 0), *worldMatrix);
            worldPosition = Vec2(worldPoint.x, worldPoint.y);
        }
    }
    return skeleton.localPoint(worldPosition, targetBoneID);
}

float convertRotation(
    const Skeleton& skeleton, float rotation, std::optional<Uuid> sourceBoneID,
    std::optional<Uuid> targetBoneID) {
    float worldRotation = rotation;
    if (sourceBoneID.has_value()) {
        if (const auto r = skeleton.worldRotation(*sourceBoneID)) worldRotation += *r;
    }
    if (targetBoneID.has_value()) {
        if (const auto r = skeleton.worldRotation(*targetBoneID)) worldRotation -= *r;
    }
    return worldRotation;
}

void convertImageAnimationSpace(
    const Skeleton& skeleton, SceneImage& image, std::optional<Uuid> sourceBoneID,
    std::optional<Uuid> targetBoneID) {
    image.basePosition = convertPosition(skeleton, image.basePosition, sourceBoneID, targetBoneID);
    image.baseRotation = convertRotation(skeleton, image.baseRotation, sourceBoneID, targetBoneID);

    // Keyframes are converted in place, matching each track's authored
    // value: translate keyframes hold a world/bone-local point, rotate
    // keyframes hold a world/bone-local angle. Scale, shear and deform are
    // space-invariant; constraint and draw-order tracks aren't owned by a
    // sprite at all, so neither is touched here.
    for (const Keyframe& kf :
         image.animationClip.keyframesFor(image.id, AnimationTrackProperty::Translate)) {
        if (auto* v = std::get_if<TranslateValue>(&kf.value)) {
            const Vec2 converted = convertPosition(skeleton, v->value, sourceBoneID, targetBoneID);
            image.animationClip.updateKeyframeValue(
                image.id, AnimationTrackProperty::Translate, kf.id, TranslateValue{converted});
        }
    }
    for (const Keyframe& kf :
         image.animationClip.keyframesFor(image.id, AnimationTrackProperty::Rotate)) {
        if (auto* v = std::get_if<RotateValue>(&kf.value)) {
            const float converted = convertRotation(skeleton, v->value, sourceBoneID, targetBoneID);
            image.animationClip.updateKeyframeValue(
                image.id, AnimationTrackProperty::Rotate, kf.id, RotateValue{converted});
        }
    }
}

void ensureImageAnimationSpaceConsistency(const Skeleton& skeleton, SceneImage& image) {
    const TransformAnimationSpace expectedSpace = image.boneBinding.has_value()
        ? TransformAnimationSpace::boneLocal(image.boneBinding->boneID)
        : TransformAnimationSpace::world();

    if (image.animationTransformSpace == expectedSpace) return;
    convertImageAnimationSpace(
        skeleton, image, image.animationTransformSpace.boneID, expectedSpace.boneID);
    image.animationTransformSpace = expectedSpace;
}

SceneImageAnimationPose boundImagePose(
    const SceneImageAnimationPose& localPose, const Mat4& worldMatrix) {
    const Vec3 localPoint(localPose.position.x, localPose.position.y, 0);
    const Vec3 worldPoint = MatrixUtilities::transformPoint(localPoint, worldMatrix);
    const Vec2 position(worldPoint.x, worldPoint.y);

    const Vec2 boneX(worldMatrix.columns[0].x, worldMatrix.columns[0].y);
    const Vec2 boneY(worldMatrix.columns[1].x, worldMatrix.columns[1].y);
    const MatrixUtilities::Axes localAxes = MatrixUtilities::shearedAxes(
        localPose.rotation * 180.0f / kPi, localPose.skew, localPose.scale);
    const Vec2 worldX = boneX * localAxes.x.x + boneY * localAxes.x.y;
    const Vec2 worldY = boneX * localAxes.y.x + boneY * localAxes.y.y;

    const auto decomposed =
        MatrixUtilities::decomposeTransform(worldX, worldY, localPose.skew.y);
    if (!decomposed.has_value()) {
        // Degenerate bone scale -- keep the local pose rather than
        // producing NaNs.
        return SceneImageAnimationPose{position, localPose.scale, localPose.rotation, localPose.skew};
    }
    return SceneImageAnimationPose{position, decomposed->scale, decomposed->rotationRadians, decomposed->skewDegrees};
}

void applyBoneBindings(
    std::vector<SceneImage>& bound, const WorldMatrices& worldMatrices, float time,
    bool sampleClips, std::unordered_map<Uuid, float, UuidHash>& lastBoundImageRotation) {
    const bool hasBindings = std::any_of(
        bound.begin(), bound.end(), [](const SceneImage& img) { return img.boneBinding.has_value(); });
    if (!hasBindings) {
        lastBoundImageRotation.clear();
        return;
    }

    for (SceneImage& image : bound) {
        if (!image.boneBinding.has_value()) continue;
        const auto matrixIt = worldMatrices.find(image.boneBinding->boneID);
        if (matrixIt == worldMatrices.end()) continue;

        const SceneImageAnimationPose localPose = sampleClips
            ? image.animationClip.poseAtTime(image.id, image.boneBinding->localPose(), time)
            : image.boneBinding->localPose();

        const SceneImageAnimationPose world = boundImagePose(localPose, matrixIt->second);
        image.position = world.position;
        image.scale = world.scale;
        image.skew = world.skew;

        float rotation = world.rotation;
        // Unwrap toward the previous frame's emitted rotation so the
        // visible angle never jumps by 2*pi while a bone sweeps across the
        // +/-180 degree boundary.
        const auto previousIt = lastBoundImageRotation.find(image.id);
        if (previousIt != lastBoundImageRotation.end()) {
            const float twoPi = kPi * 2.0f;
            rotation += twoPi * std::round((previousIt->second - rotation) / twoPi);
        }
        lastBoundImageRotation[image.id] = rotation;
        image.rotation = rotation;
    }
}

ConstraintSampleResult constraintSampledSkeleton(
    const Skeleton& base, const AnimationClip& sceneAnimationClip,
    const std::unordered_map<Uuid, ConstraintSetupValues, UuidHash>& constraintSetupValues, float time) {
    ConstraintSampleResult result;
    result.skeleton = base;
    Skeleton& working = result.skeleton;

    const auto animatedIDs = sceneAnimationClip.animatedTargetIDs();
    for (Uuid constraintID : animatedIDs) {
        if (constraintID == SceneAnimationTarget::drawOrder()) continue;
        if (!constraintKind(working, constraintID).has_value()) continue;

        const ConstraintSetupValues* setup = nullptr;
        if (auto it = constraintSetupValues.find(constraintID); it != constraintSetupValues.end()) {
            setup = &it->second;
        }

        for (AnimationTrackProperty property : animatableProperties(working, constraintID)) {
            if (!sceneAnimationClip.hasTrack(constraintID, property)) continue;
            result.didChange = true;

            switch (valueKind(property)) {
                case TrackValueKind::Scalar: {
                    float fallback;
                    if (setup && setup->scalar(property).has_value()) {
                        fallback = *setup->scalar(property);
                    } else if (auto live = constraintScalar(working, constraintID, property)) {
                        fallback = *live;
                    } else {
                        fallback = neutralValue(property);
                    }
                    const float sampled =
                        sceneAnimationClip.evaluatedScalarAtTime(constraintID, property, time, fallback);
                    setConstraintScalar(working, constraintID, property, clamped(property, sampled));
                    break;
                }
                case TrackValueKind::Flag: {
                    bool fallback;
                    if (setup && setup->flag(property).has_value()) {
                        fallback = *setup->flag(property);
                    } else if (auto live = constraintFlag(working, constraintID, property)) {
                        fallback = *live;
                    } else {
                        fallback = false;
                    }
                    const bool sampled =
                        sceneAnimationClip.evaluatedFlagAtTime(constraintID, property, time, fallback);
                    setConstraintFlag(working, constraintID, property, sampled);
                    break;
                }
                case TrackValueKind::Vector2: {
                    Vec2 fallback;
                    if (setup && setup->vector(property).has_value()) {
                        fallback = *setup->vector(property);
                    } else if (auto live = constraintVector(working, constraintID, property)) {
                        fallback = *live;
                    } else {
                        fallback = Vec2::zero();
                    }
                    const Vec2 sampled =
                        sceneAnimationClip.evaluatedVector2AtTime(constraintID, property, time, fallback);
                    setConstraintVector(working, constraintID, property, sampled);
                    break;
                }
                case TrackValueKind::Deform:
                case TrackValueKind::DrawOrder:
                case TrackValueKind::Event:
                case TrackValueKind::Attachment:
                    break;
            }
        }
    }
    return result;
}

void applyConstraintAnimations(
    Skeleton& skeleton, const AnimationClip& sceneAnimationClip,
    const std::unordered_map<Uuid, ConstraintSetupValues, UuidHash>& constraintSetupValues,
    bool isAnimationEditingEnabled, float time) {
    const auto animatedIDs = sceneAnimationClip.animatedTargetIDs();
    if (animatedIDs.empty()) return;

    if (isAnimationEditingEnabled) {
        ConstraintSampleResult sampled =
            constraintSampledSkeleton(skeleton, sceneAnimationClip, constraintSetupValues, time);
        if (sampled.didChange) skeleton = std::move(sampled.skeleton);
        return;
    }

    // Setup mode: show the authored value on every animated property, so
    // the Setup/Animate toggle behaves the way this class of editor's does.
    Skeleton working = skeleton;
    bool didWrite = false;
    for (Uuid constraintID : animatedIDs) {
        if (constraintID == SceneAnimationTarget::drawOrder()) continue;
        if (!constraintKind(working, constraintID).has_value()) continue;
        const auto setupIt = constraintSetupValues.find(constraintID);
        if (setupIt == constraintSetupValues.end()) continue;
        const ConstraintSetupValues& setup = setupIt->second;

        for (AnimationTrackProperty property : animatableProperties(working, constraintID)) {
            if (!sceneAnimationClip.hasTrack(constraintID, property)) continue;
            didWrite = true;
            switch (valueKind(property)) {
                case TrackValueKind::Scalar:
                    if (auto v = setup.scalar(property)) setConstraintScalar(working, constraintID, property, *v);
                    break;
                case TrackValueKind::Flag:
                    if (auto v = setup.flag(property)) setConstraintFlag(working, constraintID, property, *v);
                    break;
                case TrackValueKind::Vector2:
                    if (auto v = setup.vector(property)) setConstraintVector(working, constraintID, property, *v);
                    break;
                case TrackValueKind::Deform:
                case TrackValueKind::DrawOrder:
                case TrackValueKind::Event:
                case TrackValueKind::Attachment:
                    break;
            }
        }
    }
    if (didWrite) skeleton = std::move(working);
}

std::optional<std::vector<Uuid>> applyDrawOrderAnimation(
    const AnimationClip& sceneAnimationClip, bool isAnimationEditingEnabled, float time) {
    if (!isAnimationEditingEnabled) return std::nullopt;
    if (!sceneAnimationClip.hasTrack(SceneAnimationTarget::drawOrder(), AnimationTrackProperty::DrawOrder)) {
        return std::nullopt;
    }
    return sceneAnimationClip.evaluatedDrawOrderAtTime(time);
}

std::vector<std::string> slotNames(const std::vector<SceneImage>& images) {
    std::vector<std::string> out;
    std::unordered_set<std::string> seen;
    for (const SceneImage& image : images) {
        const std::string name = image.effectiveSlotName();
        if (seen.insert(name).second) out.push_back(name);
    }
    return out;
}

std::unordered_map<std::string, std::optional<Uuid>> applyAttachmentAnimations(
    const AnimationClip& sceneAnimationClip, const std::vector<SceneImage>& images,
    bool isAnimationEditingEnabled, float time) {
    std::unordered_map<std::string, std::optional<Uuid>> resolved;
    if (!isAnimationEditingEnabled) return resolved;

    for (const std::string& slotName : slotNames(images)) {
        const Uuid target = SlotAnimationTarget::id(slotName);
        if (!sceneAnimationClip.hasTrack(target, AnimationTrackProperty::Attachment)) continue;

        const auto& keys = sceneAnimationClip.keyframesFor(target, AnimationTrackProperty::Attachment);
        const KeyframeSpan span = AnimationClip::keyframeSpan(keys, time);
        const std::optional<std::size_t> index = span.exact.has_value() ? span.exact : span.previous;
        if (!index.has_value()) continue;
        const auto* attachment = std::get_if<AttachmentValue>(&keys[*index].value);
        if (attachment == nullptr) continue;
        resolved[slotName] = attachment->value;
    }
    return resolved;
}

void applySetupPose(
    Skeleton& skeleton, std::vector<SceneImage>& images, bool isPoseMode, float time,
    const WorldMatrices& worldMatrices, std::unordered_map<Uuid, float, UuidHash>& lastBoundImageRotation) {
    if (!isPoseMode) {
        auto restoredBones = skeleton.bones();
        for (auto& entry : restoredBones) {
            Bone& bone = entry.second;
            bone.localTransform.position.x = bone.baseTransform.position.x;
            bone.localTransform.position.y = bone.baseTransform.position.y;
            bone.localTransform.scale.x = bone.baseTransform.scale.x;
            bone.localTransform.scale.y = bone.baseTransform.scale.y;
            bone.localTransform.rotation.z = bone.baseTransform.rotation.z;
            bone.localTransform.skew = bone.baseTransform.skew;
        }
        skeleton.setBones(std::move(restoredBones));
    }

    for (SceneImage& image : images) {
        const SceneImageAnimationPose base =
            image.boneBinding.has_value() ? image.boneBinding->localPose() : image.basePose();
        image.position = base.position;
        image.scale = base.scale;
        image.rotation = base.rotation;
        image.rotation3D = image.baseRotation3D;
        image.skew = base.skew;
        image.meshAnimationDeform = std::nullopt;
    }
    applyBoneBindings(images, worldMatrices, time, /*sampleClips=*/false, lastBoundImageRotation);
}

Vec2 resolvedAnimatedTranslate(const Skeleton& skeleton, const SceneImage& image) {
    if (!image.boneBinding.has_value()) return image.position;
    return skeleton.localPoint(image.position, image.boneBinding->boneID);
}

float resolvedAnimatedRotation(const Skeleton& skeleton, const SceneImage& image) {
    if (!image.boneBinding.has_value()) return image.rotation;
    const auto worldRotation = skeleton.worldRotation(image.boneBinding->boneID);
    return image.rotation - (worldRotation.has_value() ? *worldRotation : 0.0f);
}

std::optional<KeyframeValue> resolvedKeyframeValue(
    const Skeleton& skeleton, const std::vector<SceneImage>& images, Uuid targetID,
    AnimationTrackProperty property) {
    for (const SceneImage& image : images) {
        if (image.id != targetID) continue;
        switch (property) {
            case AnimationTrackProperty::Translate:
                return TranslateValue{resolvedAnimatedTranslate(skeleton, image)};
            case AnimationTrackProperty::Rotate:
                return RotateValue{resolvedAnimatedRotation(skeleton, image)};
            case AnimationTrackProperty::Scale:
                return ScaleValue{image.scale};
            case AnimationTrackProperty::Shear:
                return ShearValue{image.skew};
            default:
                // Deform keys are written by the mesh tools, and constraint /
                // draw order keys are owned by the scene clip, not a sprite.
                return std::nullopt;
        }
    }

    const Bone* bone = skeleton.bone(targetID);
    if (bone == nullptr) return std::nullopt;
    switch (property) {
        case AnimationTrackProperty::Translate:
            return TranslateValue{Vec2(bone->localTransform.position.x, bone->localTransform.position.y)};
        case AnimationTrackProperty::Rotate:
            return RotateValue{bone->localTransform.rotation.z};
        case AnimationTrackProperty::Scale:
            return ScaleValue{Vec2(bone->localTransform.scale.x, bone->localTransform.scale.y)};
        case AnimationTrackProperty::Shear:
            return ShearValue{bone->localTransform.skew};
        default:
            // Bones own transform tracks only.
            return std::nullopt;
    }
}

namespace {
std::optional<SelectedKeyframe> keyframeSelectionAt(
    const AnimationClip& clip, Uuid targetID, AnimationTrackProperty property, int frame) {
    for (const Keyframe& kf : clip.keyframesFor(targetID, property)) {
        if (kf.frame == frame) return SelectedKeyframe{targetID, property, kf.id};
    }
    return std::nullopt;
}
} // namespace

std::optional<SelectedKeyframe> commitKeyframe(
    Skeleton& skeleton, std::vector<SceneImage>& images, const AnimationClip& sceneAnimationClip,
    const std::unordered_map<Uuid, ConstraintSetupValues, UuidHash>& constraintSetupValues,
    bool isAnimationEditingEnabled, bool isPoseMode, float time, int currentFrame, Uuid targetID,
    AnimationTrackProperty property, std::optional<KeyframeValue> value,
    std::unordered_map<Uuid, float, UuidHash>& lastBoundImageRotation) {
    if (!isAnimationEditingEnabled) return std::nullopt;

    for (SceneImage& image : images) {
        if (image.id != targetID) continue;
        const std::optional<KeyframeValue> resolvedValue =
            value.has_value() ? value : resolvedKeyframeValue(skeleton, images, targetID, property);
        if (!resolvedValue.has_value()) return std::nullopt;

        image.animationClip.upsertKeyframe(targetID, property, currentFrame, *resolvedValue);
        const std::optional<SelectedKeyframe> selection =
            keyframeSelectionAt(image.animationClip, targetID, property, currentFrame);
        applyAnimations(
            skeleton, images, sceneAnimationClip, constraintSetupValues, isAnimationEditingEnabled,
            isPoseMode, time, lastBoundImageRotation);
        return selection;
    }

    const Bone* bonePtr = skeleton.bone(targetID);
    if (bonePtr == nullptr) return std::nullopt;
    const std::optional<KeyframeValue> resolvedValue =
        value.has_value() ? value : resolvedKeyframeValue(skeleton, images, targetID, property);
    if (!resolvedValue.has_value()) return std::nullopt;

    Bone bone = *bonePtr;
    bone.animationClip.upsertKeyframe(targetID, property, currentFrame, *resolvedValue);
    const std::optional<SelectedKeyframe> selection =
        keyframeSelectionAt(bone.animationClip, targetID, property, currentFrame);
    skeleton.setBone(bone);
    applyAnimations(
        skeleton, images, sceneAnimationClip, constraintSetupValues, isAnimationEditingEnabled, isPoseMode,
        time, lastBoundImageRotation);
    return selection;
}

std::optional<SelectedKeyframe> commitMeshDeformKeyframe(
    Skeleton& skeleton, std::vector<SceneImage>& images, const AnimationClip& sceneAnimationClip,
    const std::unordered_map<Uuid, ConstraintSetupValues, UuidHash>& constraintSetupValues,
    bool isAnimationEditingEnabled, bool isPoseMode, float time, int currentFrame, Uuid imageID,
    std::unordered_map<Uuid, float, UuidHash>& lastBoundImageRotation) {
    if (!isAnimationEditingEnabled) return std::nullopt;

    for (SceneImage& image : images) {
        if (image.id != imageID) continue;
        const std::vector<Vec2>& vertices =
            image.meshAnimationDeform.has_value() ? *image.meshAnimationDeform : image.mesh.vertices;
        if (vertices.empty()) return std::nullopt;

        image.animationClip.upsertKeyframe(
            imageID, AnimationTrackProperty::MeshDeform, currentFrame, MeshDeformValue{vertices},
            KeyframeInterpolation::Linear);
        const std::optional<SelectedKeyframe> selection = keyframeSelectionAt(
            image.animationClip, imageID, AnimationTrackProperty::MeshDeform, currentFrame);
        applyAnimations(
            skeleton, images, sceneAnimationClip, constraintSetupValues, isAnimationEditingEnabled,
            isPoseMode, time, lastBoundImageRotation);
        return selection;
    }
    return std::nullopt;
}

AnimationFrameResult applyAnimations(
    Skeleton& skeleton, std::vector<SceneImage>& images, const AnimationClip& sceneAnimationClip,
    const std::unordered_map<Uuid, ConstraintSetupValues, UuidHash>& constraintSetupValues,
    bool isAnimationEditingEnabled, bool isPoseMode, float time,
    std::unordered_map<Uuid, float, UuidHash>& lastBoundImageRotation) {
    AnimationFrameResult result;

    // Constraint properties must settle before any world matrix is built,
    // because the solver reads mix/softness/etc. straight off the structs.
    applyConstraintAnimations(
        skeleton, sceneAnimationClip, constraintSetupValues, isAnimationEditingEnabled, time);
    result.animatedDrawOrder = applyDrawOrderAnimation(sceneAnimationClip, isAnimationEditingEnabled, time);
    result.animatedAttachments =
        applyAttachmentAnimations(sceneAnimationClip, images, isAnimationEditingEnabled, time);

    if (!isAnimationEditingEnabled) {
        for (SceneImage& image : images) ensureImageAnimationSpaceConsistency(skeleton, image);
        const WorldMatrices worldMatrices = skeleton.worldMatrices();
        applySetupPose(skeleton, images, isPoseMode, time, worldMatrices, lastBoundImageRotation);
        return result;
    }

    // In pose mode the artist is hand-posing localTransforms directly;
    // re-evaluating clips here would silently revert the pose every frame.
    if (!isPoseMode) {
        skeleton.setBones(clipSampledBones(skeleton.bones(), time));
    }
    // Runs first, against the live array, because it can convert a sprite's
    // animation space (a structural change, not a pose one).
    for (SceneImage& image : images) ensureImageAnimationSpaceConsistency(skeleton, image);

    for (SceneImage& image : images) {
        const SceneImageAnimationPose basePose =
            image.boneBinding.has_value() ? image.boneBinding->localPose() : image.basePose();
        const SceneImageAnimationPose pose = image.animationClip.poseAtTime(image.id, basePose, time);
        image.position = pose.position;
        image.scale = pose.scale;
        image.rotation = pose.rotation;
        image.rotation3D = image.baseRotation3D;
        image.skew = pose.skew;

        const std::vector<Vec2> deformed = image.animationClip.evaluatedMeshDeformAtTime(image.id, time, {});
        image.meshAnimationDeform = !deformed.empty() ? std::optional<std::vector<Vec2>>(deformed) : std::nullopt;
    }
    // Same frame's ONE solve: constraint and bone animation passes above
    // have already updated `skeleton`, so this reflects this frame's pose.
    const WorldMatrices worldMatrices = skeleton.worldMatrices();
    applyBoneBindings(images, worldMatrices, time, /*sampleClips=*/true, lastBoundImageRotation);
    return result;
}

} // namespace umeshcore
