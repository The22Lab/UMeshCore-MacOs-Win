// Tests for AnimationCurve.h / Keyframe.h / AnimationClip.h, ported from
// `Data/AnimationCurve.swift` / `Data/Keyframe.swift` / `Data/AnimationClip.swift`.
//
// The SlotAnimationTarget::id golden values below are cross-checked against
// an INDEPENDENT Python re-implementation of the documented FNV-1a +
// finalizer algorithm (not against the real Swift binary, which cannot run
// in this environment) -- they catch a C++ transcription bug, but a true
// Swift-parity golden-diff still needs to happen on a Mac toolchain per the
// project's golden_dump testing strategy.

#include <cmath>

#include "umeshcore/Animation/AnimationClip.h"
#include "umeshcore/Animation/AnimationCurve.h"
#include "umeshcore/Animation/Keyframe.h"
#include "umeshcore/Math/Angle.h"
#include "TestHarness.h"

using namespace umeshcore;

static void testKeyframeSpanBinarySearch() {
    std::vector<Keyframe> kfs;
    kfs.push_back(Keyframe(0, ScalarValue{0.0f}));
    kfs.push_back(Keyframe(10, ScalarValue{1.0f}));
    kfs.push_back(Keyframe(20, ScalarValue{2.0f}));

    {
        auto span = AnimationClip::keyframeSpan(kfs, 10.0f);
        UM_CHECK(span.exact.has_value() && *span.exact == 1);
        UM_CHECK(span.previous.has_value() && *span.previous == 0);
        UM_CHECK(span.next.has_value() && *span.next == 2);
    }
    {
        auto span = AnimationClip::keyframeSpan(kfs, 5.0f);
        UM_CHECK(!span.exact.has_value());
        UM_CHECK(span.previous.has_value() && *span.previous == 0);
        UM_CHECK(span.next.has_value() && *span.next == 1);
    }
    {
        auto span = AnimationClip::keyframeSpan(kfs, -5.0f);
        UM_CHECK(!span.exact.has_value());
        UM_CHECK(!span.previous.has_value());
        UM_CHECK(span.next.has_value() && *span.next == 0);
    }
    {
        auto span = AnimationClip::keyframeSpan(kfs, 100.0f);
        UM_CHECK(!span.exact.has_value());
        UM_CHECK(span.previous.has_value() && *span.previous == 2);
        UM_CHECK(!span.next.has_value());
    }
}

static void testAnimationCurveEndpoints() {
    using namespace AnimationCurve;
    const Segment seg = segment(
        FrameSample{0, 0.0f}, FrameSample{10, 100.0f}, std::nullopt, std::nullopt, std::nullopt,
        std::nullopt);
    UM_CHECK_NEAR(valueAtTime(seg, 0.0f), 0.0, 1e-3);
    UM_CHECK_NEAR(valueAtTime(seg, 10.0f), 100.0, 1e-3);
}

static void testAutoSlopeExtremumClamp() {
    // Keys of 0, 10, 9: the middle key is a local maximum (rising then
    // falling), so its auto slope must be exactly 0 -- this is the "no
    // overshoot past a peak" behavior the Swift header comment documents.
    const float slope = AnimationCurve::autoSlope(
        AnimationCurve::FrameSample{0, 0.0f}, AnimationCurve::FrameSample{5, 10.0f},
        AnimationCurve::FrameSample{10, 9.0f});
    UM_CHECK_NEAR(slope, 0.0, 1e-6);
}

static void testAutoSlopeMidRun() {
    // A key in the middle of a monotonic run keeps the Catmull-Rom slope:
    // (next.value - previous.value) / (next.x - previous.x).
    const float slope = AnimationCurve::autoSlope(
        AnimationCurve::FrameSample{0, 0.0f}, AnimationCurve::FrameSample{5, 5.0f},
        AnimationCurve::FrameSample{10, 20.0f});
    UM_CHECK_NEAR(slope, (20.0 - 0.0) / (10.0 - 0.0), 1e-6);
}

static void testBezierNoOvershootAtExtremum() {
    // Full round-trip: three keyframes 0/10/9 at frames 0/5/10, auto
    // tangents. Sampling densely between frame 0 and 5 must never exceed
    // 10 (the peak value) -- this is the concrete regression the extremum
    // clamp exists to prevent (measured in the Swift source at 100.65
    // against a keyframe of 100 before the fix).
    const auto before = AnimationCurve::FrameSample{0, 0.0f};
    const auto after = AnimationCurve::FrameSample{10, 9.0f};
    const AnimationCurve::Segment seg = AnimationCurve::segment(
        AnimationCurve::FrameSample{0, 0.0f}, AnimationCurve::FrameSample{5, 10.0f}, std::nullopt,
        std::nullopt, std::nullopt, after);
    for (int i = 0; i <= 50; ++i) {
        const float t = static_cast<float>(i) / 50.0f * 5.0f;
        const float v = AnimationCurve::valueAtTime(seg, t);
        UM_CHECK(v <= 10.0f + 1e-3f);
    }
    (void)before;
}

static void testSlotAnimationTargetIdGolden() {
    struct Case { const char* name; std::uint64_t hi; std::uint64_t lo; };
    const Case cases[] = {
        {"test_slot", 0x68127f0737c940caULL, 0xc209993e1e687e0cULL},
        {"head", 0x0a8f12cc5f9a0c03ULL, 0x7c5a2430e7aedb86ULL},
        {"", 0xcbf29ce484222325ULL, 0x7ec5ecd64ef08f1bULL},
    };
    for (const auto& c : cases) {
        const Uuid id = SlotAnimationTarget::id(c.name);
        UM_CHECK(id.hi == c.hi);
        UM_CHECK(id.lo == c.lo);
    }
    // Determinism + distinctness.
    UM_CHECK(SlotAnimationTarget::id("a") == SlotAnimationTarget::id("a"));
    UM_CHECK(SlotAnimationTarget::id("a") != SlotAnimationTarget::id("b"));
}

static void testSceneAnimationTargetFixedIds() {
    UM_CHECK(SceneAnimationTarget::drawOrder() == SceneAnimationTarget::drawOrder());
    UM_CHECK(SceneAnimationTarget::drawOrder() != SceneAnimationTarget::camera());
}

static void testAnimationClipLinearInterpolation() {
    AnimationClip clip("test");
    const Uuid bone = Uuid::generate();
    clip.upsertKeyframe(bone, AnimationTrackProperty::Rotate, 0, RotateValue{0.0f});
    clip.upsertKeyframe(bone, AnimationTrackProperty::Rotate, 10, RotateValue{100.0f});

    UM_CHECK_NEAR(clip.evaluatedScalar(bone, AnimationTrackProperty::Rotate, 0, 0.0f), 0.0, 1e-4);
    UM_CHECK_NEAR(clip.evaluatedScalar(bone, AnimationTrackProperty::Rotate, 5, 0.0f), 50.0, 1e-3);
    UM_CHECK_NEAR(clip.evaluatedScalar(bone, AnimationTrackProperty::Rotate, 10, 0.0f), 100.0, 1e-4);
    // Past the last key: holds the last value (no track beyond it).
    UM_CHECK_NEAR(clip.evaluatedScalar(bone, AnimationTrackProperty::Rotate, 20, 0.0f), 100.0, 1e-4);
}

static void testAnimationClipCyclicRotationShortPath() {
    // A bone swung from 179 deg to -179 deg (2 degrees of motion) must be
    // sampled the SHORT way, not by unwinding 358 degrees the long way
    // around -- this is the documented 359->0 failure the `cyclic` flag
    // fixes.
    AnimationClip clip("test");
    const Uuid bone = Uuid::generate();
    const float deg179 = 179.0f * kPi / 180.0f;
    const float degNeg179 = -179.0f * kPi / 180.0f;
    clip.upsertKeyframe(bone, AnimationTrackProperty::Rotate, 0, RotateValue{deg179});
    clip.upsertKeyframe(bone, AnimationTrackProperty::Rotate, 10, RotateValue{degNeg179});

    SceneImageAnimationPose basePose;
    const auto poseAtHalf = clip.poseAtTime(bone, basePose, 5.0f, /*cyclicRotation=*/true);
    // Halfway through the short 2-degree path from 179 should be ~180 deg
    // (== -180 deg), not ~0 deg (which is what the long way around would
    // give at the midpoint).
    const float expected = 180.0f * kPi / 180.0f;
    float delta = std::abs(shortestAngleDelta(poseAtHalf.rotation, expected));
    UM_CHECK(delta < 0.05f);
}

static void testAnimationClipHoldInterpolation() {
    AnimationClip clip("test");
    const Uuid bone = Uuid::generate();
    clip.upsertKeyframe(
        bone, AnimationTrackProperty::Rotate, 0, RotateValue{5.0f}, KeyframeInterpolation::Hold);
    clip.upsertKeyframe(bone, AnimationTrackProperty::Rotate, 10, RotateValue{50.0f});
    UM_CHECK_NEAR(clip.evaluatedScalar(bone, AnimationTrackProperty::Rotate, 5, 0.0f), 5.0, 1e-4);
}

static void testAnimationClipFlagAlwaysStepped() {
    AnimationClip clip("test");
    const Uuid constraintId = Uuid::generate();
    clip.upsertKeyframe(constraintId, AnimationTrackProperty::IkBendPositive, 0, FlagValue{true});
    clip.upsertKeyframe(constraintId, AnimationTrackProperty::IkBendPositive, 10, FlagValue{false});
    UM_CHECK(clip.evaluatedFlag(constraintId, AnimationTrackProperty::IkBendPositive, 0, false) == true);
    UM_CHECK(clip.evaluatedFlag(constraintId, AnimationTrackProperty::IkBendPositive, 5, false) == true);
    UM_CHECK(clip.evaluatedFlag(constraintId, AnimationTrackProperty::IkBendPositive, 10, false) == false);
}

static void testAnimationClipTrackIndexTracking() {
    AnimationClip clip("test");
    const Uuid bone = Uuid::generate();
    UM_CHECK(!clip.hasTrack(bone, AnimationTrackProperty::Translate));
    clip.upsertKeyframe(bone, AnimationTrackProperty::Translate, 0, TranslateValue{Vec2(1, 2)});
    UM_CHECK(clip.hasTrack(bone, AnimationTrackProperty::Translate));
    UM_CHECK(clip.animatedTargetIDs().contains(bone));

    clip.deleteKeyframes(
        bone, AnimationTrackProperty::Translate,
        std::unordered_set<Uuid, UuidHash>{clip.keyframesFor(bone, AnimationTrackProperty::Translate)[0].id});
    UM_CHECK(!clip.hasTrack(bone, AnimationTrackProperty::Translate));
    UM_CHECK(clip.tracks().empty());
}

static void testAnimationClipMeshDeformMix() {
    AnimationClip clip("test");
    const Uuid sprite = Uuid::generate();
    clip.upsertKeyframe(
        sprite, AnimationTrackProperty::MeshDeform, 0,
        MeshDeformValue{{Vec2(0, 0), Vec2(1, 1)}});
    clip.upsertKeyframe(
        sprite, AnimationTrackProperty::MeshDeform, 10,
        MeshDeformValue{{Vec2(10, 0), Vec2(1, 11)}});
    const auto mid = clip.evaluatedMeshDeform(sprite, 5, {});
    UM_CHECK(mid.size() == 2);
    UM_CHECK_NEAR(mid[0].x, 5.0, 1e-3);
    UM_CHECK_NEAR(mid[1].y, 6.0, 1e-3);
}

UM_TEST_MAIN_BEGIN()
    testKeyframeSpanBinarySearch();
    testAnimationCurveEndpoints();
    testAutoSlopeExtremumClamp();
    testAutoSlopeMidRun();
    testBezierNoOvershootAtExtremum();
    testSlotAnimationTargetIdGolden();
    testSceneAnimationTargetFixedIds();
    testAnimationClipLinearInterpolation();
    testAnimationClipCyclicRotationShortPath();
    testAnimationClipHoldInterpolation();
    testAnimationClipFlagAlwaysStepped();
    testAnimationClipTrackIndexTracking();
    testAnimationClipMeshDeformMix();
UM_TEST_MAIN_END()
