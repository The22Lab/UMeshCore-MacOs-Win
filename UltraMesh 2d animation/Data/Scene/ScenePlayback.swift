import Foundation
import QuartzCore

/// Scene's transport: where the playhead is, as a function of wall-clock time.
///
/// ## Why Scene has a clock of its own at all
///
/// It would be tempting to play a Scene with the rig's transport. It is the
/// wrong one twice over. The rig plays on `projectFramesPerSecond` between
/// `playbackStartFrame` and `playbackEndFrame`; a scene has its own
/// `durationInFrames` and its own `fps`, and they are different numbers for a
/// reason — a 24 fps shot can stage a rig animated at 60.
///
/// And it would break the thing Scene is for. A rig instance maps the SCENE
/// frame to its own clip frame through its speed, start offset and loop flag,
/// so three birds from one rig flap out of step. Drive the scene from the rig's
/// playhead and every instance moves together, which is precisely the feature
/// gone.
///
/// ## The one design rule, taken from the rig's transport
///
/// A playback session is `(startTime, startFrame, fps, bounds)` and the
/// playhead is a PURE FUNCTION of the current time. Nothing accumulates.
///
/// That is not tidiness. Scene renders on the CPU, so a heavy set can miss its
/// schedule — and a transport that advanced by a delta each tick would then run
/// SLOW, turning a dropped frame into lost time and drifting away from the
/// audio, the export and the clock on the wall. Derived from the time instead,
/// a frame the machine cannot deliver costs one SAMPLE of the motion and never
/// a step of it. The scene plays at the right speed on a machine that cannot
/// keep up; it simply plays less smoothly.
struct ScenePlayback: Equatable {

    /// What a running transport is, entirely.
    struct Session: Equatable {
        /// `CACurrentMediaTime()` when play was pressed.
        let startTime: CFTimeInterval
        /// The frame the playhead was on then.
        let startFrame: Int
        let framesPerSecond: Double
        /// Inclusive. A scene runs from 0 to `durationInFrames - 1`.
        let lastFrame: Int
        let loops: Bool
    }

    private(set) var session: Session?

    var isPlaying: Bool { session != nil }

    /// Where the playhead should be now, and whether the transport has run out.
    ///
    /// `ended` is only ever true for a session that does not loop: a looping
    /// scene has no end to reach.
    static func playhead(at now: CFTimeInterval, session: Session) -> (frame: Int, ended: Bool) {
        let span = Double(max(session.lastFrame, 0) + 1)
        let elapsed = max(now - session.startTime, 0)
        // FLOOR, not round. A frame is a moment the playhead is ON for the
        // whole of its duration; rounding would show frame 1 for the second
        // half of frame 0, so every frame would appear half a frame early and
        // the first would be half as long as the rest.
        let advanced = Double(session.startFrame) + elapsed * max(session.framesPerSecond, 0.0001)
        // The shot is over when the playhead leaves the last frame, not when it
        // reaches it. A frame is a moment the playhead is on for its whole
        // duration — the same reason the line above floors — so ending at
        // `lastFrame` exactly would cut the final frame short and stop the shot
        // half a frame early.
        guard advanced < Double(session.lastFrame) + 1 else {
            guard session.loops, span > 0 else {
                return (session.lastFrame, true)
            }
            let wrapped = advanced.truncatingRemainder(dividingBy: span)
            return (Int(wrapped.rounded(.down)), false)
        }
        return (Int(advanced.rounded(.down)), false)
    }

    /// Start playing from `frame`.
    ///
    /// From the frame the playhead is ON, not from the start: pressing play in
    /// the middle of a shot to watch the rest of it is what the button is for.
    /// A playhead already at the end rewinds, because otherwise play would be a
    /// button that does nothing.
    mutating func play(from frame: Int, fps: Int, lastFrame: Int, loops: Bool,
                       now: CFTimeInterval = CACurrentMediaTime()) {
        let end = max(lastFrame, 0)
        let begin = frame >= end ? 0 : min(max(frame, 0), end)
        session = Session(startTime: now, startFrame: begin,
                          framesPerSecond: Double(min(max(fps, 1), 240)),
                          lastFrame: end, loops: loops)
    }

    mutating func stop() { session = nil }

    /// Re-anchor a running transport to a new frame, rate or length.
    ///
    /// Called when the artist scrubs while playing, or changes the scene's fps.
    /// Without it the session would still be measuring from where play was
    /// pressed, so a scrub would be undone by the very next tick — the playhead
    /// snapping back is what "the scrubber fights me" is.
    mutating func reanchor(to frame: Int, fps: Int, lastFrame: Int, loops: Bool,
                           now: CFTimeInterval = CACurrentMediaTime()) {
        guard session != nil else { return }
        play(from: frame, fps: fps, lastFrame: lastFrame, loops: loops, now: now)
    }
}
