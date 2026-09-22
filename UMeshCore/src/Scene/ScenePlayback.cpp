#include "umeshcore/Scene/ScenePlayback.h"

#include <algorithm>
#include <cmath>

namespace umeshcore {

ScenePlayback::Playhead ScenePlayback::playhead(double now, const Session& session) {
    const double span = static_cast<double>(std::max(session.lastFrame, 0) + 1);
    const double elapsed = std::max(now - session.startTime, 0.0);
    // FLOOR, not round, here and below. A frame is a moment the playhead
    // is ON for the whole of its duration; rounding would show frame 1 for
    // the second half of frame 0, so every frame would appear half a frame
    // early and the first would be half as long as the rest.
    const double advanced =
        static_cast<double>(session.startFrame) + elapsed * std::max(session.framesPerSecond, 0.0001);

    // The shot is over when the playhead LEAVES the last frame, not when
    // it reaches it -- the same reason the floor above exists. Ending at
    // `lastFrame` exactly would cut the final frame short and stop the
    // shot half a frame early.
    if (advanced < static_cast<double>(session.lastFrame) + 1.0) {
        return Playhead{static_cast<int>(std::floor(advanced)), false};
    }
    if (!session.loops || span <= 0.0) {
        return Playhead{session.lastFrame, true};
    }
    // `fmod` keeps the sign of the dividend like Swift's
    // `truncatingRemainder`, and `advanced` is non-negative here because
    // `elapsed` is floored at zero and `startFrame` is clamped on the way
    // in, so the wrap cannot land below the first frame.
    const double wrapped = std::fmod(advanced, span);
    return Playhead{static_cast<int>(std::floor(wrapped)), false};
}

void ScenePlayback::play(int frame, int fps, int lastFrame, bool loops, double now) {
    const int end = std::max(lastFrame, 0);
    // A playhead already AT or past the end rewinds; otherwise play would
    // be a button that does nothing.
    const int begin = frame >= end ? 0 : std::min(std::max(frame, 0), end);
    Session started;
    started.startTime = now;
    started.startFrame = begin;
    started.framesPerSecond = static_cast<double>(std::min(std::max(fps, 1), 240));
    started.lastFrame = end;
    started.loops = loops;
    session = started;
}

void ScenePlayback::reanchor(int frame, int fps, int lastFrame, bool loops, double now) {
    // A stopped transport has nothing to re-anchor, and starting one here
    // would make a scrub begin playback.
    if (!session.has_value()) return;
    play(frame, fps, lastFrame, loops, now);
}

} // namespace umeshcore
