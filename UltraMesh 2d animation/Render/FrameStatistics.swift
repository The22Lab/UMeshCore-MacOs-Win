import Foundation
import QuartzCore

/// What the frame actually cost, measured on the device rather than guessed.
///
/// An average frame rate hides the thing that is felt. These two sequences both
/// read as "60 fps":
///
///     16.7  16.7  16.7  16.7  16.7      smooth
///     16.7  16.7  33.3  16.7  16.7      a visible hitch, five times a second
///
/// So the numbers that matter here are the DISTRIBUTION and the outliers —
/// P95, P99, the worst interval, and how many display refreshes went by with no
/// new frame in them. A mean is reported only because its absence would be
/// suspicious.
///
/// # What is timed
///
/// The frame is split at the boundaries that can each be fixed independently:
///
///   * `animation` — the clip evaluated and the model posed (`tickPlayback`).
///   * `solve`     — the skeleton and its constraints, IK, paths, physics.
///   * `encode`    — building vertices, uploading buffers, encoding draws.
///   * `drawable`  — time spent BLOCKED waiting for a drawable to draw into.
///                   This is the one that is invisible in a profiler summary
///                   and dominates a badly ordered frame.
///   * `gpu`       — from the command buffer's own timestamps.
///
/// # Cost when it is off
///
/// One boolean test per phase. The sample ring is preallocated and never grows,
/// and nothing is formatted until `summary()` is asked for. Enable with a launch
/// argument or environment variable, so a build can be profiled without a
/// setting to forget to turn off:
///
///     ULTRAMESH_FRAME_STATS=1        (scheme environment variable)
///     -ULTRAMESH_FRAME_STATS 1       (launch argument)
///
/// While enabled it prints a summary to the console every `reportInterval`
/// seconds. On a device that is where these numbers can actually be read.
final class FrameStatistics {

    static let shared = FrameStatistics()

    /// Phases of one frame, each fixable on its own.
    enum Phase: Int, CaseIterable {
        case animation
        case solve
        case encode
        case drawable

        var label: String {
            switch self {
            case .animation: return "animation"
            case .solve:     return "solve"
            case .encode:    return "encode"
            case .drawable:  return "drawable wait"
            }
        }
    }

    private struct Sample {
        var interval: Double = 0
        var cpu: Double = 0
        var gpu: Double = 0
        /// From the frame starting on the CPU to the drawable actually being
        /// on screen, from `CAMetalDrawable.presentedTime`. The only number
        /// here that is measured rather than inferred, and the one that says
        /// whether buffering is costing responsiveness.
        var presentLatency: Double = 0
        /// When the drawable was actually shown. Successive values are the
        /// real presented rate — distinct from how often `draw(in:)` ran,
        /// which is what an fps counter reports.
        var presentedAt: Double = 0
        var phases: [Double] = Array(repeating: 0, count: Phase.allCases.count)
        /// True when this frame drew the same animation time as the one before,
        /// i.e. the work produced no new motion.
        var isDuplicatePose: Bool = false
    }

    /// Two seconds at 120 Hz. A ring, so a long session costs nothing extra.
    private static let capacity = 240
    private static let reportInterval: CFTimeInterval = 2.0

    let isEnabled: Bool

    private var samples: [Sample]
    private var writeIndex = 0
    private var filled = 0

    private var current = Sample()
    private var phaseStart = [CFTimeInterval](repeating: 0, count: Phase.allCases.count)
    private var frameStart: CFTimeInterval = 0
    private var lastFrameStart: CFTimeInterval = 0
    /// When each slot's frame began, so the presented handler — which arrives
    /// long after the frame is over — can subtract.
    private var frameStartBySlot = [CFTimeInterval](repeating: 0, count: FrameStatistics.capacity)
    private var lastReport: CFTimeInterval = 0
    private var lastAnimationTime: Double = .nan

    /// The refresh interval frames are being judged against, set by the view.
    private(set) var expectedInterval: Double = 1.0 / 60.0

    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        let environment = ProcessInfo.processInfo.environment
        isEnabled = environment["ULTRAMESH_FRAME_STATS"] == "1"
            || arguments.contains("-ULTRAMESH_FRAME_STATS")
        samples = Array(repeating: Sample(), count: Self.capacity)
    }

    func setDisplayRefreshRate(_ framesPerSecond: Int) {
        guard isEnabled, framesPerSecond > 0 else { return }
        expectedInterval = 1.0 / Double(framesPerSecond)
    }

    // MARK: - Recording

    func beginFrame(animationTime: Double) {
        guard isEnabled else { return }
        let now = CACurrentMediaTime()
        current = Sample()
        // A frame that draws the same pose as the one before did work and
        // produced no motion. A run of these is what a stepped clip on a fast
        // display looks like from the inside.
        current.isDuplicatePose = animationTime == lastAnimationTime
        lastAnimationTime = animationTime
        if lastFrameStart > 0 { current.interval = now - lastFrameStart }
        lastFrameStart = now
        frameStart = now
    }

    func begin(_ phase: Phase) {
        guard isEnabled else { return }
        phaseStart[phase.rawValue] = CACurrentMediaTime()
    }

    func end(_ phase: Phase) {
        guard isEnabled else { return }
        current.phases[phase.rawValue] += CACurrentMediaTime() - phaseStart[phase.rawValue]
    }

    /// Called once the frame is encoded and committed. `gpu` arrives later,
    /// from the command buffer's completion handler, so it is folded into the
    /// sample that is already stored.
    func endFrame() -> Int {
        guard isEnabled else { return -1 }
        current.cpu = CACurrentMediaTime() - frameStart
        let slot = writeIndex
        samples[slot] = current
        frameStartBySlot[slot] = frameStart
        writeIndex = (writeIndex + 1) % Self.capacity
        filled = min(filled + 1, Self.capacity)
        reportIfDue()
        return slot
    }

    /// When the drawable for `slot` was actually put on screen, from
    /// `CAMetalDrawable.presentedTime`.
    ///
    /// This is the only ground truth about pacing in the whole file. Everything
    /// else measures when the app did something; this measures when the
    /// display did. A stream that submits perfectly evenly and is presented
    /// unevenly looks fine by every other metric here.
    func recordPresented(at presentedTime: Double, forSlot slot: Int) {
        guard isEnabled, slot >= 0, slot < Self.capacity, presentedTime > 0 else { return }
        DispatchQueue.main.async {
            self.samples[slot].presentedAt = presentedTime
            let started = self.frameStartBySlot[slot]
            if started > 0 {
                self.samples[slot].presentLatency = presentedTime - started
            }
        }
    }

    /// GPU time for a frame, from `MTLCommandBuffer.gpuEndTime - gpuStartTime`.
    /// Arrives after the frame is over; `slot` is what `endFrame` returned.
    ///
    /// A command buffer's completion handler runs on whatever thread Metal
    /// feels like, so this hops to the main thread before touching the ring.
    /// Everything else here is main-thread-only by construction, and a
    /// measurement tool that introduces a data race is worse than no
    /// measurement. `isEnabled` is a `let`, so reading it from here is safe.
    func recordGPUTime(_ seconds: Double, forSlot slot: Int) {
        guard isEnabled, slot >= 0, slot < Self.capacity else { return }
        DispatchQueue.main.async {
            self.samples[slot].gpu = seconds
        }
    }

    // MARK: - Reading

    private func window() -> [Sample] {
        guard filled > 0 else { return [] }
        if filled < Self.capacity { return Array(samples[0..<filled]) }
        return Array(samples[writeIndex...]) + Array(samples[..<writeIndex])
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let position = fraction * Double(sorted.count - 1)
        let low = Int(position.rounded(.down))
        let high = min(low + 1, sorted.count - 1)
        let blend = position - Double(low)
        return sorted[low] * (1 - blend) + sorted[high] * blend
    }

    private static func line(_ label: String, _ values: [Double]) -> String {
        guard !values.isEmpty else { return "  \(label): no samples" }
        let sorted = values.sorted()
        let mean = values.reduce(0, +) / Double(values.count)
        // The column is padded in Swift rather than with a `%-14@` field:
        // width flags on `%@` are not dependable across the format
        // implementations, and a report that misaligns is a report nobody
        // reads.
        let column = label.padding(toLength: 14, withPad: " ", startingAt: 0)
        return "  " + column + String(
            format: "mean %6.2f  min %6.2f  p50 %6.2f  p95 %6.2f  p99 %6.2f  max %6.2f",
            mean * 1000,
            sorted.first! * 1000,
            percentile(sorted, 0.50) * 1000,
            percentile(sorted, 0.95) * 1000,
            percentile(sorted, 0.99) * 1000,
            sorted.last! * 1000
        )
    }

    /// Everything measured, in milliseconds, as text meant to be read in a
    /// console capture.
    func summary() -> String {
        let window = self.window()
        guard window.count > 1 else { return "frame stats: not enough samples yet" }

        // The first sample has no interval (nothing preceded it).
        let intervals = window.dropFirst().map(\.interval)
        var out: [String] = []
        out.append(String(format: "── frame statistics ── %d frames, display %.1f Hz",
                          window.count, 1 / expectedInterval))
        out.append(Self.line("interval", intervals))
        out.append(Self.line("cpu", window.map(\.cpu)))
        let gpuTimes = window.map(\.gpu).filter { $0 > 0 }
        out.append(Self.line("gpu", gpuTimes))
        let latencies = window.map(\.presentLatency).filter { $0 > 0 }
        out.append(Self.line("present lat", latencies))
        for phase in Phase.allCases {
            out.append(Self.line(phase.label, window.map { $0.phases[phase.rawValue] }))
        }

        // A missed refresh is an interval long enough to have contained
        // another one. This is what the eye reads as a hitch, and it is
        // invisible in a mean.
        let expected = expectedInterval
        var missed = 0
        var worstRun = 0.0
        for interval in intervals where interval > expected * 1.5 {
            missed += Int((interval / expected).rounded()) - 1
            worstRun = max(worstRun, interval)
        }
        let duplicates = window.filter(\.isDuplicatePose).count

        // Jitter: mean absolute deviation between consecutive intervals. A
        // perfectly paced stream is 0 no matter what the rate is, so this
        // separates "slow" from "uneven" — which a frame rate cannot.
        var jitter = 0.0
        let list = Array(intervals)
        if list.count > 1 {
            for (a, b) in zip(list, list.dropFirst()) { jitter += abs(b - a) }
            jitter /= Double(list.count - 1)
        }

        // PRESENTED rate, from the display's own timestamps. `draw(in:)`
        // running 120 times a second says nothing about how many distinct
        // images reached the glass.
        let presented = window.map(\.presentedAt).filter { $0 > 0 }.sorted()
        var presentedLine = "  presented: no timestamps yet"
        if presented.count > 1 {
            let gaps = zip(presented, presented.dropFirst()).map { $1 - $0 }
            let span = presented.last! - presented.first!
            let late = gaps.filter { $0 > expectedInterval * 1.5 }.count
            presentedLine = String(
                format: "  presented %.1f fps over %d frames, %d gaps longer than a refresh",
                Double(gaps.count) / max(span, 1e-9), presented.count, late)
        }
        out.append(presentedLine)

        let effective = intervals.isEmpty
            ? 0 : Double(intervals.count) / intervals.reduce(0, +)
        out.append(String(
            format: "  effective %.1f fps   missed refreshes %d   worst gap %.2f ms   jitter %.2f ms",
            effective, missed, worstRun * 1000, jitter * 1000))
        out.append(String(
            format: "  frames drawing an unchanged pose: %d of %d (%.0f%%)",
            duplicates, window.count,
            100 * Double(duplicates) / Double(window.count)))
        return out.joined(separator: "\n")
    }

    private func reportIfDue() {
        let now = CACurrentMediaTime()
        guard now - lastReport >= Self.reportInterval else { return }
        lastReport = now
        print(summary())
    }
}
