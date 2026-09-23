// Tests for Interop/SwiftBridge.h -- the flat forms that let Swift read and
// build the three variants without any variant crossing the boundary.
//
// The one promise the pair makes is that `fromFlat(toFlat(v)) == v` for
// every case. The tests that matter beyond that are the ones a flat form
// can get wrong without failing a round trip on a single case: four cases
// share a `Vec2` payload and must not collapse into one, and an attachment
// key that deliberately shows NOTHING must not come back as "no value".

#include "umeshcore/Interop/SwiftBridge.h"

#include "TestHarness.h"

using namespace umeshcore;

static void testEveryKeyframeCaseRoundTrips() {
    AnimationEventPayload payload;
    payload.intValue = 7;
    payload.stringValue = std::string("step");

    const Uuid a(1, 2), b(3, 4);
    const std::vector<KeyframeValue> values = {
        TranslateValue{Vec2(1, 2)},
        RotateValue{0.5f},
        ScaleValue{Vec2(3, 4)},
        ShearValue{Vec2(0.1f, -0.2f)},
        MeshDeformValue{{Vec2(1, 1), Vec2(-2, 3)}},
        ScalarValue{0.25f},
        FlagValue{true},
        Vector2Value{Vec2(5, 6)},
        DrawOrderValue{{a, b}},
        EventValue{payload},
        AttachmentValue{a},
        AttachmentValue{std::nullopt},
    };
    // Guard: the list above covers every alternative of the variant.
    UM_CHECK(std::variant_size_v<KeyframeValue> == 11);

    for (const KeyframeValue& v : values) UM_CHECK(fromFlat(toFlat(v)) == v);
}

static void testCasesThatShareAPayloadStayDistinct() {
    // Four cases carry a bare Vec2. A flat form keyed on the payload type
    // would turn a translate key into a scale key without failing a single
    // same-case round trip.
    const Vec2 p(2, 3);
    UM_CHECK(toFlat(KeyframeValue{TranslateValue{p}}).kind == KeyframeValueCase::Translate);
    UM_CHECK(toFlat(KeyframeValue{ScaleValue{p}}).kind == KeyframeValueCase::Scale);
    UM_CHECK(toFlat(KeyframeValue{ShearValue{p}}).kind == KeyframeValueCase::Shear);
    UM_CHECK(toFlat(KeyframeValue{Vector2Value{p}}).kind == KeyframeValueCase::Vector2);
    UM_CHECK(!(fromFlat(toFlat(KeyframeValue{TranslateValue{p}})) == KeyframeValue{ScaleValue{p}}));

    // Rotate and Scalar share a float the same way.
    UM_CHECK(toFlat(KeyframeValue{RotateValue{1}}).kind == KeyframeValueCase::Rotate);
    UM_CHECK(toFlat(KeyframeValue{ScalarValue{1}}).kind == KeyframeValueCase::Scalar);
}

static void testAnEmptyAttachmentIsAValueNotAnAbsence() {
    // "Show nothing in this slot" is a real key -- it overrides the skin --
    // and it must survive the trip as exactly that.
    const FlatKeyframeValue empty = toFlat(KeyframeValue{AttachmentValue{std::nullopt}});
    UM_CHECK(empty.kind == KeyframeValueCase::Attachment);
    UM_CHECK(!empty.hasAttachment);
    const KeyframeValue back = fromFlat(empty);
    const auto* attachment = std::get_if<AttachmentValue>(&back);
    UM_CHECK(attachment != nullptr && !attachment->value.has_value());
}

static void testSteppedKindsAreAlwaysHold() {
    // Swift's rule, which the Keyframe constructor already applies: a key
    // that cannot tween is Hold whatever the caller asked for. Both ways
    // in from Swift keep it.
    FlatKeyframeValue flag;
    flag.kind = KeyframeValueCase::Flag;
    flag.flag = true;
    const Keyframe made = makeKeyframe(Uuid(9, 9), 12, flag, KeyframeInterpolation::Linear);
    UM_CHECK(made.interpolation == KeyframeInterpolation::Hold);
    UM_CHECK(made.frame == 12 && made.id == Uuid(9, 9));

    Keyframe k(4, ScalarValue{1.0f}, KeyframeInterpolation::Linear);
    UM_CHECK(k.interpolation == KeyframeInterpolation::Linear);
    setFlatKeyframeValue(k, flag);
    UM_CHECK(k.interpolation == KeyframeInterpolation::Hold);
    UM_CHECK(flatKeyframeValue(k).flag);

    // A tweenable kind keeps the interpolation it was given.
    FlatKeyframeValue scalar;
    scalar.kind = KeyframeValueCase::Scalar;
    scalar.scalar = 2.0f;
    const Keyframe tween = makeKeyframe(Uuid(1, 1), 0, scalar, KeyframeInterpolation::Bezier);
    UM_CHECK(tween.interpolation == KeyframeInterpolation::Bezier);
}

static void testLayerContentRoundTrips() {
    SceneRigContent rig;
    rig.clipId = Uuid(5, 6);
    rig.speed = 0.5f;
    rig.startFrame = 12;
    rig.loops = false;
    const std::vector<SceneLayerContent> contents = {
        rig, ScenePlateContent{Uuid(7, 8)}, SceneFillContent{SceneFill::neutral()}};
    UM_CHECK(std::variant_size_v<SceneLayerContent> == 3);
    for (const SceneLayerContent& c : contents) UM_CHECK(fromFlat(toFlat(c)) == c);

    SceneLayer layer;
    layer.content = rig;
    UM_CHECK(flatLayerContent(layer).kind == SceneLayerContentCase::Rig);
    FlatSceneLayerContent plate;
    plate.kind = SceneLayerContentCase::Plate;
    plate.plateAssetId = Uuid(7, 8);
    setFlatLayerContent(layer, plate);
    UM_CHECK(layer.content == SceneLayerContent{ScenePlateContent{Uuid(7, 8)}});
}

static void testGizmoHandlesRoundTrip() {
    const std::vector<GizmoHandle> handles = {
        GizmoHandleFactory::moveCenter(),     GizmoHandleFactory::moveX(),
        GizmoHandleFactory::moveY(),          GizmoHandleFactory::bone(Uuid(3, 3)),
        GizmoHandleFactory::meshVertex(4),    GizmoHandleFactory::meshInternalEdge(5),
        GizmoHandleFactory::rotateRing(),     GizmoHandleFactory::scaleCorner(2),
        GizmoHandleFactory::skewEdge(1)};
    UM_CHECK(std::variant_size_v<GizmoHandle> == 9);
    for (const GizmoHandle& h : handles) UM_CHECK(fromFlat(toFlat(h)) == h);
    // Index-carrying cases stay apart when their index agrees.
    UM_CHECK(toFlat(GizmoHandleFactory::meshVertex(2)).kind == GizmoHandleCase::MeshVertex);
    UM_CHECK(toFlat(GizmoHandleFactory::scaleCorner(2)).kind == GizmoHandleCase::ScaleCorner);
}

UM_TEST_MAIN_BEGIN()
    testEveryKeyframeCaseRoundTrips();
    testCasesThatShareAPayloadStayDistinct();
    testAnEmptyAttachmentIsAValueNotAnAbsence();
    testSteppedKindsAreAlwaysHold();
    testLayerContentRoundTrips();
    testGizmoHandlesRoundTrip();
UM_TEST_MAIN_END()
