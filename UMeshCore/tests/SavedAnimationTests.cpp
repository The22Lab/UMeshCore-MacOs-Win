// Tests for Serialization/SavedAnimation.h -- JSON conversions for the
// animation slice of `Data/ProjectPersistence.swift` (`SavedAnimationClip`,
// `SavedAnimationTrack`, `SavedKeyframe`, `SavedKeyframeValue`,
// `SavedAnimationEvent`, `SavedConstraintSetupValues`). Expected values and
// fallback behavior are hand-derived from that file's `restoredValue()`/
// `restoredKeyframe()`/`restoredAnimationTrack()` implementations, which
// were read directly -- not from this port's own output.

#include "umeshcore/Serialization/SavedAnimation.h"

#include "umeshcore/Serialization/SavedSkeleton.h"
#include "TestHarness.h"

using namespace umeshcore;

static void testTrackPropertyNamesMatchSwiftRawValues() {
    // Spot-checks against the Swift enum's case names (its rawValues).
    UM_CHECK(std::string(trackPropertyName(AnimationTrackProperty::Translate)) == "translate");
    UM_CHECK(std::string(trackPropertyName(AnimationTrackProperty::MeshDeform)) == "meshDeform");
    UM_CHECK(std::string(trackPropertyName(AnimationTrackProperty::IkBendPositive)) == "ikBendPositive");
    UM_CHECK(std::string(trackPropertyName(AnimationTrackProperty::CameraFOV)) == "cameraFOV");
    UM_CHECK(std::string(trackPropertyName(AnimationTrackProperty::LightColorB)) == "lightColorB");
    UM_CHECK(std::string(trackPropertyName(AnimationTrackProperty::DrawOrder)) == "drawOrder");
    UM_CHECK(std::string(trackPropertyName(AnimationTrackProperty::Attachment)) == "attachment");

    // Every real case round-trips name -> enum -> name.
    for (AnimationTrackProperty p : allAnimationTrackProperties()) {
        UM_CHECK(trackPropertyFromName(trackPropertyName(p)) == p);
    }
}

static void testUnknownPropertyAndInterpolationNamesFallBack() {
    UM_CHECK(trackPropertyFromName("someFutureProperty") == AnimationTrackProperty::Translate);
    UM_CHECK(interpolationFromName("someFutureCurve") == KeyframeInterpolation::Linear);
    UM_CHECK(interpolationFromName("hold") == KeyframeInterpolation::Hold);
    UM_CHECK(interpolationFromName("bezier") == KeyframeInterpolation::Bezier);
}

static void testEveryKeyframeValueKindRoundTrips() {
    const Uuid a = Uuid::generate();
    const Uuid b = Uuid::generate();

    const KeyframeValue values[] = {
        TranslateValue{Vec2(1, 2)},
        RotateValue{0.5f},
        ScaleValue{Vec2(2, 3)},
        ShearValue{Vec2(0.1f, 0.2f)},
        MeshDeformValue{{Vec2(1, 1), Vec2(-1, -1)}},
        ScalarValue{7.5f},
        FlagValue{true},
        Vector2Value{Vec2(4, 5)},
        DrawOrderValue{{a, b}},
        AttachmentValue{a},
        EventValue{AnimationEventPayload{42, std::nullopt, std::string("boom")}},
    };

    for (const KeyframeValue& value : values) {
        const KeyframeValue back = keyframeValueFromJson(toJson(value));
        UM_CHECK(kind(back) == kind(value));
        UM_CHECK(back == value);
    }
}

static void testAttachmentEmptySlotSurvivesAsEmptyArray() {
    // A deliberately empty slot is an empty id array, NOT an absent field
    // or a null -- the two statements must stay distinguishable.
    const KeyframeValue empty = AttachmentValue{std::nullopt};
    const JsonValue j = toJson(empty);
    UM_CHECK(j.find("idArray") != nullptr);
    UM_CHECK(j.find("idArray")->asArray().empty());

    const KeyframeValue back = keyframeValueFromJson(j);
    const AttachmentValue* attachment = std::get_if<AttachmentValue>(&back);
    UM_CHECK(attachment != nullptr && !attachment->value.has_value());
}

static void testEventPayloadKeepsFieldsIndependentlyOptional() {
    // "Not set" means "inherit the event definition's default" and must NOT
    // come back as 0 / "".
    const KeyframeValue value = EventValue{AnimationEventPayload{std::nullopt, 1.5f, std::nullopt}};
    const JsonValue j = toJson(value);
    UM_CHECK(j.find("eventInt") == nullptr);
    UM_CHECK(j.find("eventFloat") != nullptr);
    UM_CHECK(j.find("eventString") == nullptr);

    const KeyframeValue back = keyframeValueFromJson(j);
    const EventValue* event = std::get_if<EventValue>(&back);
    UM_CHECK(event != nullptr);
    UM_CHECK(!event->value.intValue.has_value());
    UM_CHECK(event->value.floatValue.has_value());
    UM_CHECK_NEAR(*event->value.floatValue, 1.5, 1e-6);
    UM_CHECK(!event->value.stringValue.has_value());
}

static void testScaleFallsBackToUniformScalarThenToOne() {
    // Old files wrote a uniform scale as a single `scalar`.
    const KeyframeValue fromScalar = keyframeValueFromJson(JsonValue::parse("{\"kind\":\"scale\",\"scalar\":2.5}"));
    const ScaleValue* scaled = std::get_if<ScaleValue>(&fromScalar);
    UM_CHECK(scaled != nullptr);
    UM_CHECK_NEAR(scaled->value.x, 2.5, 1e-6);
    UM_CHECK_NEAR(scaled->value.y, 2.5, 1e-6);

    // Neither vector2 nor scalar: the neutral scale is 1, not 0.
    const KeyframeValue bare = keyframeValueFromJson(JsonValue::parse("{\"kind\":\"scale\"}"));
    const ScaleValue* neutral = std::get_if<ScaleValue>(&bare);
    UM_CHECK(neutral != nullptr);
    UM_CHECK_NEAR(neutral->value.x, 1.0, 1e-6);
}

static void testUnknownKindFallsBackToTranslateZero() {
    const KeyframeValue back = keyframeValueFromJson(JsonValue::parse("{\"kind\":\"someFutureKind\"}"));
    const TranslateValue* translate = std::get_if<TranslateValue>(&back);
    UM_CHECK(translate != nullptr);
    UM_CHECK(translate->value == Vec2::zero());
}

static void testKeyframeRoundTripWithTangents() {
    Keyframe kf(
        12, TranslateValue{Vec2(3, 4)}, KeyframeInterpolation::Bezier, Vec2(0.1f, 0.2f), Vec2(0.3f, 0.4f),
        Vec2(0.5f, 0.6f), Vec2(0.7f, 0.8f));
    const Keyframe back = keyframeFromJson(toJson(kf));

    UM_CHECK(back.id == kf.id);
    UM_CHECK(back.frame == 12);
    UM_CHECK(back.interpolation == KeyframeInterpolation::Bezier);
    UM_CHECK(back.inTangent.has_value() && back.outTangent.has_value());
    UM_CHECK_NEAR(back.inTangent->x, 0.1, 1e-6);
    UM_CHECK(back.secondaryOutTangent.has_value());
    UM_CHECK_NEAR(back.secondaryOutTangent->y, 0.8, 1e-6);
    UM_CHECK(back.value == kf.value);
}

static void testKeyframeWithoutTangentsOmitsThem() {
    const Keyframe kf(5, ScalarValue{1.0f});
    const JsonValue j = toJson(kf);
    UM_CHECK(j.find("inTangent") == nullptr);
    UM_CHECK(j.find("secondaryOutTangent") == nullptr);

    const Keyframe back = keyframeFromJson(j);
    UM_CHECK(!back.inTangent.has_value());
    UM_CHECK(!back.secondaryInTangent.has_value());
}

static void testSteppedPayloadsStayHoldThroughTheRoundTrip() {
    // Keyframe's constructor forces Hold for flag/drawOrder/event/attachment
    // payloads; reading back through that same constructor must preserve it
    // even if the file claims otherwise.
    const Keyframe back =
        keyframeFromJson(JsonValue::parse("{\"id\":\"" + Uuid::generate().toString() +
                                          "\",\"frame\":3,\"interpolation\":\"bezier\"," +
                                          "\"value\":{\"kind\":\"flag\",\"flag\":true}}"));
    UM_CHECK(back.interpolation == KeyframeInterpolation::Hold);
}

static void testAnimationTrackAndClipRoundTrip() {
    const Uuid targetID = Uuid::generate();
    AnimationTrack track(
        targetID, AnimationTrackProperty::Rotate,
        {Keyframe(0, RotateValue{0.0f}), Keyframe(10, RotateValue{1.5f})});

    AnimationClip clip("Walk", 24, {track});
    const AnimationClip back = animationClipFromJson(toJson(clip));

    UM_CHECK(back.id == clip.id);
    UM_CHECK(back.name == "Walk");
    UM_CHECK(back.durationInFrames == 24);
    UM_CHECK(back.tracks().size() == 1);
    UM_CHECK(back.tracks()[0].id == track.id);
    UM_CHECK(back.tracks()[0].targetID == targetID);
    UM_CHECK(back.tracks()[0].property == AnimationTrackProperty::Rotate);
    UM_CHECK(back.tracks()[0].keyframes.size() == 2);
    UM_CHECK(back.tracks()[0].keyframes[1].frame == 10);
}

static void testAnimationEventRoundTrip() {
    AnimationEvent event;
    event.name = "footstep";
    event.defaultInt = 3;
    event.defaultFloat = 0.75f;
    event.defaultString = "left";
    event.audioPath = "sfx/step.wav";
    event.volume = 0.8f;
    event.balance = -0.25f;

    const AnimationEvent back = animationEventFromJson(toJson(event));
    UM_CHECK(back == event);
}

static void testConstraintSetupValuesRoundTrip() {
    const Uuid constraintID = Uuid::generate();
    ConstraintSetupValues values;
    values.set(AnimationTrackProperty::ConstraintMix, 0.5f);
    values.set(AnimationTrackProperty::IkSoftness, 12.0f);
    values.set(AnimationTrackProperty::IkBendPositive, false);
    values.set(AnimationTrackProperty::PhysicsWind, Vec2(3, 4));

    const JsonValue j = constraintSetupValuesToJson(constraintID, values);
    UM_CHECK(constraintSetupValuesIDFromJson(j) == constraintID);
    // Property names on the wire are Swift's rawValue spellings.
    UM_CHECK(j.find("scalars")->find("constraintMix") != nullptr);
    UM_CHECK(j.find("flags")->find("ikBendPositive") != nullptr);
    UM_CHECK(j.find("vectors")->find("physicsWind") != nullptr);

    const ConstraintSetupValues back = constraintSetupValuesFromJson(j);
    UM_CHECK(back == values);
}

static void testBoneNowCarriesItsAnimationClip() {
    // The deferral noted in SavedSkeleton.h's earlier revision is closed:
    // a bone's clip round-trips, and a bone with no tracks writes no clip.
    Bone bone;
    bone.name = "arm";
    bone.animationClip = AnimationClip(
        "arm", 30,
        {AnimationTrack(bone.id, AnimationTrackProperty::Translate, {Keyframe(4, TranslateValue{Vec2(9, 9)})})});

    const JsonValue j = toJson(bone);
    UM_CHECK(j.find("animationClip") != nullptr);

    const Bone back = boneFromJson(j);
    UM_CHECK(back.animationClip.tracks().size() == 1);
    UM_CHECK(back.animationClip.durationInFrames == 30);
    UM_CHECK(back.animationClip.tracks()[0].keyframes[0].frame == 4);

    Bone bare;
    bare.name = "leg";
    const JsonValue bareJson = toJson(bare);
    UM_CHECK(bareJson.find("animationClip") == nullptr);
    const Bone bareBack = boneFromJson(bareJson);
    UM_CHECK(bareBack.animationClip.tracks().empty());
    UM_CHECK(bareBack.animationClip.name == "leg"); // AnimationClip(name: bone.name) fallback.
}

UM_TEST_MAIN_BEGIN()
    testTrackPropertyNamesMatchSwiftRawValues();
    testUnknownPropertyAndInterpolationNamesFallBack();
    testEveryKeyframeValueKindRoundTrips();
    testAttachmentEmptySlotSurvivesAsEmptyArray();
    testEventPayloadKeepsFieldsIndependentlyOptional();
    testScaleFallsBackToUniformScalarThenToOne();
    testUnknownKindFallsBackToTranslateZero();
    testKeyframeRoundTripWithTangents();
    testKeyframeWithoutTangentsOmitsThem();
    testSteppedPayloadsStayHoldThroughTheRoundTrip();
    testAnimationTrackAndClipRoundTrip();
    testAnimationEventRoundTrip();
    testConstraintSetupValuesRoundTrip();
    testBoneNowCarriesItsAnimationClip();
UM_TEST_MAIN_END()
