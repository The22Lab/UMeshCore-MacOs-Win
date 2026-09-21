import Foundation
import simd

/// The one authority on what a Bézier animation segment IS.
///
/// Graph, Canvas, playback, preview and export all get their geometry from
/// here, so the curve an animator sees drawn is the curve that plays. That was
/// not true before, and not by a rounding error — there were three separate
/// implementations of "where do the control points go", and they disagreed in
/// three different ways. `Editor/verify_curve_authority.py` measures each:
///
///   * AUTO TANGENTS. The evaluator flattens a tangent at a turning point, so
///     a curve cannot climb past the key it just left. The graph's own
///     `smoothAutoTangent` had no such clamp and drew the overshoot — measured
///     at 100.65 against a keyframe of 100, on a curve playback holds at
///     exactly 100.
///
///   * CLAMPING. The evaluator pins a control point's x inside its segment.
///     The graph drew it wherever the handle was dragged to, so a handle
///     pulled past the next key drew an S-bend that differed from what played
///     by 90 units of value.
///
///   * THE FALLBACK. A third of the span with zero slope, against 0.35 and
///     0.65 of it. A different curve again.
///
/// So this type is not a tidy-up. It is the fix, and the reason it is a type
/// rather than a rule written down twice is that a rule written down twice is
/// what produced all three.
enum AnimationCurve {

    /// A segment's four Bézier points, in (time, value).
    struct Segment {
        /// The keyframe the segment leaves.
        var start: SIMD2<Float>
        /// Its out control point.
        var control1: SIMD2<Float>
        /// The next keyframe's in control point.
        var control2: SIMD2<Float>
        /// The keyframe it arrives at.
        var end: SIMD2<Float>
    }

    /// The slope an untangented keyframe is given.
    ///
    /// FLATTENED AT A TURNING POINT — `rising * falling <= 0` — which is what
    /// stops an auto-curve overshooting past a local maximum. Derived, never
    /// stored: nothing writes this into a keyframe, so an animator's own
    /// tangents and every animation already saved are untouched by it.
    static func autoSlope(previous: (frame: Int, value: Float)?,
                          current: (frame: Int, value: Float),
                          next: (frame: Int, value: Float)?) -> Float {
        autoSlope(previous: previous.map { (x: Float($0.frame), value: $0.value) },
                  current: (x: Float(current.frame), value: current.value),
                  next: next.map { (x: Float($0.frame), value: $0.value) },
                  minimumSpan: Self.frameSpanFloor)
    }

    /// The same rule on a CONTINUOUS axis.
    ///
    /// Lighting needs it: a falloff curve's stops sit at normalised distances
    /// in [0, 1], not at frames, and the alternative — a second curve engine
    /// for lights — is exactly the "colección de herramientas pegadas" this
    /// editor keeps refusing to become. So the float version is the
    /// implementation and the frame version above is an adapter, rather than
    /// the two being transcriptions of one rule.
    ///
    /// `minimumSpan` is the reason it is a parameter and not a constant. On the
    /// frame axis the floor is ONE FRAME, which is the smallest real gap
    /// between two keys and guards the two-keys-on-one-frame case. On a
    /// normalised axis a floor of 1 would swallow the entire domain and flatten
    /// every falloff curve to a straight line — the same number meaning
    /// opposite things on the two axes is precisely how a shared function goes
    /// wrong quietly, so neither axis gets to inherit the other's.
    static func autoSlope(previous: (x: Float, value: Float)?,
                          current: (x: Float, value: Float),
                          next: (x: Float, value: Float)?,
                          minimumSpan: Float) -> Float {
        if let previous, let next {
            let rising = current.value - previous.value
            let falling = next.value - current.value
            if rising * falling <= 0 { return 0 }
            return (next.value - previous.value) / max(next.x - previous.x, minimumSpan)
        }
        if let previous {
            return (current.value - previous.value) / max(current.x - previous.x, minimumSpan)
        }
        if let next {
            return (next.value - current.value) / max(next.x - current.x, minimumSpan)
        }
        return 0
    }

    /// One frame. Keys live on integers, so nothing smaller is a real gap.
    static let frameSpanFloor: Float = 1
    /// A normalised axis runs 0...1 whole, so its floor has to be small enough
    /// to be invisible against that range and large enough to stop a division
    /// by a gap of zero.
    static let normalisedSpanFloor: Float = 1e-6

    /// The segment between two keyframes, tangents resolved and clamped.
    ///
    /// `outTangent` and `inTangent` are the authored ones when they exist; nil
    /// asks for the auto tangent, which needs the neighbours on either side.
    static func segment(
        start: (frame: Int, value: Float),
        end: (frame: Int, value: Float),
        outTangent: SIMD2<Float>?,
        inTangent: SIMD2<Float>?,
        beforeStart: (frame: Int, value: Float)?,
        afterEnd: (frame: Int, value: Float)?
    ) -> Segment {
        segment(start: (x: Float(start.frame), value: start.value),
                end: (x: Float(end.frame), value: end.value),
                outTangent: outTangent, inTangent: inTangent,
                beforeStart: beforeStart.map { (x: Float($0.frame), value: $0.value) },
                afterEnd: afterEnd.map { (x: Float($0.frame), value: $0.value) },
                minimumSpan: Self.frameSpanFloor)
    }

    /// The same segment on a CONTINUOUS axis — see `autoSlope` above for why
    /// this direction of delegation, and for what `minimumSpan` is.
    static func segment(
        start: (x: Float, value: Float),
        end: (x: Float, value: Float),
        outTangent: SIMD2<Float>?,
        inTangent: SIMD2<Float>?,
        beforeStart: (x: Float, value: Float)?,
        afterEnd: (x: Float, value: Float)?,
        minimumSpan: Float
    ) -> Segment {
        let span = max(end.x - start.x, minimumSpan)
        let p0 = SIMD2<Float>(start.x, start.value)
        let p3 = SIMD2<Float>(end.x, end.value)

        let out: SIMD2<Float>
        if let outTangent {
            out = outTangent
        } else {
            let slope = autoSlope(previous: beforeStart, current: start, next: end,
                                  minimumSpan: minimumSpan)
            let x = span / 3
            out = SIMD2<Float>(x, slope * x)
        }

        let incoming: SIMD2<Float>
        if let inTangent {
            incoming = inTangent
        } else {
            let slope = autoSlope(previous: start, current: end, next: afterEnd,
                                  minimumSpan: minimumSpan)
            let x = -span / 3
            incoming = SIMD2<Float>(x, slope * x)
        }

        var p1 = p0 + out
        var p2 = p3 + incoming
        // Inside the segment, both of them. A control point outside it makes
        // x(t) non-monotonic, which means a time with two values — and the
        // solver would answer with whichever it found first. Clamping is what
        // keeps "a time has one value" true, and it is why the drawing has to
        // clamp as well: an animator dragging a handle must see it stop where
        // the curve stops honouring it.
        p1.x = min(max(p1.x, p0.x), p3.x)
        p2.x = min(max(p2.x, p0.x), p3.x)
        return Segment(start: p0, control1: p1, control2: p2, end: p3)
    }

    /// A cubic Bézier component at `t`.
    static func value(_ t: Float, _ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float) -> Float {
        let u = 1 - t
        return (u * u * u * p0) + (3 * u * u * t * p1) + (3 * u * t * t * p2) + (t * t * t * p3)
    }

    /// Its derivative, which Newton needs.
    static func slope(_ t: Float, _ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float) -> Float {
        let u = 1 - t
        return (3 * u * u * (p1 - p0)) + (6 * u * t * (p2 - p1)) + (3 * t * t * (p3 - p2))
    }

    /// The parameter at which the curve reaches time `x`.
    ///
    /// Newton inside a bisection bracket, keeping the best answer it has seen.
    /// It replaces eighteen plain bisections — which were ACCURATE ENOUGH, at
    /// 2.8e-6 of normalised time, and saying otherwise would be inventing a
    /// fault. What they were not is cheap: measured in
    /// `verify_curve_authority.py`, reaching 1e-7 takes 23 bisections and 6 of
    /// these, and each step is a cubic evaluation paid per component, per
    /// property, per sprite, per frame.
    ///
    /// Three details decide whether this is better than bisection or worse,
    /// and a first attempt at it got all three wrong and scored worse:
    ///
    ///   * stop when converged — otherwise it walks away from an exact answer;
    ///   * accept a step ON the bracket edge, because landing there is what
    ///     converging onto it looks like, and rejecting it throws the answer
    ///     away;
    ///   * return the best t seen, so a poor final step cannot undo good ones.
    static func parameter(forTime x: Float,
                          _ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float) -> Float {
        var low: Float = 0
        var high: Float = 1
        var t: Float = 0.5
        var bestT = t
        var bestError = Float.greatestFiniteMagnitude

        for _ in 0..<Self.solverIterations {
            let error = value(t, p0, p1, p2, p3) - x
            let magnitude = abs(error)
            if magnitude < bestError {
                bestError = magnitude
                bestT = t
            }
            if magnitude <= Self.solverTolerance { return t }
            if error > 0 { high = t } else { low = t }

            let derivative = slope(t, p0, p1, p2, p3)
            guard abs(derivative) > 1e-9 else {
                t = (low + high) * 0.5
                continue
            }
            let step = t - error / derivative
            t = (step >= low && step <= high) ? step : (low + high) * 0.5
        }
        return abs(value(t, p0, p1, p2, p3) - x) < bestError ? t : bestT
    }

    /// Enough for the tolerance below with room to spare, and a hard ceiling so
    /// a degenerate curve cannot spin.
    static let solverIterations = 10
    /// Normalised time. Below what a single display pixel can show at any zoom
    /// the graph offers.
    static let solverTolerance: Float = 1e-7

    /// The value this segment holds at `time`.
    static func value(of segment: Segment, atTime time: Float) -> Float {
        let t = parameter(forTime: time,
                          segment.start.x, segment.control1.x,
                          segment.control2.x, segment.end.x)
        return value(t, segment.start.y, segment.control1.y,
                     segment.control2.y, segment.end.y)
    }
}
