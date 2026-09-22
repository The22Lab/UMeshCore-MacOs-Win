// Tests for Render/SceneRenderBudget.h, ported from
// `Render/SceneRenderBudget.swift`.
//
// The Swift header describes the two failure modes the ladder exists to
// avoid, and gives concrete numbers for one of them. Both are reproduced
// here as scenarios rather than asserted as constants:
//
//   - OSCILLATION: the header's own worked example -- a machine measuring
//     15 ms at half size against a 33 ms budget "looks like plenty of
//     room" to a naive threshold, climbs to three quarters, takes 34 ms
//     and is dropped straight back, nine frames later does it again. The
//     test runs that machine for hundreds of frames and requires the rung
//     to be still.
//   - RATCHETING: one catastrophic frame must not leave the canvas soft
//     for the rest of the session.

#include "umeshcore/Render/SceneRenderBudget.h"

#include "TestHarness.h"

using namespace umeshcore;

namespace {

// A machine whose frame time is proportional to the pixels it draws, which
// go as the square of the scale. `atFullScale` is what it takes at rung 0.
double frameTime(double atFullScale, float scale) {
    return atFullScale * static_cast<double>(scale) * static_cast<double>(scale);
}

} // namespace

static void testSlowFramesStepDownOneRungAtATime() {
    SceneRenderBudget budget;
    UM_CHECK(budget.rung() == 0);
    UM_CHECK(budget.scale() == 1.0f);

    // However catastrophic: a single frame is not evidence about the
    // steady state, and dropping three rungs for it would take three
    // seconds of good frames to undo.
    budget.record(4000.0, true);
    UM_CHECK(budget.rung() == 1);
    budget.record(4000.0, true);
    UM_CHECK(budget.rung() == 2);
    for (int i = 0; i < 20; ++i) budget.record(4000.0, true);
    // And never past the bottom.
    UM_CHECK(budget.rung() == SceneRenderBudget::kLadderSize - 1);
    UM_CHECK(budget.scale() == 0.25f);
}

static void testAStillCanvasGoesStraightBackToTheTop() {
    SceneRenderBudget budget;
    for (int i = 0; i < 3; ++i) budget.record(100.0, true);
    UM_CHECK(budget.rung() == 3);
    // The artist stops moving: no ratcheting, no eight-frame wait.
    budget.record(100.0, false);
    UM_CHECK(budget.rung() == 0);
    UM_CHECK(budget.scale() == 1.0f);

    for (int i = 0; i < 3; ++i) budget.record(100.0, true);
    budget.reset();
    UM_CHECK(budget.rung() == 0 && budget.comfortableFrames() == 0);
}

static void testTheHeadersOscillationScenarioDoesNotOscillate() {
    // The machine from the Swift header: 15 ms at half size against a 33 ms
    // budget. A naive "climb when under 60% of target" sees 45% and climbs
    // to 0.75, where the same machine takes 15 * (0.75/0.5)^2 = 33.75 ms,
    // is dropped back, and repeats forever.
    const double atFullScale = 15.0 / (0.5 * 0.5); // 60 ms at rung 0
    SceneRenderBudget budget;
    // Settle: two slow frames put it at half size.
    budget.record(frameTime(atFullScale, 1.0f), true);
    budget.record(frameTime(atFullScale, 0.75f), true);
    UM_CHECK(budget.rung() == 2);
    UM_CHECK(budget.scale() == 0.5f);

    // Now run it. The naive rule would pulse; the prediction keeps it still.
    for (int frame = 0; frame < 600; ++frame) {
        budget.record(frameTime(atFullScale, budget.scale()), true);
        UM_CHECK(budget.rung() == 2);
        // Credit never accumulates towards a climb that would be undone.
        UM_CHECK(budget.comfortableFrames() == 0);
    }
}

static void testItClimbsBackAfterATransientAndStopsWhereItFits() {
    // A machine that sustains 20 ms at full size -- comfortably inside the
    // budget. Two catastrophic frames (a sheet animating over the canvas,
    // a project opening) drop it two rungs; the ladder has to walk back up
    // rather than leave the canvas soft for the session.
    const double atFullScale = 20.0;
    SceneRenderBudget budget;
    budget.record(900.0, true);
    budget.record(900.0, true);
    UM_CHECK(budget.rung() == 2);

    // Rung 2 costs 5 ms; rung 1 is predicted at 11.25, inside 33 * 0.9.
    for (int i = 0; i < SceneRenderBudget::kFramesBeforeClimbing - 1; ++i) {
        budget.record(frameTime(atFullScale, budget.scale()), true);
        UM_CHECK(budget.rung() == 2); // not yet: one frame is not evidence
        UM_CHECK(budget.comfortableFrames() == i + 1);
    }
    budget.record(frameTime(atFullScale, budget.scale()), true);
    UM_CHECK(budget.rung() == 1);
    UM_CHECK(budget.comfortableFrames() == 0);

    // Eight more and it is back at the top, where 20 ms fits.
    for (int i = 0; i < SceneRenderBudget::kFramesBeforeClimbing; ++i) {
        budget.record(frameTime(atFullScale, budget.scale()), true);
    }
    UM_CHECK(budget.rung() == 0);
    for (int i = 0; i < 100; ++i) budget.record(frameTime(atFullScale, budget.scale()), true);
    UM_CHECK(budget.rung() == 0);
}

static void testAMachineSettlesOnTheHighestRungThatFits() {
    // 40 ms at full size: rung 0 does not fit, rung 1 (22.5 ms) does, and
    // the prediction for rung 0 is 40 -- outside the budget -- so it stops
    // there instead of pulsing between the two.
    const double atFullScale = 40.0;
    SceneRenderBudget budget;
    budget.record(frameTime(atFullScale, 1.0f), true);
    UM_CHECK(budget.rung() == 1);
    for (int frame = 0; frame < 300; ++frame) {
        budget.record(frameTime(atFullScale, budget.scale()), true);
        UM_CHECK(budget.rung() == 1);
        UM_CHECK(budget.comfortableFrames() == 0);
    }
}

static void testTheStreakHasToBeConsecutive() {
    const double atFullScale = 20.0;
    SceneRenderBudget budget;
    budget.record(900.0, true);
    budget.record(900.0, true);
    UM_CHECK(budget.rung() == 2);

    for (int i = 0; i < 6; ++i) budget.record(frameTime(atFullScale, budget.scale()), true);
    UM_CHECK(budget.comfortableFrames() == 6);
    // One expensive frame in the middle spends the credit AND costs a rung.
    budget.record(90.0, true);
    UM_CHECK(budget.rung() == 3);
    UM_CHECK(budget.comfortableFrames() == 0);
}

static void testTopRungAccumulatesNoCredit() {
    SceneRenderBudget budget;
    for (int i = 0; i < 50; ++i) budget.record(1.0, true);
    UM_CHECK(budget.rung() == 0);
    UM_CHECK(budget.comfortableFrames() == 0); // nothing above to climb to
}

static void testPixelCapIsACeilingNotATarget() {
    SceneRenderBudget budget;
    UM_CHECK_NEAR(budget.pixelCap(2000.0f), 2000.0, 1e-6);
    budget.record(500.0, true);
    UM_CHECK_NEAR(budget.pixelCap(2000.0f), 1500.0, 1e-6);
    budget.record(500.0, true);
    UM_CHECK_NEAR(budget.pixelCap(2000.0f), 1000.0, 1e-6);
}

static void testMeterTakesTheMedianAndKeepsAShortWindow() {
    FrameCostMeter meter;
    UM_CHECK(!meter.hasSamples());
    UM_CHECK(meter.milliseconds() == 0.0);

    for (int i = 0; i < 5; ++i) meter.record(10.0);
    // One eighty-millisecond frame because the app was launching: it drags
    // a six-frame MEAN (21.7 ms) most of the way to the target and would
    // cost a rung. The median ignores it.
    meter.record(80.0);
    UM_CHECK(meter.milliseconds() == 10.0);

    // Short enough to follow a genuine change: six slow frames replace the
    // window entirely.
    for (int i = 0; i < 6; ++i) meter.record(50.0);
    UM_CHECK(meter.milliseconds() == 50.0);

    meter.reset();
    UM_CHECK(!meter.hasSamples() && meter.milliseconds() == 0.0);
}

static void testMeterWindowDropsTheOldestSamples() {
    FrameCostMeter meter;
    for (int i = 1; i <= 10; ++i) meter.record(static_cast<double>(i));
    // Only the last six survive: 5..10, whose upper-middle is 8.
    UM_CHECK(meter.milliseconds() == 8.0);
}

UM_TEST_MAIN_BEGIN()
    testSlowFramesStepDownOneRungAtATime();
    testAStillCanvasGoesStraightBackToTheTop();
    testTheHeadersOscillationScenarioDoesNotOscillate();
    testItClimbsBackAfterATransientAndStopsWhereItFits();
    testAMachineSettlesOnTheHighestRungThatFits();
    testTheStreakHasToBeConsecutive();
    testTopRungAccumulatesNoCredit();
    testPixelCapIsACeilingNotATarget();
    testMeterTakesTheMedianAndKeepsAShortWindow();
    testMeterWindowDropsTheOldestSamples();
UM_TEST_MAIN_END()
