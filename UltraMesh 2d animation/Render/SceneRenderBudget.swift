import Foundation

/// How many pixels Scene is allowed to render this frame.
///
/// ## Why this exists
///
/// Scene composites on the CPU, so the cost of a frame is very nearly the
/// number of pixels in it. A fixed cap has to be chosen for the worst machine
/// and the heaviest set, which makes it wrong for every other combination: too
/// low and a MacBook Pro shows a soft picture it could easily have drawn sharp,
/// too high and an iPad drops half its frames while the artist is orbiting.
///
/// So the cap is not chosen. It is MEASURED — the renderer reports how long the
/// last frames took, and the ladder steps down until they fit the budget and
/// back up when they comfortably do.
///
/// ## The two things an adaptive ladder gets wrong
///
/// **Oscillation.** Step down when slow and up when fast, with one threshold,
/// and the step up makes it slow again — a picture that visibly pulses between
/// two sharpnesses, which is worse than either. Fixed by making the step-up
/// threshold far below the step-down one and requiring the headroom to have
/// LASTED: a frame is cheap-looking for all sorts of reasons, and one of them
/// is that it was drawn at half size.
///
/// **Ratcheting.** One expensive frame — a mesh edit, a project opening, a
/// sheet coming down — should not leave the canvas soft for the rest of the
/// session. So the ladder returns to the top whenever the reason for being
/// down goes away: the artist stops moving, the shot stops playing.
struct SceneRenderBudget {

    /// The rungs, as fractions of the full cap.
    ///
    /// Geometric and shallow-ended: 1.0 → 0.75 is a quarter of the work, which
    /// is enough to matter and small enough not to be seen; further down the
    /// steps are larger because by then the picture is already provisional and
    /// what matters is catching up.
    static let ladder: [Float] = [1.0, 0.75, 0.5, 0.35, 0.25]

    /// The frame time the ladder aims at while the artist is moving.
    ///
    /// Not 1/60. A drag or an orbit is answered on the next frame either way,
    /// and 1/30 leaves headroom for the rest of the app on a machine that is
    /// also running an editor, a timeline and a preview. Aiming at 60 on a CPU
    /// compositor means living at the bottom of the ladder for a picture nobody
    /// can see the difference in while it is moving.
    static let interactiveTargetMilliseconds: Double = 33

    /// How much of the budget the rung above has to be PREDICTED to fit in
    /// before the ladder climbs to it.
    ///
    /// The climb is decided by predicting the next rung's cost, not by whether
    /// the current one is comfortable — and the difference is the whole
    /// difference between a ladder that settles and one that pulses.
    ///
    /// A fixed "climb when under 60% of target" was the first attempt and it
    /// oscillates, which the harness caught: at half size a machine measures
    /// 15 ms against a 33 ms budget, which looks like plenty of room, so it
    /// climbs to three quarters — where the same machine takes 34 ms and is
    /// dropped straight back. Nine frames later it does it again. The picture
    /// visibly pulses between two sharpnesses, which is worse than either.
    ///
    /// Cost goes as the pixels, which go as the square of the scale, so the
    /// rung above costs `(next / current)²` times what this one does. Predict
    /// that, and climb only if it lands inside the budget with this much room
    /// to spare.
    static let climbSafety: Double = 0.9

    /// How many consecutive comfortable frames it takes to climb one rung.
    ///
    /// One is not evidence: the cheapest frame in any sequence is the one where
    /// nothing moved. Eight at 30 fps is a quarter of a second of steady
    /// headroom, which is short enough not to be waited for and long enough not
    /// to be a coincidence.
    static let framesBeforeClimbing = 8

    /// Which rung the ladder is on, and how long it has been comfortable.
    private(set) var rung: Int = 0
    private(set) var comfortableFrames: Int = 0

    var scale: Float { Self.ladder[min(max(rung, 0), Self.ladder.count - 1)] }

    /// Report what the last frame cost, and move the ladder if it should.
    ///
    /// `isProvisional` is true while the artist is moving or the shot is
    /// playing — the only times a soft picture is the right answer. When it is
    /// false the ladder goes straight back to the top, because a still canvas
    /// has all the time in the world and a soft one is simply a worse picture.
    mutating func record(milliseconds: Double, isProvisional: Bool) {
        guard isProvisional else {
            rung = 0
            comfortableFrames = 0
            return
        }
        let target = Self.interactiveTargetMilliseconds
        if milliseconds > target {
            // ONE RUNG AT A TIME, however slow the frame was. A single
            // catastrophic frame — a sheet animating over the canvas, the
            // project being opened — is not evidence about the steady state,
            // and dropping three rungs for it would take three seconds of good
            // frames to undo.
            rung = min(rung + 1, Self.ladder.count - 1)
            comfortableFrames = 0
            return
        }
        guard rung > 0 else {
            comfortableFrames = 0
            return
        }
        // WOULD THE RUNG ABOVE FIT? Cost goes as the pixels and the pixels go
        // as the square of the scale, so the answer is this frame's cost times
        // the square of the ratio between the two rungs.
        let next = Self.ladder[rung - 1]
        let ratio = Double(next / Self.ladder[rung])
        let predicted = milliseconds * ratio * ratio
        guard predicted <= target * Self.climbSafety else {
            // Comfortable here, and would not be up there. Stay, and do not
            // accumulate credit towards a climb that would only be undone.
            comfortableFrames = 0
            return
        }
        comfortableFrames += 1
        if comfortableFrames >= Self.framesBeforeClimbing {
            rung -= 1
            comfortableFrames = 0
        }
    }

    /// Back to the top. Called when the reason for being down has gone.
    mutating func reset() {
        rung = 0
        comfortableFrames = 0
    }

    /// The longest edge to render, given the full cap.
    ///
    /// A CEILING, never a target: a viewport already smaller than the cap is
    /// left alone. Upscaling a small viewport to meet a cap would be paying for
    /// pixels nobody asked for and then throwing them away.
    func pixelCap(full: Float) -> Float { full * scale }
}

/// A rolling average of what the last few frames cost.
///
/// Averaged because one frame says very little: the first frame after a change
/// pays for every cache it missed, and a ladder driven by that alone would drop
/// a rung every time anything happened. Short, so it still follows a genuine
/// change in the set within a few frames.
struct FrameCostMeter {
    static let window = 6

    private var samples: [Double] = []

    mutating func record(_ milliseconds: Double) {
        samples.append(milliseconds)
        if samples.count > Self.window { samples.removeFirst(samples.count - Self.window) }
    }

    /// The MEDIAN, not the mean.
    ///
    /// One frame that took eighty milliseconds because the app was launching
    /// drags a six-frame mean past the target and costs a rung. The median
    /// ignores it, which is the whole reason to prefer it here: the ladder is
    /// meant to follow what the machine is sustaining, not what happened once.
    var milliseconds: Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    var hasSamples: Bool { !samples.isEmpty }

    mutating func reset() { samples.removeAll(keepingCapacity: true) }
}
