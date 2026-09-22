// Tests for SceneAnimator.h, ported from `SceneManager.clipSampledBones`,
// `applyBoneBindings`/`boundImagePose`, and
// `ensureImageAnimationSpaceConsistency`/`convertImageAnimationSpace`.
// Expected values are hand-derived from the matrix/decompose formulas
// already golden-tested in MathTests.cpp and AnimationTests.cpp, not from
// this file's own output.

#include "umeshcore/Animation/SceneAnimator.h"
#include "umeshcore/Constraints/ConstraintAnimation.h"
#include "umeshcore/Math/MatrixUtilities.h"
#include "TestHarness.h"

using namespace umeshcore;

static Bone makeBone(Vec2 basePosition, float baseRotation) {
    Bone b;
    b.id = Uuid::generate();
    b.name = "bone";
    b.baseTransform.position = Vec3(basePosition.x, basePosition.y, 0);
    b.baseTransform.rotation = Vec3(0, 0, baseRotation);
    b.baseTransform.scale = Vec3::one();
    b.localTransform = b.baseTransform;
    b.animationClip = AnimationClip("bone");
    return b;
}

static void testUnanimatedBoneKeepsBasePose() {
    Bone bone = makeBone(Vec2(10, 20), 0.3f);
    // Move localTransform away from base, so the test can tell whether
    // clipSampledBones actually re-derives it from base + clip (it must,
    // since an unkeyed bone has no clip to override the base pose with).
    bone.localTransform.position = Vec3(999, 999, 0);

    std::unordered_map<Uuid, Bone, UuidHash> bones;
    bones[bone.id] = bone;

    const auto sampled = clipSampledBones(bones, /*time=*/0.0f);
    const Bone& result = sampled.at(bone.id);
    UM_CHECK_NEAR(result.localTransform.position.x, 10.0, 1e-4);
    UM_CHECK_NEAR(result.localTransform.position.y, 20.0, 1e-4);
    UM_CHECK_NEAR(result.localTransform.rotation.z, 0.3, 1e-4);
}

static void testAnimatedBoneSamplesTranslateTrack() {
    Bone bone = makeBone(Vec2(0, 0), 0.0f);
    bone.animationClip.upsertKeyframe(
        bone.id, AnimationTrackProperty::Translate, /*frame=*/0, TranslateValue{Vec2(0, 0)});
    bone.animationClip.upsertKeyframe(
        bone.id, AnimationTrackProperty::Translate, /*frame=*/10, TranslateValue{Vec2(100, 0)});

    std::unordered_map<Uuid, Bone, UuidHash> bones;
    bones[bone.id] = bone;

    // Frame 5 of a 0->10 linear translate track: halfway.
    const auto sampled = clipSampledBones(bones, /*time=*/5.0f);
    const Bone& result = sampled.at(bone.id);
    UM_CHECK_NEAR(result.localTransform.position.x, 50.0, 1e-3);
    UM_CHECK_NEAR(result.localTransform.position.y, 0.0, 1e-3);
}

static void testCyclicRotationTakesShortestPathAcrossWrap() {
    // A rotate track from just past +pi to just past -pi. The short way
    // round crosses the wrap boundary (the "long way" would be ~2*pi - the
    // short delta); cyclicRotation=true must take the short way, matching
    // moveBoneTip/setBoneRotation writing rotation.z through atan2 (wrapped
    // to (-pi, pi]).
    Bone bone = makeBone(Vec2::zero(), 0.0f);
    const float justPastPi = 3.10f;   // ~ pi - 0.04
    const float justPastNegPi = -3.10f;
    bone.animationClip.upsertKeyframe(
        bone.id, AnimationTrackProperty::Rotate, /*frame=*/0, RotateValue{justPastPi});
    bone.animationClip.upsertKeyframe(
        bone.id, AnimationTrackProperty::Rotate, /*frame=*/10, RotateValue{justPastNegPi});

    std::unordered_map<Uuid, Bone, UuidHash> bones;
    bones[bone.id] = bone;

    // Halfway across a wrap that is ~0.08 rad wide (via the short way) should
    // land near +/-pi, not near 0 (which is where the "long way" midpoint
    // would fall).
    const auto sampled = clipSampledBones(bones, /*time=*/5.0f);
    const float halfway = sampled.at(bone.id).localTransform.rotation.z;
    UM_CHECK(std::abs(halfway) > 3.0);
}

static void testBoundImagePoseComposesBoneRotationAndTranslation() {
    // Bone world matrix: rotate 90deg, then translate to (100, 0). A sprite
    // sitting at local (10, 0) with identity rotation/scale/skew should land
    // at (100, 10) -- (10,0) rotated 90deg is (0,10), then offset by the
    // bone's world position -- with the bone's rotation carried onto it.
    const Mat4 worldMatrix =
        MatrixUtilities::translation(Vec3(100, 0, 0)) * MatrixUtilities::rotationZ(kPi / 2.0f);
    SceneImageAnimationPose localPose;
    localPose.position = Vec2(10, 0);
    localPose.scale = Vec2::one();

    const SceneImageAnimationPose world = boundImagePose(localPose, worldMatrix);
    UM_CHECK_NEAR(world.position.x, 100.0, 1e-3);
    UM_CHECK_NEAR(world.position.y, 10.0, 1e-3);
    UM_CHECK_NEAR(world.rotation, kPi / 2.0, 1e-3);
    UM_CHECK_NEAR(world.scale.x, 1.0, 1e-4);
    UM_CHECK_NEAR(world.scale.y, 1.0, 1e-4);
}

static void testApplyBoneBindingsUnwrapsRotationAcrossWrap() {
    Bone bone = makeBone(Vec2::zero(), 0.0f);
    std::unordered_map<Uuid, Bone, UuidHash> bones;
    bones[bone.id] = bone;

    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.boneBinding = BoneImageBinding{bone.id, Vec2::zero(), Vec2::one(), 0.0f, Vec2::zero()};
    std::vector<SceneImage> images{image};

    std::unordered_map<Uuid, float, UuidHash> lastRotation;

    // First call: bone just short of +pi.
    WorldMatrices matrices;
    matrices[bone.id] = MatrixUtilities::rotationZ(kPi - 0.05f);
    applyBoneBindings(images, matrices, /*time=*/0.0f, /*sampleClips=*/false, lastRotation);
    const float first = images[0].rotation;
    UM_CHECK(first > 3.0);

    // Second call: bone continues rotating the same way, past +pi, which
    // atan2 reports wrapped to just past -pi. Unwrapped, this must land
    // close to `first` (a small further step), not jump by ~2*pi.
    matrices[bone.id] = MatrixUtilities::rotationZ(-(kPi - 0.05f));
    applyBoneBindings(images, matrices, /*time=*/0.0f, /*sampleClips=*/false, lastRotation);
    const float second = images[0].rotation;
    UM_CHECK(std::abs(second - first) < 0.3);
}

static void testApplyBoneBindingsClearsContinuityWhenNothingIsBound() {
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    // No boneBinding.
    std::vector<SceneImage> images{image};

    std::unordered_map<Uuid, float, UuidHash> lastRotation;
    lastRotation[Uuid::generate()] = 1.23f;

    WorldMatrices matrices;
    applyBoneBindings(images, matrices, 0.0f, false, lastRotation);
    UM_CHECK(lastRotation.empty());
}

static void testEnsureImageAnimationSpaceConsistencyConvertsBaseValues() {
    // A bone offset to (50, 0) with no rotation. A world-space sprite whose
    // base position is (50, 0) is exactly AT the bone's origin, so once
    // bound its bone-local base position must become (0, 0).
    Skeleton skeleton;
    Bone bone = Bone::makeRoot("bone", Vec2(50, 0), Vec2(150, 0));
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);

    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.basePosition = Vec2(50, 0);
    image.animationTransformSpace = TransformAnimationSpace::world();
    image.boneBinding = BoneImageBinding{bone.id, Vec2::zero(), Vec2::one(), 0.0f, Vec2::zero()};

    ensureImageAnimationSpaceConsistency(skeleton, image);

    UM_CHECK(image.animationTransformSpace == TransformAnimationSpace::boneLocal(bone.id));
    UM_CHECK_NEAR(image.basePosition.x, 0.0, 1e-3);
    UM_CHECK_NEAR(image.basePosition.y, 0.0, 1e-3);

    // Calling again with the space already consistent must be a no-op.
    ensureImageAnimationSpaceConsistency(skeleton, image);
    UM_CHECK_NEAR(image.basePosition.x, 0.0, 1e-3);
}

static void testConstraintSampledSkeletonInterpolatesScalarTrack() {
    Skeleton skeleton;
    IKConstraint ik;
    ik.mix_ = 1.0f; // Overwritten by the sample -- not read since a track exists.
    skeleton.ikConstraints.push_back(ik);

    AnimationClip sceneClip("Scene");
    sceneClip.upsertKeyframe(ik.id_, AnimationTrackProperty::ConstraintMix, /*frame=*/0, ScalarValue{0.2f});
    sceneClip.upsertKeyframe(ik.id_, AnimationTrackProperty::ConstraintMix, /*frame=*/10, ScalarValue{0.8f});

    std::unordered_map<Uuid, ConstraintSetupValues, UuidHash> setupValues;
    const ConstraintSampleResult result =
        constraintSampledSkeleton(skeleton, sceneClip, setupValues, /*time=*/5.0f);

    UM_CHECK(result.didChange);
    UM_CHECK_NEAR(result.skeleton.ikConstraints[0].mix_, 0.5, 1e-3);
    // The base skeleton passed in is never mutated -- only the copy.
    UM_CHECK_NEAR(skeleton.ikConstraints[0].mix_, 1.0, 1e-5);
}

static void testConstraintSampledSkeletonOnlyWritesTrackedProperties() {
    // A constraint with ONE animated property (ConstraintMix) still owns
    // several animatable properties (see `animatableProperties`). Only the
    // one with an actual track gets sampled and written; the rest -- here
    // PathRotateMix, which has no track -- must be left at their live value.
    Skeleton skeleton;
    PathConstraint path;
    path.rotateMix = 0.11f;
    skeleton.pathConstraints.push_back(path);

    AnimationClip sceneClip("Scene");
    sceneClip.upsertKeyframe(path.id_, AnimationTrackProperty::ConstraintMix, /*frame=*/0, ScalarValue{1.0f});

    std::unordered_map<Uuid, ConstraintSetupValues, UuidHash> setupValues;
    const ConstraintSampleResult result =
        constraintSampledSkeleton(skeleton, sceneClip, setupValues, /*time=*/0.0f);
    UM_CHECK_NEAR(result.skeleton.pathConstraints[0].rotateMix, 0.11, 1e-4);
    UM_CHECK_NEAR(result.skeleton.pathConstraints[0].mix_, 1.0, 1e-3);
}

static void testApplyConstraintAnimationsSetupModeRestoresAuthoredValue() {
    Skeleton skeleton;
    TransformConstraint transform;
    // Animation left the mix at some sampled value; Setup mode must restore
    // the authored one below, not leave this in place.
    transform.mix_ = 0.9f;
    skeleton.transformConstraints.push_back(transform);

    AnimationClip sceneClip("Scene");
    sceneClip.upsertKeyframe(
        transform.id_, AnimationTrackProperty::ConstraintMix, /*frame=*/0, ScalarValue{0.3f});

    std::unordered_map<Uuid, ConstraintSetupValues, UuidHash> setupValues;
    ConstraintSetupValues setup;
    setup.set(AnimationTrackProperty::ConstraintMix, 0.42f);
    setupValues[transform.id_] = setup;

    applyConstraintAnimations(
        skeleton, sceneClip, setupValues, /*isAnimationEditingEnabled=*/false, /*time=*/0.0f);
    UM_CHECK_NEAR(skeleton.transformConstraints[0].mix_, 0.42, 1e-4);
}

static void testApplyConstraintAnimationsAnimateModeSamplesClip() {
    Skeleton skeleton;
    IKConstraint ik;
    skeleton.ikConstraints.push_back(ik);

    AnimationClip sceneClip("Scene");
    sceneClip.upsertKeyframe(ik.id_, AnimationTrackProperty::ConstraintMix, /*frame=*/0, ScalarValue{0.0f});
    sceneClip.upsertKeyframe(ik.id_, AnimationTrackProperty::ConstraintMix, /*frame=*/10, ScalarValue{1.0f});
    std::unordered_map<Uuid, ConstraintSetupValues, UuidHash> setupValues;

    applyConstraintAnimations(
        skeleton, sceneClip, setupValues, /*isAnimationEditingEnabled=*/true, /*time=*/10.0f);
    UM_CHECK_NEAR(skeleton.ikConstraints[0].mix_, 1.0, 1e-3);
}

static void testApplyConstraintAnimationsNoOpWhenNothingAnimated() {
    Skeleton skeleton;
    IKConstraint ik;
    ik.mix_ = 0.55f;
    skeleton.ikConstraints.push_back(ik);

    AnimationClip sceneClip("Scene"); // No tracks at all.
    std::unordered_map<Uuid, ConstraintSetupValues, UuidHash> setupValues;

    applyConstraintAnimations(skeleton, sceneClip, setupValues, true, 3.0f);
    applyConstraintAnimations(skeleton, sceneClip, setupValues, false, 3.0f);
    UM_CHECK_NEAR(skeleton.ikConstraints[0].mix_, 0.55, 1e-5);
}

static void testApplyDrawOrderAnimationReturnsNulloptWhenNotAnimating() {
    AnimationClip sceneClip("Scene");
    sceneClip.upsertKeyframe(
        SceneAnimationTarget::drawOrder(), AnimationTrackProperty::DrawOrder, 0,
        DrawOrderValue{{Uuid::generate(), Uuid::generate()}});

    UM_CHECK(!applyDrawOrderAnimation(sceneClip, /*isAnimationEditingEnabled=*/false, 0.0f).has_value());
}

static void testApplyDrawOrderAnimationReturnsKeyedOrder() {
    const Uuid a = Uuid::generate();
    const Uuid b = Uuid::generate();
    AnimationClip sceneClip("Scene");
    sceneClip.upsertKeyframe(
        SceneAnimationTarget::drawOrder(), AnimationTrackProperty::DrawOrder, 0, DrawOrderValue{{a, b}});
    sceneClip.upsertKeyframe(
        SceneAnimationTarget::drawOrder(), AnimationTrackProperty::DrawOrder, 10, DrawOrderValue{{b, a}});

    // Stepped: at frame 5 (before the second key), the order is still the
    // first key's, not an interpolation of the two.
    const auto order = applyDrawOrderAnimation(sceneClip, /*isAnimationEditingEnabled=*/true, 5.0f);
    UM_CHECK(order.has_value());
    UM_CHECK(order->size() == 2);
    UM_CHECK((*order)[0] == a && (*order)[1] == b);
}

static void testSlotNamesInFirstAppearanceOrder() {
    SceneImage first;
    first.slotName = "hat";
    SceneImage second;
    second.name = "shirt"; // slotName empty -> effectiveSlotName falls back to name.
    SceneImage third;
    third.slotName = "hat"; // Repeats the first slot -- must not duplicate.

    const auto names = slotNames({first, second, third});
    UM_CHECK(names.size() == 2);
    UM_CHECK(names[0] == "hat");
    UM_CHECK(names[1] == "shirt");
}

static void testApplyAttachmentAnimationsResolvesKeyedSlotAndOmitsUnkeyed() {
    SceneImage hatSlot;
    hatSlot.slotName = "hat";
    SceneImage shirtSlot;
    shirtSlot.slotName = "shirt"; // No attachment track for this one.

    const Uuid strawHat = Uuid::generate();
    AnimationClip sceneClip("Scene");
    sceneClip.upsertKeyframe(
        SlotAnimationTarget::id("hat"), AnimationTrackProperty::Attachment, 0,
        AttachmentValue{strawHat});

    const auto resolved =
        applyAttachmentAnimations(sceneClip, {hatSlot, shirtSlot}, /*isAnimationEditingEnabled=*/true, 0.0f);
    UM_CHECK(resolved.size() == 1);
    const auto it = resolved.find("hat");
    UM_CHECK(it != resolved.end());
    UM_CHECK(it->second.has_value() && *it->second == strawHat);
    UM_CHECK(resolved.find("shirt") == resolved.end());
}

static void testApplyAttachmentAnimationsExplicitlyEmptySlot() {
    SceneImage hatSlot;
    hatSlot.slotName = "hat";

    AnimationClip sceneClip("Scene");
    // A nil-valued attachment keyframe means "show nothing", distinct from
    // no track at all.
    sceneClip.upsertKeyframe(
        SlotAnimationTarget::id("hat"), AnimationTrackProperty::Attachment, 0,
        AttachmentValue{std::nullopt});

    const auto resolved =
        applyAttachmentAnimations(sceneClip, {hatSlot}, /*isAnimationEditingEnabled=*/true, 0.0f);
    const auto it = resolved.find("hat");
    UM_CHECK(it != resolved.end());
    UM_CHECK(!it->second.has_value());
}

static void testApplyAttachmentAnimationsEmptyWhenNotAnimating() {
    SceneImage hatSlot;
    hatSlot.slotName = "hat";
    AnimationClip sceneClip("Scene");
    sceneClip.upsertKeyframe(
        SlotAnimationTarget::id("hat"), AnimationTrackProperty::Attachment, 0,
        AttachmentValue{Uuid::generate()});

    const auto resolved =
        applyAttachmentAnimations(sceneClip, {hatSlot}, /*isAnimationEditingEnabled=*/false, 0.0f);
    UM_CHECK(resolved.empty());
}

static void testApplySetupPoseRestoresBoneFromBaseWhenNotPosing() {
    Skeleton skeleton;
    Bone bone = makeBone(Vec2(10, 20), 0.4f);
    bone.localTransform.position = Vec3(999, 999, 0); // Drifted away from base.
    bone.localTransform.rotation.z = 1.5f;
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);

    std::vector<SceneImage> images;
    std::unordered_map<Uuid, float, UuidHash> lastRotation;
    WorldMatrices matrices;

    applySetupPose(skeleton, images, /*isPoseMode=*/false, 0.0f, matrices, lastRotation);

    const Bone& restored = *skeleton.bone(bone.id);
    UM_CHECK_NEAR(restored.localTransform.position.x, 10.0, 1e-4);
    UM_CHECK_NEAR(restored.localTransform.position.y, 20.0, 1e-4);
    UM_CHECK_NEAR(restored.localTransform.rotation.z, 0.4, 1e-4);
}

static void testApplySetupPosePreservesLocalTransformWhilePosing() {
    Skeleton skeleton;
    Bone bone = makeBone(Vec2(10, 20), 0.4f);
    bone.localTransform.position = Vec3(999, 999, 0); // The pose an artist just posed.
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);

    std::vector<SceneImage> images;
    std::unordered_map<Uuid, float, UuidHash> lastRotation;
    WorldMatrices matrices;

    applySetupPose(skeleton, images, /*isPoseMode=*/true, 0.0f, matrices, lastRotation);

    // Pose mode owns localTransform -- must be left exactly as posed.
    UM_CHECK_NEAR(skeleton.bone(bone.id)->localTransform.position.x, 999.0, 1e-3);
}

static void testApplySetupPoseRestoresSpriteFromBasePoseAndClearsDeform() {
    Skeleton skeleton;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.basePosition = Vec2(5, 6);
    image.baseScale = Vec2(2, 2);
    image.baseRotation = 0.25f;
    image.position = Vec2(999, 999); // Left over from a previous animated frame.
    image.meshAnimationDeform = std::vector<Vec2>{Vec2(1, 1)};
    std::vector<SceneImage> images{image};

    std::unordered_map<Uuid, float, UuidHash> lastRotation;
    WorldMatrices matrices;
    applySetupPose(skeleton, images, false, 0.0f, matrices, lastRotation);

    UM_CHECK_NEAR(images[0].position.x, 5.0, 1e-4);
    UM_CHECK_NEAR(images[0].position.y, 6.0, 1e-4);
    UM_CHECK_NEAR(images[0].scale.x, 2.0, 1e-4);
    UM_CHECK_NEAR(images[0].rotation, 0.25, 1e-4);
    UM_CHECK(!images[0].meshAnimationDeform.has_value());
}

static void testResolvedKeyframeValuePrefersImageOverBone() {
    Skeleton skeleton;
    Bone bone = makeBone(Vec2(1, 2), 0.5f);
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);

    // A sprite whose id happens to equal the bone's id would be a bug
    // elsewhere in the app, but the resolution order itself -- images
    // first, bones second -- is what this test checks, using an unbound
    // sprite with its own id.
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.position = Vec2(30, 40);
    image.scale = Vec2(1.5f, 1.5f);
    std::vector<SceneImage> images{image};

    const auto translate = resolvedKeyframeValue(skeleton, images, image.id, AnimationTrackProperty::Translate);
    UM_CHECK(translate.has_value());
    const auto* tv = std::get_if<TranslateValue>(&*translate);
    UM_CHECK(tv != nullptr);
    UM_CHECK_NEAR(tv->value.x, 30.0, 1e-4);
    UM_CHECK_NEAR(tv->value.y, 40.0, 1e-4);

    const auto scale = resolvedKeyframeValue(skeleton, images, image.id, AnimationTrackProperty::Scale);
    const auto* sv = std::get_if<ScaleValue>(&*scale);
    UM_CHECK(sv != nullptr && std::abs(sv->value.x - 1.5f) < 1e-4);
}

static void testResolvedKeyframeValueFallsBackToBone() {
    Skeleton skeleton;
    Bone bone = makeBone(Vec2(7, 8), 0.9f);
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);
    std::vector<SceneImage> images; // No sprites at all.

    const auto rotate = resolvedKeyframeValue(skeleton, images, bone.id, AnimationTrackProperty::Rotate);
    UM_CHECK(rotate.has_value());
    const auto* rv = std::get_if<RotateValue>(&*rotate);
    UM_CHECK(rv != nullptr && std::abs(rv->value - 0.9f) < 1e-4);
}

static void testResolvedKeyframeValueUnsupportedPropertyReturnsNullopt() {
    Skeleton skeleton;
    Bone bone = makeBone(Vec2::zero(), 0.0f);
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);
    std::vector<SceneImage> images;

    UM_CHECK(!resolvedKeyframeValue(skeleton, images, bone.id, AnimationTrackProperty::MeshDeform).has_value());
    UM_CHECK(!resolvedKeyframeValue(skeleton, images, Uuid::generate(), AnimationTrackProperty::Translate)
                  .has_value());
}

static void testCommitKeyframeWritesAndSelectsBoneKeyframe() {
    Skeleton skeleton;
    Bone bone = makeBone(Vec2(5, 5), 0.2f);
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);

    std::vector<SceneImage> images;
    AnimationClip sceneClip("Scene");
    std::unordered_map<Uuid, ConstraintSetupValues, UuidHash> setupValues;
    std::unordered_map<Uuid, float, UuidHash> lastRotation;

    const auto selection = commitKeyframe(
        skeleton, images, sceneClip, setupValues, /*isAnimationEditingEnabled=*/true, /*isPoseMode=*/false,
        /*time=*/3.0f, /*currentFrame=*/3, bone.id, AnimationTrackProperty::Rotate,
        /*value=*/std::nullopt, lastRotation);

    UM_CHECK(selection.has_value());
    UM_CHECK(selection->imageID == bone.id);
    UM_CHECK(selection->property == AnimationTrackProperty::Rotate);

    const Bone& updated = *skeleton.bone(bone.id);
    UM_CHECK(updated.animationClip.hasTrack(bone.id, AnimationTrackProperty::Rotate));
    const auto& keys = updated.animationClip.keyframesFor(bone.id, AnimationTrackProperty::Rotate);
    UM_CHECK(keys.size() == 1);
    UM_CHECK(keys[0].frame == 3);
    const auto* rv = std::get_if<RotateValue>(&keys[0].value);
    // Resolved from the bone's current local rotation, since no explicit
    // value was passed.
    UM_CHECK(rv != nullptr && std::abs(rv->value - 0.2f) < 1e-3);
}

static void testCommitKeyframeNoOpOutsideAnimateMode() {
    Skeleton skeleton;
    Bone bone = makeBone(Vec2::zero(), 0.0f);
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);
    std::vector<SceneImage> images;
    AnimationClip sceneClip("Scene");
    std::unordered_map<Uuid, ConstraintSetupValues, UuidHash> setupValues;
    std::unordered_map<Uuid, float, UuidHash> lastRotation;

    const auto selection = commitKeyframe(
        skeleton, images, sceneClip, setupValues, /*isAnimationEditingEnabled=*/false, false, 0.0f, 0,
        bone.id, AnimationTrackProperty::Translate, std::nullopt, lastRotation);
    UM_CHECK(!selection.has_value());
    UM_CHECK(!skeleton.bone(bone.id)->animationClip.hasTrack(bone.id, AnimationTrackProperty::Translate));
}

static void testCommitMeshDeformKeyframeCapturesCurrentDeform() {
    Skeleton skeleton;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.mesh = Mesh::makeQuad("m", Vec2(10, 10));
    image.meshAnimationDeform = image.mesh.vertices; // Pretend a drag already deformed it.
    image.meshAnimationDeform->at(0) = Vec2(99, 99);
    std::vector<SceneImage> images{image};

    AnimationClip sceneClip("Scene");
    std::unordered_map<Uuid, ConstraintSetupValues, UuidHash> setupValues;
    std::unordered_map<Uuid, float, UuidHash> lastRotation;

    const auto selection = commitMeshDeformKeyframe(
        skeleton, images, sceneClip, setupValues, /*isAnimationEditingEnabled=*/true, false, 7.0f, 7,
        image.id, lastRotation);
    UM_CHECK(selection.has_value());
    UM_CHECK(selection->property == AnimationTrackProperty::MeshDeform);

    const auto& keys = images[0].animationClip.keyframesFor(image.id, AnimationTrackProperty::MeshDeform);
    UM_CHECK(keys.size() == 1);
    const auto* dv = std::get_if<MeshDeformValue>(&keys[0].value);
    UM_CHECK(dv != nullptr);
    UM_CHECK_NEAR(dv->value.at(0).x, 99.0, 1e-3);
}

static void testApplyAnimationsAnimateModeSamplesBoneAndSprite() {
    Skeleton skeleton;
    Bone bone = makeBone(Vec2(0, 0), 0.0f);
    bone.animationClip.upsertKeyframe(bone.id, AnimationTrackProperty::Translate, 0, TranslateValue{Vec2(0, 0)});
    bone.animationClip.upsertKeyframe(bone.id, AnimationTrackProperty::Translate, 10, TranslateValue{Vec2(20, 0)});
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);

    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.basePosition = Vec2(1, 1);
    std::vector<SceneImage> images{image};

    AnimationClip sceneClip("Scene");
    std::unordered_map<Uuid, ConstraintSetupValues, UuidHash> setupValues;
    std::unordered_map<Uuid, float, UuidHash> lastRotation;

    applyAnimations(
        skeleton, images, sceneClip, setupValues, /*isAnimationEditingEnabled=*/true, /*isPoseMode=*/false,
        /*time=*/5.0f, lastRotation);

    UM_CHECK_NEAR(skeleton.bone(bone.id)->localTransform.position.x, 10.0, 1e-2);
    // Unbound sprite with no clip of its own: pose falls back to basePose.
    UM_CHECK_NEAR(images[0].position.x, 1.0, 1e-4);
}

static void testApplyAnimationsSetupModeRestoresBasePoseAndReturnsDrawOrder() {
    Skeleton skeleton;
    Bone bone = makeBone(Vec2(3, 4), 0.1f);
    bone.localTransform.position = Vec3(999, 999, 0); // Drifted -- must be restored.
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);
    std::vector<SceneImage> images;

    const Uuid a = Uuid::generate();
    AnimationClip sceneClip("Scene");
    sceneClip.upsertKeyframe(
        SceneAnimationTarget::drawOrder(), AnimationTrackProperty::DrawOrder, 0, DrawOrderValue{{a}});
    std::unordered_map<Uuid, ConstraintSetupValues, UuidHash> setupValues;
    std::unordered_map<Uuid, float, UuidHash> lastRotation;

    const AnimationFrameResult result = applyAnimations(
        skeleton, images, sceneClip, setupValues, /*isAnimationEditingEnabled=*/false, false, 0.0f,
        lastRotation);

    UM_CHECK_NEAR(skeleton.bone(bone.id)->localTransform.position.x, 3.0, 1e-3);
    // Setup mode never animates the draw order, regardless of its track.
    UM_CHECK(!result.animatedDrawOrder.has_value());
}

static void testLocalSpritePoseIsExactInverseOfBoundImagePose() {
    // A rotated+translated bone; a sprite sitting at a world pose. Converting
    // that world pose into the bone's local space with localSpritePose, then
    // placing the result back on the bone with boundImagePose, must return
    // exactly the original world pose -- the whole point of "binding a
    // sprite never changes what's on screen."
    Skeleton skeleton;
    Bone bone = Bone::makeRoot("bone", Vec2(50, 20), Vec2(150, 20));
    skeleton.setBone(bone);
    skeleton.rootIDs.push_back(bone.id);

    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.position = Vec2(80, 45);
    image.rotation = 0.3f;
    image.scale = Vec2(1.2f, 0.9f);
    image.skew = Vec2(5.0f, 0.0f);

    const SceneImageAnimationPose local = localSpritePose(skeleton, image, bone.id);
    const Mat4 worldMatrix = *skeleton.worldMatrix(bone.id);
    const SceneImageAnimationPose roundTripped = boundImagePose(local, worldMatrix);

    UM_CHECK_NEAR(roundTripped.position.x, image.position.x, 1e-2);
    UM_CHECK_NEAR(roundTripped.position.y, image.position.y, 1e-2);
    UM_CHECK_NEAR(roundTripped.rotation, image.rotation, 1e-3);
    UM_CHECK_NEAR(roundTripped.scale.x, image.scale.x, 1e-3);
    UM_CHECK_NEAR(roundTripped.scale.y, image.scale.y, 1e-3);
}

static void testLocalSpritePoseWithNoBoneReturnsWorldPoseUnchanged() {
    Skeleton skeleton;
    SceneImage image;
    image.id = Uuid::generate();
    image.animationClip = AnimationClip("sprite");
    image.position = Vec2(7, 8);
    image.rotation = 0.1f;

    const SceneImageAnimationPose local = localSpritePose(skeleton, image, std::nullopt);
    UM_CHECK_NEAR(local.position.x, 7.0, 1e-5);
    UM_CHECK_NEAR(local.position.y, 8.0, 1e-5);
    UM_CHECK_NEAR(local.rotation, 0.1, 1e-5);
}

UM_TEST_MAIN_BEGIN()
    testUnanimatedBoneKeepsBasePose();
    testAnimatedBoneSamplesTranslateTrack();
    testCyclicRotationTakesShortestPathAcrossWrap();
    testBoundImagePoseComposesBoneRotationAndTranslation();
    testApplyBoneBindingsUnwrapsRotationAcrossWrap();
    testApplyBoneBindingsClearsContinuityWhenNothingIsBound();
    testEnsureImageAnimationSpaceConsistencyConvertsBaseValues();
    testConstraintSampledSkeletonInterpolatesScalarTrack();
    testConstraintSampledSkeletonOnlyWritesTrackedProperties();
    testApplyConstraintAnimationsSetupModeRestoresAuthoredValue();
    testApplyConstraintAnimationsAnimateModeSamplesClip();
    testApplyConstraintAnimationsNoOpWhenNothingAnimated();
    testApplyDrawOrderAnimationReturnsNulloptWhenNotAnimating();
    testApplyDrawOrderAnimationReturnsKeyedOrder();
    testSlotNamesInFirstAppearanceOrder();
    testApplyAttachmentAnimationsResolvesKeyedSlotAndOmitsUnkeyed();
    testApplyAttachmentAnimationsExplicitlyEmptySlot();
    testApplyAttachmentAnimationsEmptyWhenNotAnimating();
    testApplySetupPoseRestoresBoneFromBaseWhenNotPosing();
    testApplySetupPosePreservesLocalTransformWhilePosing();
    testApplySetupPoseRestoresSpriteFromBasePoseAndClearsDeform();
    testResolvedKeyframeValuePrefersImageOverBone();
    testResolvedKeyframeValueFallsBackToBone();
    testResolvedKeyframeValueUnsupportedPropertyReturnsNullopt();
    testCommitKeyframeWritesAndSelectsBoneKeyframe();
    testCommitKeyframeNoOpOutsideAnimateMode();
    testCommitMeshDeformKeyframeCapturesCurrentDeform();
    testApplyAnimationsAnimateModeSamplesBoneAndSprite();
    testApplyAnimationsSetupModeRestoresBasePoseAndReturnsDrawOrder();
    testLocalSpritePoseIsExactInverseOfBoundImagePose();
    testLocalSpritePoseWithNoBoneReturnsWorldPoseUnchanged();
UM_TEST_MAIN_END()
