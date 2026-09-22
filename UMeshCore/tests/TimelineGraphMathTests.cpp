// Tests for Editor/TimelineGraphMath.h, the graph editor's math lifted out
// of the body of `TimelineView.swift`.
//
// The expected values are derived by hand from the Swift, and the first
// test is the one the whole file exists for: the graph must draw the curve
// that PLAYS. Its Swift header names three ways the graph's own geometry
// used to differ from the evaluator's, and each is a curve the artist was
// shown but never heard. Two of the three are reproduced here by building
// the broken answer alongside the ported one and showing them disagree --
// an assertion that only says "the port matches itself" would pass just as
// happily with the bug back in.

#include "umeshcore/Editor/TimelineGraphMath.h"

#include <cmath>
#include <vector>

#include "TestHarness.h"

using namespace umeshcore;
using namespace umeshcore::TimelineGraph;

namespace {

Sample bezierSample(int frame, float value) {
    Sample s;
    s.keyframeID = Uuid::generate();
    s.frame = frame;
    s.value = value;
    s.interpolation = KeyframeInterpolation::Bezier;
    return s;
}

// The largest value a cubic reaches, found by dense sampling. Used to
// MEASURE a curve rather than restate the formula that made it.
double peakOf(double p0, double p1, double p2, double p3) {
    double peak = -1e30;
    for (int i = 0; i <= 20000; ++i) {
        const double t = static_cast<double>(i) / 20000.0;
        peak = std::max(peak, GraphBounds::cubic(t, p0, p1, p2, p3));
    }
    return peak;
}

} // namespace

// An auto tangent at a turning point is FLAT, so the drawn curve cannot
// climb past the key it has just left. Swift measured the broken version at
// 100.65 against a key of 100; the numbers below are a different segment,
// so the figure differs -- the property does not.
static void testTheDrawnCurveDoesNotOvershootATurningPointKey() {
    // Up to 100, then down to 50: frame 10 is a local maximum.
    const std::vector<Sample> samples = {
        bezierSample(0, 0.0f), bezierSample(10, 100.0f), bezierSample(20, 50.0f)};

    const AnimationCurve::Segment segment = controlPoints(samples, 1);

    // The out-handle is flat: rising * falling <= 0 at the middle key.
    UM_CHECK_NEAR(segment.control1.y, 100.0f, 1e-4f);
    const double peak = peakOf(
        segment.start.y, segment.control1.y, segment.control2.y, segment.end.y);
    UM_CHECK(peak <= 100.0 + 1e-4);

    // The graph's own former answer: a plain central difference, no
    // turning-point clamp -- slope (50 - 0) / (20 - 0) = 2.5, over a third
    // of the ten-frame span.
    const double brokenControl1 = 100.0 + 2.5 * (10.0 / 3.0);
    const double brokenPeak = peakOf(
        100.0, brokenControl1, static_cast<double>(segment.control2.y), 50.0);
    // It climbs past a key that playback holds at exactly 100.
    UM_CHECK(brokenPeak > 100.5);
}

// A control point dragged past the next key is clamped INTO the segment.
// Without it x(t) stops being monotonic and one time maps to two values --
// the 90-unit S-bend the Swift header records.
static void testAControlPointIsClampedIntoItsSegment() {
    std::vector<Sample> samples = {bezierSample(0, 0.0f), bezierSample(10, 100.0f)};
    // Thirty frames of out-handle on a ten-frame segment.
    samples[0].outTangent = Vec2(30.0f, 0.0f);
    samples[1].inTangent = Vec2(-30.0f, 0.0f);

    const AnimationCurve::Segment segment = controlPoints(samples, 0);
    UM_CHECK_NEAR(segment.control1.x, 10.0f, 1e-5f);
    UM_CHECK_NEAR(segment.control2.x, 0.0f, 1e-5f);

    // x(t) is still monotonic, which is the property the clamp buys.
    double previous = -1e30;
    for (int i = 0; i <= 1000; ++i) {
        const double t = static_cast<double>(i) / 1000.0;
        const double x = GraphBounds::cubic(
            t, segment.start.x, segment.control1.x, segment.control2.x, segment.end.x);
        UM_CHECK(x >= previous - 1e-9);
        previous = x;
    }
}

// A key that is not a bezier key is not drawn with its stored out-tangent:
// the interpolation describes the segment, and a linear one is a line.
static void testOnlyABezierKeyIsDrawnWithItsStoredOutTangent() {
    std::vector<Sample> samples = {bezierSample(0, 0.0f), bezierSample(10, 100.0f)};
    samples[0].outTangent = Vec2(1.0f, 80.0f);
    const AnimationCurve::Segment bezier = controlPoints(samples, 0);
    UM_CHECK_NEAR(bezier.control1.y, 80.0f, 1e-5f);

    samples[0].interpolation = KeyframeInterpolation::Linear;
    const AnimationCurve::Segment linear = controlPoints(samples, 0);
    // Auto now: slope 10 per frame over a third of the span.
    UM_CHECK_NEAR(linear.control1.y, 100.0f / 3.0f, 1e-3f);
}

// The rule that decides which of a keyframe's TWO tangent pairs a channel
// owns. `constraint.flag` is the case that got it wrong the first time:
// neither `.x` nor `.scalar`, so it takes the secondary pair.
static void testTheChannelToTangentPairRuleIsOneRule() {
    UM_CHECK(usesPrimaryTangents("translate.x"));
    UM_CHECK(usesPrimaryTangents("constraintMix.scalar"));
    UM_CHECK(!usesPrimaryTangents("translate.y"));
    UM_CHECK(!usesPrimaryTangents("constraint.flag"));

    Keyframe keyframe(4, TranslateValue{Vec2(1.0f, 2.0f)}, KeyframeInterpolation::Bezier);
    keyframe.outTangent = Vec2(3.0f, 4.0f);
    keyframe.secondaryOutTangent = Vec2(5.0f, 6.0f);

    UM_CHECK(tangentFor(keyframe, "translate.x", HandleKind::Out)->y == 4.0f);
    UM_CHECK(tangentFor(keyframe, "translate.y", HandleKind::Out)->y == 6.0f);

    // And a sample built for a channel carries that channel's pair.
    UM_CHECK(sampleFor(keyframe, 1.0f, "translate.y").outTangent->y == 6.0f);
}

// A drag writes exactly ONE of the four tangent fields; the other three
// come back as they were, so a caller can write all four back blind.
static void testADragWritesExactlyOneOfTheFourTangentFields() {
    Keyframe keyframe(0, TranslateValue{Vec2(0.0f, 0.0f)}, KeyframeInterpolation::Bezier);
    keyframe.inTangent = Vec2(-1.0f, -1.0f);
    keyframe.outTangent = Vec2(1.0f, 1.0f);
    keyframe.secondaryInTangent = Vec2(-2.0f, -2.0f);
    keyframe.secondaryOutTangent = Vec2(2.0f, 2.0f);

    const Vec2 dragged(9.0f, 9.0f);

    // A y channel's out-handle: only the secondary out field moves.
    UM_CHECK(*updatedPrimaryInTangent(keyframe, "t.y", HandleKind::Out, dragged) ==
             Vec2(-1.0f, -1.0f));
    UM_CHECK(*updatedPrimaryOutTangent(keyframe, "t.y", HandleKind::Out, dragged) ==
             Vec2(1.0f, 1.0f));
    UM_CHECK(*updatedSecondaryInTangent(keyframe, "t.y", HandleKind::Out, dragged) ==
             Vec2(-2.0f, -2.0f));
    UM_CHECK(*updatedSecondaryOutTangent(keyframe, "t.y", HandleKind::Out, dragged) == dragged);

    // An x channel's in-handle: only the primary in field moves.
    UM_CHECK(*updatedPrimaryInTangent(keyframe, "t.x", HandleKind::In, dragged) == dragged);
    UM_CHECK(*updatedPrimaryOutTangent(keyframe, "t.x", HandleKind::In, dragged) ==
             Vec2(1.0f, 1.0f));
    UM_CHECK(*updatedSecondaryInTangent(keyframe, "t.x", HandleKind::In, dragged) ==
             Vec2(-2.0f, -2.0f));
    UM_CHECK(*updatedSecondaryOutTangent(keyframe, "t.x", HandleKind::In, dragged) ==
             Vec2(2.0f, 2.0f));
}

// A handle cannot be dragged across its own keyframe. Past it, x(t) is no
// longer monotonic, which is the same failure the control-point clamp
// guards -- this is the guard one step earlier, on the artist's hand.
static void testAHandleCannotCrossItsOwnKeyframe() {
    const GraphRange range{0.0, 100.0};
    // Dragging the out-handle 500 px LEFT on a 100 px / 100 frame graph.
    const Vec2 out = updatedTangent(
        defaultTangent(HandleKind::Out), -500.0, 0.0, HandleKind::Out, range, 100.0, 100.0, 100,
        false);
    UM_CHECK_NEAR(out.x, 0.1f, 1e-6f);

    const Vec2 in = updatedTangent(
        defaultTangent(HandleKind::In), 500.0, 0.0, HandleKind::In, range, 100.0, 100.0, 100,
        false);
    UM_CHECK_NEAR(in.x, -0.1f, 1e-6f);

    // Dragging DOWN raises nothing: screen y grows downward, value upward.
    const Vec2 down = updatedTangent(
        Vec2(4.0f, 0.0f), 0.0, 10.0, HandleKind::Out, range, 100.0, 100.0, 100, false);
    UM_CHECK_NEAR(down.y, -10.0f, 1e-4f);

    // Snap rounds the FRAME delta and leaves the value alone: an artist
    // snapping to frames still wants the value they dragged to.
    const Vec2 snapped = updatedTangent(
        Vec2(4.0f, 0.0f), 2.6, 10.0, HandleKind::Out, range, 100.0, 100.0, 100, true);
    UM_CHECK_NEAR(snapped.x, 7.0f, 1e-6f);
    UM_CHECK_NEAR(snapped.y, -10.0f, 1e-4f);
}

// The two axes are mapped by DIFFERENT rules on purpose: x is the clip
// fraction the ruler and the playhead share, y goes through the value
// range. Making x go through the viewport would slide the graph out of
// register with the frame numbers above it.
static void testTheTwoAxesAreMappedByDifferentRulesOnPurpose() {
    const GraphRange range{-1.0, 1.0};
    // x: half the clip is half the width, whatever the value range is.
    UM_CHECK_NEAR(xForFrame(30.0, 200.0, 60), 100.0, 1e-9);
    UM_CHECK_NEAR(xForFrame(30.0, 200.0, 120), 50.0, 1e-9);
    // A clip of zero frames still divides by one, not by nothing.
    UM_CHECK(std::isfinite(xForFrame(0.0, 200.0, 0)));

    // y: the range's midpoint is the middle of the graph, and the top of
    // the range is y = 0 because screen y grows downward.
    UM_CHECK_NEAR(yForValue(0.0f, range, 100.0), 50.0, 1e-9);
    UM_CHECK_NEAR(yForValue(1.0f, range, 100.0), 0.0, 1e-9);
    UM_CHECK_NEAR(yForValue(-1.0f, range, 100.0), 100.0, 1e-9);

    // And the drag conversion agrees with the mapping: moving a value by
    // `valueDelta(dy)` moves its pixel by dy.
    const double dy = 17.0;
    const float delta = valueDelta(dy, range, 100.0);
    UM_CHECK_NEAR(yForValue(0.0f - delta, range, 100.0) - yForValue(0.0f, range, 100.0), dy, 1e-6);
}

// A handle is drawn at its keyframe plus its tangent, and an untangented
// key still shows a handle -- four frames wide and flat -- so there is
// something to grab.
static void testAnUntangentedKeyStillHasAHandleToGrab() {
    Keyframe keyframe(10, ScalarValue{0.5f}, KeyframeInterpolation::Bezier);
    const GraphRange range{0.0, 1.0};

    const auto out = handlePoint(keyframe, 0.5f, "a.scalar", HandleKind::Out, 100.0, 100.0, 100, range);
    UM_CHECK(out.has_value());
    UM_CHECK_NEAR(out->x, 14.0, 1e-9);   // frame 10 + 4, over a 100-frame clip
    UM_CHECK_NEAR(out->y, 50.0, 1e-9);   // flat: still the key's value

    const auto in = handlePoint(keyframe, 0.5f, "a.scalar", HandleKind::In, 100.0, 100.0, 100, range);
    UM_CHECK_NEAR(in->x, 6.0, 1e-9);

    // No value on this channel, no handle -- not a handle at zero.
    UM_CHECK(!handlePoint(keyframe, std::nullopt, "a.scalar", HandleKind::Out, 100.0, 100.0, 100, range)
                  .has_value());
}

// Fitting the view to the keys crops the curve; fitting it to the curve
// does not. This is the same bug `GraphBounds` was built for, arriving from
// the graph's side.
static void testTheBoundsCoverTheCurveAndNotJustTheKeys() {
    std::vector<Sample> samples = {bezierSample(0, 0.0f), bezierSample(10, 0.0f)};
    // Two handles pulling hard in opposite directions: both keys are at
    // zero and the curve is nowhere near it.
    samples[0].outTangent = Vec2(3.0f, 60.0f);
    samples[1].inTangent = Vec2(-3.0f, 60.0f);

    const GraphBounds bounds = curveBounds(samples);
    UM_CHECK(bounds.isValid());
    UM_CHECK(bounds.maxValue() > 20.0);

    // And it really is where the curve goes: sample it.
    const AnimationCurve::Segment segment = controlPoints(samples, 0);
    const double peak = peakOf(
        segment.start.y, segment.control1.y, segment.control2.y, segment.end.y);
    UM_CHECK(bounds.maxValue() >= peak - 1e-6);

    // A linear pair has no overshoot to cover, so the bounds are the keys.
    std::vector<Sample> flat = {bezierSample(0, 0.0f), bezierSample(10, 5.0f)};
    flat[0].interpolation = KeyframeInterpolation::Linear;
    const GraphBounds flatBounds = curveBounds(flat);
    UM_CHECK_NEAR(flatBounds.maxValue(), 5.0, 1e-9);
}

// The keyframe picker in the track rows: within eleven pixels, nearest
// wins, and a tie keeps the earlier key.
static void testNearestKeyframeIsBoundedAndBreaksTiesForwards() {
    const std::vector<int> frames = {0, 10, 20};
    // Ten frames at 4 px each: keys at 5, 45 and 85 px.
    const double spacing = 4.0, zoom = 1.0, inset = 5.0;

    UM_CHECK(*nearestKeyframe(48.0, frames, spacing, zoom, inset) == 1u);
    UM_CHECK(*nearestKeyframe(85.0, frames, spacing, zoom, inset) == 2u);
    // Exactly halfway between two keys, twenty pixels from each: outside
    // the eleven-pixel radius, so nothing is grabbed. A picker that always
    // returned the nearest key would select one from anywhere in the track.
    UM_CHECK(!nearestKeyframe(25.0, frames, spacing, zoom, inset).has_value());

    // Halfway between two keys that ARE both in range: the earlier wins.
    const std::vector<int> close = {0, 5};
    UM_CHECK(*nearestKeyframe(15.0, close, spacing, zoom, inset) == 0u);
}

// The curve itself is grabbable along its whole length, and the hold
// segment's STEP is grabbable too -- it is drawn, so it can be hit.
static void testACurveIsGrabbableAlongItsLengthIncludingAHoldStep() {
    const GraphRange range{0.0, 100.0};
    const double grab = GraphMetrics::curveGrabPx(GraphMetrics::kPointerTouchScale) / 2.0;

    std::vector<Sample> samples = {bezierSample(0, 0.0f), bezierSample(50, 100.0f)};
    // A point ON the curve: sample it and hand it back.
    const AnimationCurve::Segment segment = controlPoints(samples, 0);
    const double t = 0.4;
    const Point onCurve{
        xForFrame(GraphBounds::cubic(t, segment.start.x, segment.control1.x, segment.control2.x,
                                     segment.end.x), 100.0, 100),
        yForValue(static_cast<float>(GraphBounds::cubic(
                      t, segment.start.y, segment.control1.y, segment.control2.y, segment.end.y)),
                  range, 100.0)};
    UM_CHECK(distanceToCurve(onCurve, samples, 0, 100.0, 100.0, 100, range) < grab);

    // And well off it is not grabbed.
    UM_CHECK(distanceToCurve({onCurve.x, onCurve.y + 40.0}, samples, 0, 100.0, 100.0, 100, range) >
             grab);

    // Hold: the value is held flat to the next key and then steps. A point
    // on the vertical leg is on the path.
    samples[0].interpolation = KeyframeInterpolation::Hold;
    const Point onStep{xForFrame(50.0, 100.0, 100), yForValue(50.0f, range, 100.0)};
    UM_CHECK(distanceToCurve(onStep, samples, 0, 100.0, 100.0, 100, range) < 1e-6);
    // And a point under the flat leg, at the held value, is on it too.
    const Point onFlat{xForFrame(25.0, 100.0, 100), yForValue(0.0f, range, 100.0)};
    UM_CHECK(distanceToCurve(onFlat, samples, 0, 100.0, 100.0, 100, range) < 1e-6);
    // The linear reading of the same two keys is NOT the same path: at the
    // midpoint it is fifty units above the held value.
    samples[0].interpolation = KeyframeInterpolation::Linear;
    UM_CHECK(distanceToCurve(onFlat, samples, 0, 100.0, 100.0, 100, range) > 20.0);
}

// Dragging one channel of a vector property leaves the other alone, and the
// scale floor is not cosmetic: a zero scale is a matrix that stops
// inverting, and skinning, picking and the gizmos all invert it.
static void testWritingOneChannelLeavesTheOtherAloneAndScaleHasAFloor() {
    const KeyframeValue existing = ScaleValue{Vec2(2.0f, 3.0f)};

    const KeyframeValue x =
        updatedKeyframeValue(AnimationTrackProperty::Scale, "scale.x", 7.0f, existing);
    UM_CHECK(*simd2Value(x) == Vec2(7.0f, 3.0f));

    const KeyframeValue y =
        updatedKeyframeValue(AnimationTrackProperty::Scale, "scale.y", 7.0f, existing);
    UM_CHECK(*simd2Value(y) == Vec2(2.0f, 7.0f));

    const KeyframeValue zero =
        updatedKeyframeValue(AnimationTrackProperty::Scale, "scale.x", 0.0f, existing);
    UM_CHECK_NEAR(simd2Value(zero)->x, 0.001f, 1e-9f);
    const KeyframeValue negative =
        updatedKeyframeValue(AnimationTrackProperty::Scale, "scale.x", -5.0f, existing);
    UM_CHECK_NEAR(simd2Value(negative)->x, 0.001f, 1e-9f);

    // Translate has no floor -- a sprite may sit at x = 0.
    const KeyframeValue translated = updatedKeyframeValue(
        AnimationTrackProperty::Translate, "translate.x", 0.0f,
        KeyframeValue{TranslateValue{Vec2(4.0f, 5.0f)}});
    UM_CHECK(*simd2Value(translated) == Vec2(0.0f, 5.0f));
}

// A property whose value has no in-between -- a deform, a draw order, an
// event, an attachment -- comes back UNCHANGED from a graph drag. There is
// no scalar in it to write, and inventing one would replace the artist's
// payload with an empty one.
static void testAPayloadPropertyIsNotOverwrittenByAScalarDrag() {
    const KeyframeValue deform = MeshDeformValue{{Vec2(1.0f, 2.0f), Vec2(3.0f, 4.0f)}};
    const KeyframeValue result =
        updatedKeyframeValue(AnimationTrackProperty::MeshDeform, "meshDeform", 9.0f, deform);
    UM_CHECK(meshDeformValue(result) != nullptr);
    UM_CHECK(meshDeformValue(result)->size() == 2u);

    const KeyframeValue order = DrawOrderValue{{Uuid::generate()}};
    const KeyframeValue orderResult =
        updatedKeyframeValue(AnimationTrackProperty::DrawOrder, "drawOrder", 9.0f, order);
    UM_CHECK(drawOrderValue(orderResult) != nullptr);
    UM_CHECK(drawOrderValue(orderResult)->size() == 1u);
}

// A keyframe the caller could not find does not refuse the edit: it builds
// a value of the property's own shape. A flag takes the halfway rule, and
// a scalar is clamped to the property's range on the way in.
static void testAMissingKeyframeBuildsTheProperty_sOwnShape() {
    const KeyframeValue translate = updatedKeyframeValue(
        AnimationTrackProperty::Translate, "translate.x", 3.0f, std::nullopt);
    UM_CHECK(*simd2Value(translate) == Vec2(3.0f, 0.0f));

    // Scale builds BOTH components from the one number -- a uniform scale
    // is the only honest guess when there is nothing to preserve.
    const KeyframeValue scale =
        updatedKeyframeValue(AnimationTrackProperty::Scale, "scale.x", 3.0f, std::nullopt);
    UM_CHECK(*simd2Value(scale) == Vec2(3.0f, 3.0f));

    const KeyframeValue rotate =
        updatedKeyframeValue(AnimationTrackProperty::Rotate, "rotate.scalar", 1.5f, std::nullopt);
    UM_CHECK(floatValue(rotate).has_value());

    // A mix is a fraction: dragging past one writes one, not past it.
    const KeyframeValue mix = updatedKeyframeValue(
        AnimationTrackProperty::ConstraintMix, "constraintMix.scalar", 4.0f, std::nullopt);
    UM_CHECK_NEAR(*floatValue(mix), clamped(AnimationTrackProperty::ConstraintMix, 4.0f), 1e-9f);
    UM_CHECK(*floatValue(mix) <= 1.0f);
}

UM_TEST_MAIN_BEGIN()
    testTheDrawnCurveDoesNotOvershootATurningPointKey();
    testAControlPointIsClampedIntoItsSegment();
    testOnlyABezierKeyIsDrawnWithItsStoredOutTangent();
    testTheChannelToTangentPairRuleIsOneRule();
    testADragWritesExactlyOneOfTheFourTangentFields();
    testAHandleCannotCrossItsOwnKeyframe();
    testTheTwoAxesAreMappedByDifferentRulesOnPurpose();
    testAnUntangentedKeyStillHasAHandleToGrab();
    testTheBoundsCoverTheCurveAndNotJustTheKeys();
    testNearestKeyframeIsBoundedAndBreaksTiesForwards();
    testACurveIsGrabbableAlongItsLengthIncludingAHoldStep();
    testWritingOneChannelLeavesTheOtherAloneAndScaleHasAFloor();
    testAPayloadPropertyIsNotOverwrittenByAScalarDrag();
    testAMissingKeyframeBuildsTheProperty_sOwnShape();
UM_TEST_MAIN_END()
