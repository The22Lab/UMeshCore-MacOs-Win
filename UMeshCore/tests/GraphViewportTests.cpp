// Tests for Editor/GraphViewport.h, ported from `GraphViewport.swift` and
// `GraphMetrics.swift`.
//
// The type exists because of a specific bug, so the tests are built around
// it: the editor used to derive its vertical range from the KEYFRAME
// VALUES, and a cubic between two keys is bounded by neither its keys nor
// its control points -- it is bounded by its own extrema. So the curve was
// cropped to fit a rectangle derived from something that is not the curve.
// `GraphBounds::includeCubic` is the fix, and the first test below
// measures it against a densely sampled curve rather than restating the
// formula.
//
// The other property this type promises is EXACTNESS: every mapping has an
// exact inverse, so a drag that reads a pixel and stores a value
// round-trips back to the pixel it came from. That is what keeps a handle
// dragged slowly at high zoom moving by what the pointer moved, and it is
// asserted here to a tolerance no artist could express rather than to
// "close enough".

#include "umeshcore/Editor/GraphViewport.h"

#include <cmath>

#include "TestHarness.h"

using namespace umeshcore;

static void testACubicIsBoundedByItsExtremaNotByItsKeysOrHandles() {
    // A segment whose control points pull it well past both ends: the
    // overshoot an ease-out-then-in curve has, and the case the old
    // keyframe-derived range clipped.
    const GraphBounds::Point p0{0.0, 0.0};
    const GraphBounds::Point c1{2.0, 9.0};
    const GraphBounds::Point c2{8.0, -8.0};
    const GraphBounds::Point p3{10.0, 1.0};

    GraphBounds bounds;
    bounds.includeCubic(p0, c1, c2, p3);
    UM_CHECK(bounds.isValid());

    // The truth, by dense sampling -- an INDEPENDENT check rather than a
    // restatement of the quadratic the code solves.
    double sampledMin = 1e30, sampledMax = -1e30;
    for (int i = 0; i <= 200000; ++i) {
        const double t = static_cast<double>(i) / 200000.0;
        const double y = GraphBounds::cubic(t, p0.y, c1.y, c2.y, p3.y);
        sampledMin = std::min(sampledMin, y);
        sampledMax = std::max(sampledMax, y);
    }

    // THE CURVE LEAVES THE SPAN OF ITS KEYS, which is exactly why a range
    // derived from keyframe values cropped it: the keys are 0 and 1, and
    // the curve reaches well past both.
    UM_CHECK(sampledMax > std::max(p0.y, p3.y) + 1.5);
    UM_CHECK(sampledMin < std::min(p0.y, p3.y) - 1.5);

    // The solved extrema ARE the sampled ones -- the quadratic is exact,
    // so this is tight rather than merely safe.
    double solvedMin = std::min(p0.y, p3.y), solvedMax = std::max(p0.y, p3.y);
    for (double t : GraphBounds::extremaParameters(p0.y, c1.y, c2.y, p3.y)) {
        const double y = GraphBounds::cubic(t, p0.y, c1.y, c2.y, p3.y);
        solvedMin = std::min(solvedMin, y);
        solvedMax = std::max(solvedMax, y);
    }
    UM_CHECK_NEAR(solvedMax, sampledMax, 1e-6);
    UM_CHECK_NEAR(solvedMin, sampledMin, 1e-6);

    // And the bounds contain all of it, control points included -- they
    // are DRAWN and DRAGGED, and a handle the artist cannot see is a
    // handle they cannot grab.
    UM_CHECK(bounds.maxValue() >= sampledMax);
    UM_CHECK(bounds.minValue() <= sampledMin);
    UM_CHECK(bounds.maxValue() >= c1.y - 1e-9);
    UM_CHECK(bounds.minValue() <= c2.y + 1e-9);
}

static void testExtremaAreSolvedIncludingTheDegenerateCases() {
    // A straight segment turns nowhere.
    UM_CHECK(GraphBounds::extremaParameters(0, 1, 2, 3).empty());
    // A flat one likewise -- and without dividing by zero.
    UM_CHECK(GraphBounds::extremaParameters(5, 5, 5, 5).empty());
    // A symmetric hump turns exactly once, in the middle.
    const auto hump = GraphBounds::extremaParameters(0, 3, 3, 0);
    UM_CHECK(hump.size() == 1);
    UM_CHECK_NEAR(hump[0], 0.5, 1e-9);
    // Roots outside (0, 1) are not on the segment.
    for (double t : GraphBounds::extremaParameters(0, 10, -10, 0)) {
        UM_CHECK(t > 0.0 && t < 1.0);
    }

    // Empty bounds stay invalid rather than reporting an infinite box, and
    // a non-finite sample is refused rather than poisoning the range.
    GraphBounds empty;
    UM_CHECK(!empty.isValid());
    empty.include(std::nan(""), 1.0);
    empty.include(1.0, std::numeric_limits<double>::infinity());
    UM_CHECK(!empty.isValid());
}

static void testEveryMappingHasAnExactInverse() {
    const GraphViewport viewport(GraphRange{12.5, 61.25}, GraphRange{-3.75, 9.125});
    const double width = 1280.0, height = 460.0;

    for (int i = 0; i <= 1000; ++i) {
        const double x = width * static_cast<double>(i) / 1000.0;
        const double time = viewport.timeForX(x, width);
        UM_CHECK_NEAR(viewport.xForTime(time, width), x, 1e-9);

        const double y = height * static_cast<double>(i) / 1000.0;
        const double value = viewport.valueForY(y, height);
        UM_CHECK_NEAR(viewport.yForValue(value, height), y, 1e-9);
    }

    // Y flips: the top of the view is the LARGER value.
    UM_CHECK(viewport.valueForY(0.0, height) > viewport.valueForY(height, height));

    // The deltas are the derivative of the mapping, so a drag and the
    // mapping cannot disagree.
    const double dy = 37.0;
    UM_CHECK_NEAR(
        viewport.valueForY(100.0, height) - viewport.valueForY(100.0 + dy, height),
        viewport.valueDeltaForPoints(dy, height), 1e-12);
    const double dx = 21.0;
    UM_CHECK_NEAR(
        viewport.timeForX(100.0 + dx, width) - viewport.timeForX(100.0, width),
        viewport.timeDeltaForPoints(dx, width), 1e-12);

    // A zero-sized view answers its own lower bound rather than dividing
    // by nothing.
    UM_CHECK(viewport.timeForX(50.0, 0.0) == viewport.timeRange().lower);
    UM_CHECK(viewport.valueForY(50.0, 0.0) == viewport.valueRange().lower);
    UM_CHECK(viewport.valueDeltaForPoints(50.0, 0.0) == 0.0);
}

static void testZoomHoldsThePointUnderTheCursor() {
    const double width = 900.0, height = 400.0;
    const double anchorX = 610.0, anchorY = 122.0;
    GraphViewport viewport(GraphRange{0, 60}, GraphRange{-2, 6});
    const double timeUnder = viewport.timeForX(anchorX, width);
    const double valueUnder = viewport.valueForY(anchorY, height);

    for (int step = 0; step < 40; ++step) {
        viewport.zoom(1.2, 1.15, anchorX, anchorY, width, height);
        // What is under the cursor stays under the cursor -- that is what
        // "zoom at the cursor" means.
        UM_CHECK_NEAR(viewport.timeForX(anchorX, width), timeUnder, 1e-6);
        UM_CHECK_NEAR(viewport.valueForY(anchorY, height), valueUnder, 1e-6);
    }
    // And the two axes scaled independently, because a curve's interesting
    // span in time has nothing to do with its span in value.
    UM_CHECK(viewport.timeSpan() < 60.0 && viewport.valueSpan() < 8.0);

    // A factor of zero or a NaN leaves the axis alone rather than
    // destroying it.
    const GraphRange before = viewport.timeRange();
    viewport.zoom(0.0, std::nan(""), anchorX, anchorY, width, height);
    UM_CHECK(viewport.timeRange() == before);
}

static void testTheZoomFloorWidensTheViewWithoutMovingIt() {
    // THE FLOOR DECIDES HOW WIDE THE VIEW IS; it has no business deciding
    // where it sits. Without the anchor, re-centring at the floor drags
    // the picture on every further zoom step -- measured in the Swift
    // harness at 262% of the view's width over ninety steps.
    const double width = 800.0, height = 400.0;
    const double anchorX = 700.0; // deliberately off centre
    GraphViewport viewport(GraphRange{0, 60}, GraphRange{-1, 1});
    const double timeUnder = viewport.timeForX(anchorX, width);

    for (int step = 0; step < 90; ++step) {
        viewport.zoom(2.0, 1.0, anchorX, 200.0, width, height);
    }
    // Deep past the floor, and the anchor has not walked.
    UM_CHECK(viewport.timeSpan() <= GraphViewport::kMinimumSpan * 1.0001);
    UM_CHECK_NEAR(viewport.timeForX(anchorX, width), timeUnder, 1e-4);

    // What a re-centring floor would have done instead, computed here so
    // the difference is a number rather than a claim: the anchor ends up
    // at the middle of the view, which for an anchor at 7/8 of the width
    // is 3/8 of a view away -- and it moves again on every step.
    const double recentred = viewport.timeRange().lower + viewport.timeSpan() * 0.5;
    const double driftPerStep =
        std::fabs(recentred - timeUnder) / std::max(viewport.timeSpan(), 1e-12);
    UM_CHECK(driftPerStep > 0.3);
}

static void testPanKeepsContentUnderTheFinger() {
    const double width = 1000.0, height = 500.0;
    GraphViewport viewport(GraphRange{10, 70}, GraphRange{-5, 5});
    const double x = 300.0, y = 220.0;
    const double timeUnder = viewport.timeForX(x, width);
    const double valueUnder = viewport.valueForY(y, height);

    const double dx = 140.0, dy = -60.0;
    viewport.pan(dx, dy, width, height);
    // The same content is now under the moved finger.
    UM_CHECK_NEAR(viewport.timeForX(x + dx, width), timeUnder, 1e-9);
    UM_CHECK_NEAR(viewport.valueForY(y + dy, height), valueUnder, 1e-9);

    // Dragging DOWN moves the content down, so the visible values go UP.
    // The sign is the flip in the mapping, not a choice.
    GraphViewport other(GraphRange{0, 10}, GraphRange{0, 10});
    other.pan(0.0, 50.0, width, height);
    UM_CHECK(other.valueRange().lower > 0.0);
}

static void testFittingMovesTheViewToTheCurveAndNeverTheOtherWayRound() {
    GraphBounds bounds;
    bounds.includeCubic({0, 0}, {2, 4}, {8, -3}, {10, 1});
    const GraphViewport fitted = GraphViewport::fitting(bounds);

    // Everything the curve reaches is inside the view, with room to spare
    // -- nothing sits on the edge.
    UM_CHECK(fitted.valueRange().lower < bounds.minValue());
    UM_CHECK(fitted.valueRange().upper > bounds.maxValue());
    UM_CHECK(fitted.timeRange().lower < bounds.minTime());
    UM_CHECK(fitted.timeRange().upper > bounds.maxTime());

    // A flat curve still gets a usable view rather than a degenerate one:
    // the pad has a floor of its own.
    GraphBounds flat;
    flat.include(3.0, 2.0);
    flat.include(9.0, 2.0);
    const GraphViewport flatFit = GraphViewport::fitting(flat);
    UM_CHECK(flatFit.valueSpan() > 0.05);
    UM_CHECK(flatFit.timeSpan() > 6.0);

    // Nothing to fit: the neutral view, not an infinite one.
    UM_CHECK(GraphViewport::fitting(GraphBounds{}).timeRange() == GraphViewport::neutral().timeRange());

    // `extendToInclude` keeps the framing the artist chose and only widens.
    GraphViewport chosen(GraphRange{0, 20}, GraphRange{-1, 1});
    GraphBounds outside;
    outside.include(45.0, 7.0);
    chosen.extendToInclude(outside);
    UM_CHECK(chosen.timeRange().lower == 0.0);   // the near edge did not move
    UM_CHECK(chosen.timeRange().upper > 45.0);   // the far one did
    UM_CHECK(chosen.valueRange().upper > 7.0);
    UM_CHECK(chosen.valueRange().lower == -1.0);
}

static void testTheGridSubdividesInsteadOfDrifting() {
    // A nice number -- 1, 2 or 5 times a power of ten -- so zooming in
    // falls to the next one rather than spreading the same lines apart.
    const double steps[] = {
        GraphViewport::gridStep(60.0), GraphViewport::gridStep(6.0),
        GraphViewport::gridStep(0.6), GraphViewport::gridStep(600.0)};
    for (double step : steps) {
        const double magnitude = std::pow(10.0, std::floor(std::log10(step)));
        const double mantissa = step / magnitude;
        UM_CHECK(
            std::fabs(mantissa - 1.0) < 1e-9 || std::fabs(mantissa - 2.0) < 1e-9 ||
            std::fabs(mantissa - 5.0) < 1e-9);
    }
    // Monotone: a narrower span never asks for a wider step.
    double previous = GraphViewport::gridStep(1000.0);
    for (double span = 900.0; span > 0.01; span *= 0.7) {
        const double step = GraphViewport::gridStep(span);
        UM_CHECK(step <= previous + 1e-12);
        previous = step;
    }
    // A degenerate span answers 1 rather than dividing by nothing.
    UM_CHECK(GraphViewport::gridStep(0.0) == 1.0);
    UM_CHECK(GraphViewport::gridStep(std::nan("")) == 1.0);

    // Lines land on the step's own multiples, so a line at zero is AT
    // zero.
    const auto lines = GraphViewport::gridLines(GraphRange{-7.3, 12.4}, 5.0);
    UM_CHECK(!lines.empty());
    bool sawZero = false;
    for (double line : lines) {
        UM_CHECK_NEAR(std::fmod(line, 5.0), 0.0, 1e-9);
        UM_CHECK(line >= -7.3 && line <= 12.4);
        if (std::fabs(line) < 1e-12) sawZero = true;
    }
    UM_CHECK(sawZero);

    // Too many lines to draw is answered with none rather than with a
    // million: at that density the grid is a fill, not a grid.
    UM_CHECK(GraphViewport::gridLines(GraphRange{0, 1e9}, 0.001).empty());
    UM_CHECK(GraphViewport::gridLines(GraphRange{0, 10}, 0.0).empty());
}

static void testTheGrabToleranceOrderIsAFactNotAHope() {
    // A handle beats a keyframe, a keyframe beats the curve -- so the
    // z-order and the tolerances agree instead of quietly contradicting
    // each other.
    for (double scale : {GraphMetrics::kPointerTouchScale, GraphMetrics::kFingerTouchScale}) {
        UM_CHECK(GraphMetrics::respectsPriority(scale));
        UM_CHECK(GraphMetrics::handleGrabPx(scale) > GraphMetrics::keyframeGrabPx(scale));
        UM_CHECK(GraphMetrics::keyframeGrabPx(scale) > GraphMetrics::curveGrabPx(scale));
    }
    // Scaled, never redefined, so the order cannot come apart between
    // platforms: touch is uniformly more generous.
    UM_CHECK(
        GraphMetrics::handleGrabPx(GraphMetrics::kFingerTouchScale) >
        GraphMetrics::handleGrabPx(GraphMetrics::kPointerTouchScale));
    // And what is DRAWN is smaller than what can be GRABBED, which is the
    // whole reason the two sets of numbers exist.
    UM_CHECK(GraphMetrics::kKeyframeVisualPx < GraphMetrics::keyframeGrabPx(1.0));
    UM_CHECK(GraphMetrics::kHandleVisualPx < GraphMetrics::handleGrabPx(1.0));
}

UM_TEST_MAIN_BEGIN()
    testACubicIsBoundedByItsExtremaNotByItsKeysOrHandles();
    testExtremaAreSolvedIncludingTheDegenerateCases();
    testEveryMappingHasAnExactInverse();
    testZoomHoldsThePointUnderTheCursor();
    testTheZoomFloorWidensTheViewWithoutMovingIt();
    testPanKeepsContentUnderTheFinger();
    testFittingMovesTheViewToTheCurveAndNeverTheOtherWayRound();
    testTheGridSubdividesInsteadOfDrifting();
    testTheGrabToleranceOrderIsAFactNotAHope();
UM_TEST_MAIN_END()
