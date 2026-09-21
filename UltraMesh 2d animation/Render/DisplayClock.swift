import Foundation
import QuartzCore

/// When the frame being built will actually be SEEN.
///
/// The animation is a continuous function of time, sampled once per displayed
/// frame. Which leaves one question that decides whether motion looks smooth:
/// at which instants is it sampled?
///
/// It used to be sampled at `CFAbsoluteTimeGetCurrent()` — the moment the CPU
/// woke up to build the frame. But the frame is not shown then. It is shown at
/// the next vsync, on a grid whose spacing is exactly the refresh interval.
/// Main-thread wake-ups jitter by a fraction of a millisecond to a couple of
/// milliseconds; the display does not jitter at all.
///
/// So the poses were computed for uneven instants and displayed at even ones.
/// On an 8.33 ms frame, a millisecond of wake jitter is twelve per cent of a
/// frame of position error, changing sign from frame to frame. Every sample is
/// exactly on the curve — nothing is dropped, nothing is mis-interpolated — and
/// the motion still shimmers, because the samples are off the beat. Measured in
/// `verify_temporal_quality.py`: constant-velocity motion arrives with 11%
/// frame-to-frame velocity variation with no frames missed at all.
///
/// This reconstructs the grid instead. It is a phase-locked loop:
///
///   * `phase` is the estimated time of vsync zero.
///   * each frame lands on the nearest multiple of the refresh interval from
///     it, so the reported instant is always ON the grid;
///   * `phase` is then nudged toward the observed wake time by a small
///     fraction of the error, so the lock TRACKS the display's slow drift
///     against the CPU's clock without FOLLOWING the wake jitter.
///
/// It cannot drift, because it is locked to wall time. It cannot slow the
/// animation down, because a genuinely missed frame lands two indices along and
/// the animation advances two intervals. And it cannot run the animation fast
/// to catch up, because the index is derived from the clock, never accumulated.
///
/// # The gain
///
/// The one number here, and it is a trade. Large follows the jitter, which is
/// the bug. Small is slow to absorb real drift between two crystals — and a
/// clock that does not track drift eventually reports an index a whole frame
/// out and hitches.
///
/// 0.02 attenuates the wake jitter about fiftyfold and still absorbs 20 ppm of
/// drift with a steady-state lag of roughly a hundredth of a millisecond. The
/// drift test in the harness is what pins it: 4000 frames at 20 ppm, no frame
/// lost.
///
/// # Not `@MainActor`
///
/// Matching `CanvasActivity`: every caller is the render loop, on the main
/// thread by construction.
final class DisplayClock {

    /// A gap longer than this is a stall, not jitter: the app was backgrounded,
    /// a modal loop held the thread, the display changed rate. Re-lock rather
    /// than crawl back at the tracking gain, which would smear the error over
    /// the next thousand frames.
    private static let resyncIntervals: Double = 4

    private static let gain: Double = 0.02

    private(set) var interval: CFTimeInterval = 1.0 / 60.0

    private var phase: CFTimeInterval?
    private var lastIndex: Int = 0

    /// The display's refresh interval. Changing it re-locks: the grid the old
    /// phase referred to no longer exists.
    func setRefreshRate(_ framesPerSecond: Int) {
        guard framesPerSecond > 0 else { return }
        let next = 1.0 / CFTimeInterval(framesPerSecond)
        guard abs(next - interval) > 1e-9 else { return }
        interval = next
        reset()
    }

    /// Forget the lock. The next frame starts a new one.
    func reset() {
        phase = nil
        lastIndex = 0
    }

    /// The instant the frame being built now will be presented.
    ///
    /// - Parameter cpuTime: `CACurrentMediaTime()` at the top of the frame.
    ///   Media time, not `CFAbsoluteTimeGetCurrent()`: it is monotonic, so a
    ///   clock correction cannot teleport the playhead mid-animation.
    func presentationTime(cpuTime: CFTimeInterval) -> CFTimeInterval {
        guard let phase else {
            self.phase = cpuTime
            lastIndex = 0
            return cpuTime + interval
        }

        let offset = (cpuTime - phase) / interval
        var index = Int(offset.rounded())

        if Double(index - lastIndex) > Self.resyncIntervals {
            self.phase = cpuTime
            lastIndex = 0
            return cpuTime + interval
        }

        // Never the same slot twice, and never backwards. macOS draws by hand
        // during a modal drag loop while the link is stalled, so two draws can
        // land inside one refresh; giving them the same instant would render
        // the same pose twice and stall the motion.
        if index <= lastIndex { index = lastIndex + 1 }

        let nominal = phase + CFTimeInterval(index) * interval
        self.phase = phase + Self.gain * (cpuTime - nominal)
        lastIndex = index

        // One interval ahead: what is being built now is shown at the NEXT
        // vsync, and the pose it carries should be the pose for that moment.
        return nominal + interval
    }
}
