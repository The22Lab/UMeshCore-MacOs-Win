// Tests for SceneAnimator.h, ported from `SceneManager.clipSampledBones`.
// Expected values are hand-derived from AnimationClip's own documented
// evaluation rules (already golden-tested in AnimationTests.cpp), not from
// this function's own output.

#include "umeshcore/Animation/SceneAnimator.h"
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

UM_TEST_MAIN_BEGIN()
    testUnanimatedBoneKeepsBasePose();
    testAnimatedBoneSamplesTranslateTrack();
    testCyclicRotationTakesShortestPathAcrossWrap();
UM_TEST_MAIN_END()
