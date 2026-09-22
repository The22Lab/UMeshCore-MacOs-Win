// Tests for SceneAnimator.h, ported from `SceneManager.clipSampledBones`,
// `applyBoneBindings`/`boundImagePose`, and
// `ensureImageAnimationSpaceConsistency`/`convertImageAnimationSpace`.
// Expected values are hand-derived from the matrix/decompose formulas
// already golden-tested in MathTests.cpp and AnimationTests.cpp, not from
// this file's own output.

#include "umeshcore/Animation/SceneAnimator.h"
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

UM_TEST_MAIN_BEGIN()
    testUnanimatedBoneKeepsBasePose();
    testAnimatedBoneSamplesTranslateTrack();
    testCyclicRotationTakesShortestPathAcrossWrap();
    testBoundImagePoseComposesBoneRotationAndTranslation();
    testApplyBoneBindingsUnwrapsRotationAcrossWrap();
    testApplyBoneBindingsClearsContinuityWhenNothingIsBound();
    testEnsureImageAnimationSpaceConsistencyConvertsBaseValues();
UM_TEST_MAIN_END()
