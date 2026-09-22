#pragma once

// 1:1 port of `Render/SceneRenderBudget.swift` -- how many pixels a Scene
// frame is allowed, as a ladder that MEASURES rather than a cap that is
// chosen.
//
// WHY IT EXISTS. A fixed cap has to be chosen for the worst machine and
// the heaviest set, which makes it wrong for every other combination: too
// low and a fast machine shows a soft picture it could easily have drawn
// sharp, too high and a slow one drops half its frames while the artist is
// orbiting. So the renderer reports what the last frames cost, and the
// ladder steps down until they fit and back up when they comfortably do.
//
// WHY IT IS STILL SHARED CODE ON THE GPU PATH. The Swift header's premise
// is that Scene composites on the CPU, so a frame costs very nearly its
// pixel count. The GPU path this phase targets is faster, but the shape of
// the problem is identical -- a resolution ladder driven by measured frame
// time -- and the two failure modes below are properties of the LADDER,
// not of the rasterizer. A Metal shell and a DirectX shell each inventing
// their own would give the same artist two different pulsing behaviours on
// two machines. The one number worth revisiting per backend is the target
// frame time; it is a constant here, not a hidden assumption.
//
// THE TWO THINGS AN ADAPTIVE LADDER GETS WRONG, both fixed here:
//
//   - OSCILLATION. Step down when slow and up when fast, with one
//     threshold, and the step up makes it slow again: the picture visibly
//     pulses between two sharpnesses, which is worse than either. Fixed by
//     PREDICTING the rung above (cost goes as pixels, pixels go as the
//     square of the scale) and requiring the headroom to have LASTED -- a
//     frame is cheap-looking for all sorts of reasons, and one of them is
//     that it was drawn at half size.
//   - RATCHETING. One expensive frame -- a mesh edit, a project opening, a
//     sheet coming down -- must not leave the canvas soft for the rest of
//     the session. So the ladder returns to the top the moment the reason
//     for being down goes away.

#include <cstddef>
#include <vector>

namespace umeshcore {

class SceneRenderBudget {
public:
    // The rungs, as fractions of the full cap.
    //
    // Geometric and shallow-ended: 1.0 -> 0.75 is a quarter of the work,
    // which is enough to matter and small enough not to be seen; further
    // down the steps are larger because by then the picture is already
    // provisional and what matters is catching up.
    static constexpr int kLadderSize = 5;
    static constexpr float kLadder[kLadderSize] = {1.0f, 0.75f, 0.5f, 0.35f, 0.25f};

    // The frame time the ladder aims at while the artist is moving.
    //
    // Not 1/60. A drag or an orbit is answered on the next frame either
    // way, and 1/30 leaves headroom for the rest of the app on a machine
    // also running an editor, a timeline and a preview. Aiming at 60 means
    // living at the bottom of the ladder for a picture nobody can see the
    // difference in while it is moving.
    static constexpr double kInteractiveTargetMilliseconds = 33.0;

    // How much of the budget the rung above has to be PREDICTED to fit in
    // before the ladder climbs to it.
    //
    // The climb is decided by predicting the next rung's cost, not by
    // whether the current one is comfortable -- and that difference is the
    // whole difference between a ladder that settles and one that pulses.
    // A fixed "climb when under 60% of target" was the first attempt and
    // it oscillates: at half size a machine measures 15 ms against a 33 ms
    // budget, which looks like plenty of room, so it climbs to three
    // quarters -- where the same machine takes 34 ms and is dropped
    // straight back, then does it again nine frames later.
    static constexpr double kClimbSafety = 0.9;

    // How many consecutive comfortable frames it takes to climb one rung.
    // One is not evidence: the cheapest frame in any sequence is the one
    // where nothing moved. Eight at 30 fps is a quarter of a second of
    // steady headroom -- short enough not to be waited for, long enough
    // not to be a coincidence.
    static constexpr int kFramesBeforeClimbing = 8;

    int rung() const { return rung_; }
    int comfortableFrames() const { return comfortableFrames_; }
    float scale() const;

    // Report what the last frame cost, and move the ladder if it should.
    //
    // `isProvisional` is true while the artist is moving or the shot is
    // playing -- the only times a soft picture is the right answer. When
    // it is false the ladder goes straight back to the top, because a
    // still canvas has all the time in the world and a soft one is simply
    // a worse picture.
    void record(double milliseconds, bool isProvisional);

    // Back to the top. Called when the reason for being down has gone.
    void reset();

    // The longest edge to render, given the full cap.
    //
    // A CEILING, never a target: a viewport already smaller than the cap
    // is left alone. Upscaling a small viewport to meet a cap would be
    // paying for pixels nobody asked for and then throwing them away.
    float pixelCap(float full) const { return full * scale(); }

private:
    int rung_ = 0;
    int comfortableFrames_ = 0;
};

// A rolling average of what the last few frames cost.
//
// Averaged because one frame says very little: the first frame after a
// change pays for every cache it missed, and a ladder driven by that alone
// would drop a rung every time anything happened. Short, so it still
// follows a genuine change in the set within a few frames.
class FrameCostMeter {
public:
    static constexpr std::size_t kWindow = 6;

    void record(double milliseconds);

    // The MEDIAN, not the mean.
    //
    // One frame that took eighty milliseconds because the app was
    // launching drags a six-frame mean past the target and costs a rung.
    // The median ignores it, which is the whole reason to prefer it here:
    // the ladder is meant to follow what the machine is SUSTAINING, not
    // what happened once.
    double milliseconds() const;

    bool hasSamples() const { return !samples_.empty(); }
    void reset() { samples_.clear(); }

private:
    std::vector<double> samples_;
};

} // namespace umeshcore
