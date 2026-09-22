#pragma once

// 1:1 port of `Data/Scene/ScenePlayback.swift` -- Scene's transport: where
// the playhead is, as a function of wall-clock time.
//
// ## Why Scene has a clock of its own
//
// It would be tempting to play a Scene with the rig's transport. It is the
// wrong one twice over. The rig plays on `projectFramesPerSecond` between
// `playbackStartFrame` and `playbackEndFrame`; a scene has its own
// `durationInFrames` and its own `fps`, and they are different numbers for
// a reason -- a 24 fps shot can stage a rig animated at 60.
//
// And it would break the thing Scene is FOR. A rig instance maps the SCENE
// frame to its own clip frame through its speed, start offset and loop
// flag (`SceneLayer::rigFrame`), so three birds from one rig flap out of
// step. Drive the scene from the rig's playhead and every instance moves
// together, which is precisely the feature gone.
//
// ## The one design rule
//
// A session is `(startTime, startFrame, fps, bounds)` and the playhead is
// a PURE FUNCTION of the current time. NOTHING ACCUMULATES.
//
// That is not tidiness. A heavy set can miss its schedule, and a transport
// that advanced by a delta each tick would then run SLOW -- turning a
// dropped frame into lost time and drifting away from the audio, the
// export and the clock on the wall. Derived from the time instead, a frame
// the machine cannot deliver costs one SAMPLE of the motion and never a
// step of it: the scene plays at the right speed on a machine that cannot
// keep up, it simply plays less smoothly.
//
// ## The clock is injected
//
// Swift defaults `now` to `CACurrentMediaTime()`. There is no portable
// equivalent and no reason for the core to own one, so every entry point
// here TAKES the time. That is the same "inject what's needed" rule the
// rest of the port follows, and it has a second benefit the Swift version
// does not get: the transport is exactly testable, because a test can hand
// it any instant it likes. Seconds, monotonic; which clock produces them
// is the shell's business, as long as it is the same one every tick.

#include <optional>

namespace umeshcore {

struct ScenePlayback {
    // What a running transport is, entirely.
    struct Session {
        // The monotonic time when play was pressed.
        double startTime = 0.0;
        // The frame the playhead was on then.
        int startFrame = 0;
        double framesPerSecond = 30.0;
        // INCLUSIVE. A scene runs from 0 to `durationInFrames - 1`.
        int lastFrame = 0;
        bool loops = false;

        bool operator==(const Session&) const = default;
    };

    std::optional<Session> session;

    bool operator==(const ScenePlayback&) const = default;

    bool isPlaying() const { return session.has_value(); }

    struct Playhead {
        int frame = 0;
        // Only ever true for a session that does not loop: a looping scene
        // has no end to reach.
        bool ended = false;
    };

    // Where the playhead should be now, and whether the transport has run
    // out.
    static Playhead playhead(double now, const Session& session);

    // Start playing from `frame` -- from the frame the playhead is ON, not
    // from the start: pressing play in the middle of a shot to watch the
    // rest of it is what the button is for. A playhead already at the end
    // REWINDS, because otherwise play would be a button that does nothing.
    void play(int frame, int fps, int lastFrame, bool loops, double now);

    void stop() { session.reset(); }

    // Re-anchor a running transport to a new frame, rate or length.
    //
    // Called when the artist scrubs while playing, or changes the scene's
    // fps. Without it the session would still be measuring from where play
    // was pressed, so a scrub would be undone by the very next tick -- the
    // playhead snapping back is what "the scrubber fights me" is.
    void reanchor(int frame, int fps, int lastFrame, bool loops, double now);
};

} // namespace umeshcore
