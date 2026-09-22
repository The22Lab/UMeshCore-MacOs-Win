#include "umeshcore/Animation/SceneAnimator.h"

#include <algorithm>
#include <cmath>

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

} // namespace umeshcore
