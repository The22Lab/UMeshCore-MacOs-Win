// Tests for Scene/ScenePlayback.h and Scene/SceneSelection.h, ported from
// `Data/Scene/ScenePlayback.swift` and `SceneSelection.swift`.
//
// The transport's contract is stated as a rule with a failure behind it,
// so these assert the rule:
//
//   - The playhead is a PURE FUNCTION of the time. Nothing accumulates, so
//     a machine that misses its schedule plays at the right SPEED and only
//     less smoothly. The test for this is the one that matters: sampling
//     the same session at wildly uneven intervals must land on exactly the
//     frames a perfectly-paced machine would have shown.
//   - It FLOORS, never rounds. A frame is a moment the playhead is on for
//     the whole of its duration; rounding would show frame 1 for the
//     second half of frame 0.
//   - The shot ends when the playhead LEAVES the last frame, not when it
//     reaches it -- otherwise the final frame is cut short.
//   - Play from the end REWINDS, or play would be a button that does
//     nothing.
//   - `reanchor` on a stopped transport does not start one, and on a
//     running one stops the scrubber "fighting" the artist.
//
// And `SceneSelection` exists to make "one thing at a time" a type rather
// than a convention that four call sites each enforced differently.

#include "umeshcore/Scene/ScenePlayback.h"

#include <cmath>
#include <vector>

#include "umeshcore/Scene/SceneSelection.h"

#include "TestHarness.h"

using namespace umeshcore;

namespace {

// 24 fps, frames 0..47, from a clock that starts at a deliberately
// non-zero instant -- a monotonic clock does not start at zero, and a
// transport that assumed it did would work only on the first run.
ScenePlayback::Session session(bool loops) {
    ScenePlayback::Session s;
    s.startTime = 1000.0;
    s.startFrame = 0;
    s.framesPerSecond = 24.0;
    s.lastFrame = 47;
    s.loops = loops;
    return s;
}

int frameAt(double now, const ScenePlayback::Session& s) {
    return ScenePlayback::playhead(now, s).frame;
}

// A frame's worth of seconds at 24 fps, plus a nudge.
//
// The nudge is there because `now - startTime` is a DIFFERENCE of two
// large doubles: with a monotonic clock in the thousands of seconds,
// `(1000.0 + 1.0/24.0) - 1000.0` comes back about 4e-14 short, so a sample
// taken at the exact instant a frame begins can land on the previous one.
// That is inherent to the arithmetic and identical in Swift -- and it does
// not matter, which is the point of the whole file: an exact-boundary
// sample is ambiguous by at most ONE sample and never accumulates. The
// tests therefore ask about instants INSIDE a frame, which is all a real
// transport ever samples. `testExactFrameBoundaryIsAmbiguousAndHarmless`
// pins the behaviour itself.
double frames(double count) { return count / 24.0 + 1e-9; }

} // namespace

static void testPlayheadFloorsAndNeverRounds() {
    const ScenePlayback::Session s = session(false);
    // A frame lasts 1/24 s. The playhead is on frame 0 for the WHOLE of
    // it, including the instant just before frame 1 begins.
    UM_CHECK(frameAt(1000.0, s) == 0);
    UM_CHECK(frameAt(1000.0 + 0.9 / 24.0, s) == 0);
    UM_CHECK(frameAt(1000.0 + frames(1.0), s) == 1);
    UM_CHECK(frameAt(1000.0 + 1.9 / 24.0, s) == 1);
    // Rounding would have put frame 1 on screen from half way through
    // frame 0, making the first frame half as long as the rest.
    UM_CHECK(frameAt(1000.0 + 0.5 / 24.0, s) == 0);
}

static void testPlayheadIsAPureFunctionOfTime() {
    // The rule the whole file exists for. A machine that misses its
    // schedule samples the motion less often; it must not fall BEHIND.
    const ScenePlayback::Session s = session(false);
    // Uneven, hostile sampling: some ticks far apart, some very close.
    const std::vector<double> offsets = {0.0,  0.31, 0.33, 0.9,  1.4,
                                         1.41, 1.42, 1.85, 1.9,  1.95};
    for (const double offset : offsets) {
        const int expected = static_cast<int>(std::floor(offset * 24.0));
        UM_CHECK(frameAt(1000.0 + offset, s) == expected);
    }
}

static void testExactFrameBoundaryIsAmbiguousAndHarmless() {
    // Documented, not worked around. `now - startTime` is a difference of
    // two large doubles, so a sample taken at the exact instant a frame
    // begins can come back one ulp short and show the previous frame. From
    // a clock at zero it does not; from a clock at 1000 seconds it does.
    //
    // It is harmless for the reason the file is built around: the playhead
    // is derived from the time, not accumulated, so the error is bounded
    // at ONE sample and the next tick is right again. A transport that
    // stepped by a delta would have turned the same ulp into permanent
    // drift.
    ScenePlayback::Session fromZero = session(false);
    fromZero.startTime = 0.0;
    UM_CHECK(frameAt(1.0 / 24.0, fromZero) == 1);

    const ScenePlayback::Session fromLate = session(false); // startTime 1000
    const int atBoundary = frameAt(1000.0 + 1.0 / 24.0, fromLate);
    UM_CHECK(atBoundary == 0 || atBoundary == 1);
    // Whichever it was, a hair later is unambiguous -- the error does not
    // carry.
    UM_CHECK(frameAt(1000.0 + frames(1.0), fromLate) == 1);
    UM_CHECK(frameAt(1000.0 + frames(2.0), fromLate) == 2);
}

static void testTimeBeforeTheStartDoesNotRunBackwards() {
    // `elapsed` is floored at zero, so a clock that jitters backwards by a
    // microsecond shows the start frame rather than a negative one.
    ScenePlayback::Session s = session(false);
    s.startFrame = 5;
    UM_CHECK(frameAt(999.999, s) == 5);
    UM_CHECK(frameAt(1000.0, s) == 5);
}

static void testShotEndsOnlyAfterTheLastFrameHasPlayed() {
    const ScenePlayback::Session s = session(false);
    // Frame 47 begins at 47/24 s and lasts until 48/24 s. Ending when the
    // playhead REACHES it would cut it short by a whole frame.
    const ScenePlayback::Playhead onLast = ScenePlayback::playhead(1000.0 + frames(47.0), s);
    UM_CHECK(onLast.frame == 47);
    UM_CHECK(!onLast.ended);

    const ScenePlayback::Playhead stillOnLast =
        ScenePlayback::playhead(1000.0 + 47.9 / 24.0, s);
    UM_CHECK(stillOnLast.frame == 47 && !stillOnLast.ended);

    const ScenePlayback::Playhead past = ScenePlayback::playhead(1000.0 + frames(48.0), s);
    UM_CHECK(past.frame == 47);
    UM_CHECK(past.ended);
}

static void testALoopingSceneNeverEnds() {
    const ScenePlayback::Session s = session(true);
    // 48 frames, so the wrap is back to 0 at 48/24 s.
    const ScenePlayback::Playhead wrapped = ScenePlayback::playhead(1000.0 + frames(48.0), s);
    UM_CHECK(wrapped.frame == 0);
    UM_CHECK(!wrapped.ended);
    UM_CHECK(frameAt(1000.0 + frames(49.0), s) == 1);
    // Many laps later it is still inside the shot, and still not ended.
    const ScenePlayback::Playhead late = ScenePlayback::playhead(1000.0 + 1000.0, s);
    UM_CHECK(late.frame >= 0 && late.frame <= 47);
    UM_CHECK(!late.ended);
}

static void testStartFrameOffsetsTheWholeTransport() {
    ScenePlayback::Session s = session(false);
    s.startFrame = 20;
    UM_CHECK(frameAt(1000.0, s) == 20);
    UM_CHECK(frameAt(1000.0 + frames(1.0), s) == 21);
}

static void testAZeroFpsSessionDoesNotDivideTheTimelineByNothing() {
    // The floor is 0.0001, so the playhead crawls rather than stalling on
    // a NaN or racing to the end.
    ScenePlayback::Session s = session(false);
    s.framesPerSecond = 0.0;
    const ScenePlayback::Playhead head = ScenePlayback::playhead(1000.0 + 1.0, s);
    UM_CHECK(head.frame == 0);
    UM_CHECK(!head.ended);
}

// ---- play / stop / reanchor -------------------------------------------

static void testPlayStartsFromWhereThePlayheadIs() {
    // Pressing play in the middle of a shot to watch the rest of it is
    // what the button is for.
    ScenePlayback transport;
    transport.play(12, 24, 47, false, 500.0);
    UM_CHECK(transport.isPlaying());
    UM_CHECK(transport.session.has_value());
    if (transport.session) {
        UM_CHECK(transport.session->startFrame == 12);
        UM_CHECK(ScenePlayback::playhead(500.0, *transport.session).frame == 12);
    }
}

static void testPlayFromTheEndRewinds() {
    // Otherwise play would be a button that does nothing.
    ScenePlayback transport;
    transport.play(47, 24, 47, false, 0.0);
    UM_CHECK(transport.session.has_value());
    if (transport.session) UM_CHECK(transport.session->startFrame == 0);
    // Past the end too.
    transport.play(900, 24, 47, false, 0.0);
    if (transport.session) UM_CHECK(transport.session->startFrame == 0);
}

static void testPlayClampsItsInputs() {
    ScenePlayback transport;
    transport.play(-10, 9000, -5, false, 0.0);
    UM_CHECK(transport.session.has_value());
    if (!transport.session) return;
    UM_CHECK(transport.session->startFrame == 0);
    UM_CHECK(transport.session->lastFrame == 0);
    UM_CHECK_NEAR(transport.session->framesPerSecond, 240.0, 1e-9);
    transport.play(0, 0, 47, false, 0.0);
    if (transport.session) UM_CHECK_NEAR(transport.session->framesPerSecond, 1.0, 1e-9);
}

static void testStopClearsTheSession() {
    ScenePlayback transport;
    transport.play(0, 24, 47, true, 0.0);
    transport.stop();
    UM_CHECK(!transport.isPlaying());
}

static void testReanchorOnAStoppedTransportDoesNotStartOne() {
    // A scrub must not become a play.
    ScenePlayback transport;
    transport.reanchor(10, 24, 47, false, 0.0);
    UM_CHECK(!transport.isPlaying());
}

static void testReanchorStopsTheScrubberFightingTheArtist() {
    // Without it the session still measures from where play was pressed,
    // so the very next tick undoes the scrub and the playhead snaps back.
    ScenePlayback transport;
    transport.play(0, 24, 47, false, 1000.0);
    // One second in, the playhead is on frame 24. The artist scrubs to 40.
    UM_CHECK(frameAt(1001.0, *transport.session) == 24);
    transport.reanchor(40, 24, 47, false, 1001.0);
    // The next tick must show 40, not snap back towards 24.
    UM_CHECK(frameAt(1001.0, *transport.session) == 40);
    UM_CHECK(frameAt(1001.0 + frames(1.0), *transport.session) == 41);
}

static void testReanchorAcceptsANewRateAndLength() {
    ScenePlayback transport;
    transport.play(0, 24, 47, false, 0.0);
    transport.reanchor(10, 60, 120, true, 5.0);
    UM_CHECK(transport.session.has_value());
    if (!transport.session) return;
    UM_CHECK_NEAR(transport.session->framesPerSecond, 60.0, 1e-9);
    UM_CHECK(transport.session->lastFrame == 120);
    UM_CHECK(transport.session->loops);
}

// ---- SceneSelection ----------------------------------------------------

static void testSelectionIsOneThingAtATime() {
    // The point of the type. Selecting a light cannot leave a layer
    // selected, because there is one id and not two.
    SceneSelection selection = SceneSelection::layer(Uuid(1, 1));
    UM_CHECK(selection.layerID().has_value());
    UM_CHECK(!selection.lightID().has_value());

    selection = SceneSelection::light(Uuid(2, 2));
    UM_CHECK(!selection.layerID().has_value());
    UM_CHECK(selection.lightID().has_value());
    if (selection.lightID()) UM_CHECK(*selection.lightID() == Uuid(2, 2));
}

static void testSelectedIdAnswersWithoutSayingWhichKind() {
    UM_CHECK(SceneSelection::layer(Uuid(3, 3)).selectedID() == Uuid(3, 3));
    UM_CHECK(SceneSelection::light(Uuid(4, 4)).selectedID() == Uuid(4, 4));
    UM_CHECK(!SceneSelection::none().selectedID().has_value());
}

static void testEmptySelectionIgnoresAStaleId() {
    // Two cleared selections are equal whatever was last in the field --
    // a difference nothing should be able to observe.
    SceneSelection selection = SceneSelection::layer(Uuid(5, 5));
    selection = SceneSelection::none();
    UM_CHECK(selection.isEmpty());
    UM_CHECK(selection == SceneSelection::none());
    UM_CHECK(!selection.selectedID().has_value());
}

static void testSameKindDifferentIdsAreNotEqual() {
    UM_CHECK(SceneSelection::layer(Uuid(1, 1)) != SceneSelection::layer(Uuid(2, 2)));
    UM_CHECK(SceneSelection::layer(Uuid(1, 1)) == SceneSelection::layer(Uuid(1, 1)));
    // And the same id under two kinds is two different selections.
    UM_CHECK(SceneSelection::layer(Uuid(1, 1)) != SceneSelection::light(Uuid(1, 1)));
}

UM_TEST_MAIN_BEGIN()
testPlayheadFloorsAndNeverRounds();
testPlayheadIsAPureFunctionOfTime();
testExactFrameBoundaryIsAmbiguousAndHarmless();
testTimeBeforeTheStartDoesNotRunBackwards();
testShotEndsOnlyAfterTheLastFrameHasPlayed();
testALoopingSceneNeverEnds();
testStartFrameOffsetsTheWholeTransport();
testAZeroFpsSessionDoesNotDivideTheTimelineByNothing();
testPlayStartsFromWhereThePlayheadIs();
testPlayFromTheEndRewinds();
testPlayClampsItsInputs();
testStopClearsTheSession();
testReanchorOnAStoppedTransportDoesNotStartOne();
testReanchorStopsTheScrubberFightingTheArtist();
testReanchorAcceptsANewRateAndLength();
testSelectionIsOneThingAtATime();
testSelectedIdAnswersWithoutSayingWhichKind();
testEmptySelectionIgnoresAStaleId();
testSameKindDifferentIdsAreNotEqual();
UM_TEST_MAIN_END()
