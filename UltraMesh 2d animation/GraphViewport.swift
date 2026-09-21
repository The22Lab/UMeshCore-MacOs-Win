import CoreGraphics
import Foundation

/// What part of the curve the Graph Editor is looking at, and the only place
/// time and value become pixels.
///
/// The editor used to have no viewport. Two functions did the mapping:
///
///     graphXPosition = width * frame / totalFrames        // the whole clip, always
///     graphYPosition = normalised into `graphValueRange`
///
/// and `graphValueRange` was derived, on every layout, from the KEYFRAME
/// VALUES: the minimum and maximum of `samples.map(\.value)`, padded 18%. That
/// is the bug in the report. A Bézier handle is not a keyframe value, and
/// neither is the curve between two keys — a cubic can overshoot well past both
/// of its ends. So a handle dragged out any distance, and the curve it
/// produces, mapped outside `[0, height]` and were clipped by the frame. The
/// curve was being cropped to fit a rectangle derived from something that is
/// not the curve.
///
/// # The rule this type exists to enforce
///
/// The curve and the viewport are independent. A curve may take any value it
/// likes; the viewport is what moves. Nothing here ever clamps a value to fit
/// the view — `fitting(_:)` moves the view to the values instead, and it
/// measures the CURVE, including its handles and its true extrema, not the
/// keyframes.
///
/// # Precision
///
/// Everything is `Double` and every mapping has an exact inverse. A drag reads
/// a pixel, converts to time and value, and the value it stores round-trips
/// back to the pixel it came from — so a handle dragged slowly at high zoom
/// moves by exactly what the pointer moved, with no accumulating drift.
/// Nothing rounds to whole frames or whole pixels on the way through.
struct GraphViewport: Equatable {

    /// Visible span in frames. Fractional on purpose: at high zoom a single
    /// frame can be wider than the editor.
    var timeRange: ClosedRange<Double>
    /// Visible span in the property's own units.
    var valueRange: ClosedRange<Double>

    static let neutral = GraphViewport(timeRange: 0...60, valueRange: -1...1)

    /// Below this the ranges are degenerate and every mapping divides by
    /// nothing. It bounds how far in a zoom may go, and it is far finer than
    /// anything an artist can express.
    private static let minimumSpan: Double = 1e-6

    init(timeRange: ClosedRange<Double>, valueRange: ClosedRange<Double>) {
        self.timeRange = GraphViewport.sanitised(timeRange)
        self.valueRange = GraphViewport.sanitised(valueRange)
    }

    /// A usable range: finite, and never narrower than the floor.
    ///
    /// `anchor`, when given, is a point that must stay where it is in the view.
    /// Without it the floor RE-CENTRES — and every zoom step past the floor
    /// then drags the picture, so the point under the cursor walks away.
    /// Measured in `verify_curve_authority.py`: ninety zoom steps moved it
    /// 262% of the view's width. The floor decides how WIDE the view is; it
    /// has no business deciding where it sits.
    private static func sanitised(_ range: ClosedRange<Double>,
                                  holding anchor: Double? = nil) -> ClosedRange<Double> {
        let lower = range.lowerBound.isFinite ? range.lowerBound : 0
        let upper = range.upperBound.isFinite ? range.upperBound : lower + 1
        let span = upper - lower
        guard span < minimumSpan else { return lower...upper }

        guard let anchor, anchor.isFinite, span > 0 else {
            let centre = (lower + upper) * 0.5
            return (centre - minimumSpan * 0.5)...(centre + minimumSpan * 0.5)
        }
        // Widen to the floor around the anchor, keeping it at the same FRACTION
        // of the view it was already at.
        let share = min(max((anchor - lower) / span, 0), 1)
        let newLower = anchor - minimumSpan * share
        return newLower...(newLower + minimumSpan)
    }

    var timeSpan: Double { timeRange.upperBound - timeRange.lowerBound }
    var valueSpan: Double { valueRange.upperBound - valueRange.lowerBound }

    // MARK: - Mapping, both ways

    func x(forTime time: Double, width: CGFloat) -> CGFloat {
        CGFloat((time - timeRange.lowerBound) / timeSpan) * width
    }

    func time(forX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return timeRange.lowerBound }
        return timeRange.lowerBound + (Double(x / width) * timeSpan)
    }

    /// Y grows downward in the view and values grow upward, so this flips.
    func y(forValue value: Double, height: CGFloat) -> CGFloat {
        height - CGFloat((value - valueRange.lowerBound) / valueSpan) * height
    }

    func value(forY y: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return valueRange.lowerBound }
        return valueRange.lowerBound + (Double((height - y) / height) * valueSpan)
    }

    /// How much value a vertical drag of `points` is worth. The derivative of
    /// the mapping, so a drag and the mapping can never disagree.
    func valueDelta(forPoints points: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        return Double(points / height) * valueSpan
    }

    func timeDelta(forPoints points: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(points / width) * timeSpan
    }

    // MARK: - Navigating

    /// Zoom about a point that stays put.
    ///
    /// The anchor is given in view coordinates, and the time and value under it
    /// are the same before and after — which is what "zoom at the cursor" means
    /// and why it is expressed as a fixed point rather than as a scale applied
    /// to the centre.
    ///
    /// The two axes scale independently, because a curve's interesting span in
    /// time and its interesting span in value have nothing to do with each
    /// other.
    mutating func zoom(timeFactor: Double, valueFactor: Double,
                       anchor: CGPoint, size: CGSize) {
        let anchorTime = time(forX: anchor.x, width: size.width)
        let anchorValue = value(forY: anchor.y, height: size.height)

        if timeFactor > 0, timeFactor.isFinite {
            let lower = anchorTime - (anchorTime - timeRange.lowerBound) / timeFactor
            let upper = anchorTime + (timeRange.upperBound - anchorTime) / timeFactor
            timeRange = Self.sanitised(lower...upper, holding: anchorTime)
        }
        if valueFactor > 0, valueFactor.isFinite {
            let lower = anchorValue - (anchorValue - valueRange.lowerBound) / valueFactor
            let upper = anchorValue + (valueRange.upperBound - anchorValue) / valueFactor
            valueRange = Self.sanitised(lower...upper, holding: anchorValue)
        }
    }

    /// Drag the view by a distance in points. Exactly the inverse of the
    /// mapping, so content stays under the finger with no accumulating slip.
    mutating func pan(byPoints translation: CGSize, size: CGSize) {
        let timeShift = timeDelta(forPoints: translation.width, width: size.width)
        let valueShift = valueDelta(forPoints: translation.height, height: size.height)
        timeRange = (timeRange.lowerBound - timeShift)...(timeRange.upperBound - timeShift)
        // Dragging down should move the content down, which means the visible
        // values go UP. The sign is the flip in `y(forValue:)`, not a choice.
        valueRange = (valueRange.lowerBound + valueShift)...(valueRange.upperBound + valueShift)
    }

    // MARK: - Fitting

    /// A viewport showing `bounds`, with a margin so nothing sits on the edge.
    static func fitting(_ bounds: GraphBounds, margin: Double = 0.12) -> GraphViewport {
        guard bounds.isValid else { return .neutral }
        let timePad = max(bounds.timeSpan * margin, 0.5)
        let valuePad = max(bounds.valueSpan * margin, abs(bounds.maxValue) * 0.08, 0.05)
        return GraphViewport(
            timeRange: (bounds.minTime - timePad)...(bounds.maxTime + timePad),
            valueRange: (bounds.minValue - valuePad)...(bounds.maxValue + valuePad)
        )
    }

    /// Widen just enough to contain `bounds`, keeping the current view where it
    /// already is. For keeping a selected key and its handles on screen without
    /// throwing away the framing the artist chose.
    mutating func extend(toInclude bounds: GraphBounds, margin: Double = 0.06) {
        guard bounds.isValid else { return }
        let timePad = max(bounds.timeSpan * margin, 0.25)
        let valuePad = max(bounds.valueSpan * margin, 0.05)
        timeRange = Self.sanitised(
            min(timeRange.lowerBound, bounds.minTime - timePad) ... max(timeRange.upperBound, bounds.maxTime + timePad))
        valueRange = Self.sanitised(
            min(valueRange.lowerBound, bounds.minValue - valuePad) ... max(valueRange.upperBound, bounds.maxValue + valuePad))
    }

    // MARK: - Grid

    /// The step a grid line should sit on, in the axis's own units.
    ///
    /// A "nice" number — 1, 2 or 5 times a power of ten — chosen so the visible
    /// span holds roughly `targetDivisions` of them. Zooming in therefore
    /// subdivides on its own: the step falls to the next nice number rather
    /// than the same lines drifting apart.
    static func gridStep(forSpan span: Double, targetDivisions: Double = 6) -> Double {
        guard span > 0, span.isFinite, targetDivisions > 0 else { return 1 }
        let rough = span / targetDivisions
        let magnitude = pow(10, (log10(rough)).rounded(.down))
        let normalised = rough / magnitude
        let nice: Double
        switch normalised {
        case ..<1.5: nice = 1
        case ..<3.5: nice = 2
        case ..<7.5: nice = 5
        default:     nice = 10
        }
        return nice * magnitude
    }

    /// Grid positions inside a range, on the step's own multiples so a line at
    /// zero is always AT zero.
    static func gridLines(in range: ClosedRange<Double>, step: Double,
                          limit: Int = 512) -> [Double] {
        guard step > 0, step.isFinite else { return [] }
        let first = (range.lowerBound / step).rounded(.up)
        let last = (range.upperBound / step).rounded(.down)
        guard last >= first, last - first < Double(limit) else { return [] }
        return stride(from: first, through: last, by: 1).map { $0 * step }
    }
}

/// The extent of what is actually drawn — keys, handles and the curve between
/// them.
///
/// The distinction that matters: a cubic Bézier between two keys is not bounded
/// by those keys, and it is not bounded by its control points either. It is
/// bounded by its own extrema, which are the roots of its derivative. Fitting a
/// view to the keyframe values is how a curve ends up drawn outside its own
/// editor.
struct GraphBounds: Equatable {
    private(set) var minTime = Double.infinity
    private(set) var maxTime = -Double.infinity
    private(set) var minValue = Double.infinity
    private(set) var maxValue = -Double.infinity

    var isValid: Bool { minTime <= maxTime && minValue <= maxValue }
    var timeSpan: Double { isValid ? maxTime - minTime : 0 }
    var valueSpan: Double { isValid ? maxValue - minValue : 0 }

    mutating func include(time: Double, value: Double) {
        guard time.isFinite, value.isFinite else { return }
        minTime = Swift.min(minTime, time)
        maxTime = Swift.max(maxTime, time)
        minValue = Swift.min(minValue, value)
        maxValue = Swift.max(maxValue, value)
    }

    mutating func formUnion(_ other: GraphBounds) {
        guard other.isValid else { return }
        include(time: other.minTime, value: other.minValue)
        include(time: other.maxTime, value: other.maxValue)
    }

    /// Include a whole cubic segment: its ends, its control points, and its
    /// true extrema.
    ///
    /// The control points are included because they are DRAWN and DRAGGED —
    /// a handle the artist cannot see is a handle they cannot grab, which is
    /// the complaint. The extrema are included because the curve goes there
    /// even though no control point does.
    mutating func include(cubicFrom p0: CGPoint, control1 c1: CGPoint,
                          control2 c2: CGPoint, to p3: CGPoint) {
        for point in [p0, c1, c2, p3] {
            include(time: Double(point.x), value: Double(point.y))
        }
        for t in Self.extremaParameters(Double(p0.y), Double(c1.y),
                                        Double(c2.y), Double(p3.y)) {
            include(time: Self.cubic(t, Double(p0.x), Double(c1.x), Double(c2.x), Double(p3.x)),
                    value: Self.cubic(t, Double(p0.y), Double(c1.y), Double(c2.y), Double(p3.y)))
        }
    }

    static func cubic(_ t: Double, _ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double) -> Double {
        let u = 1 - t
        return u * u * u * p0 + 3 * u * u * t * p1 + 3 * u * t * t * p2 + t * t * t * p3
    }

    /// Where the cubic turns, solved rather than sampled.
    ///
    /// y'(t)/3 = A + 2(B-A)t + (A-2B+C)t², with A = p1-p0, B = p2-p1, C = p3-p2.
    /// Sampling would miss a narrow spike between samples and would cost more;
    /// the quadratic is exact and is two roots.
    static func extremaParameters(_ p0: Double, _ p1: Double,
                                  _ p2: Double, _ p3: Double) -> [Double] {
        let a = p1 - p0
        let b = p2 - p1
        let c = p3 - p2
        let quadratic = a - 2 * b + c
        let linear = 2 * (b - a)
        let constant = a

        var roots: [Double] = []
        if abs(quadratic) < 1e-12 {
            // Degenerates to a line: one root, unless that is flat too.
            if abs(linear) > 1e-12 { roots.append(-constant / linear) }
        } else {
            let discriminant = linear * linear - 4 * quadratic * constant
            guard discriminant >= 0 else { return [] }
            let root = discriminant.squareRoot()
            roots.append((-linear + root) / (2 * quadratic))
            roots.append((-linear - root) / (2 * quadratic))
        }
        return roots.filter { $0 > 0 && $0 < 1 && $0.isFinite }
    }
}
