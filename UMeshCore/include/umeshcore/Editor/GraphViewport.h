#pragma once

// 1:1 port of `GraphViewport.swift` (302 L) and `GraphMetrics.swift` (59 L)
// -- what part of a curve the Graph Editor is looking at, and the ONLY
// place time and value become pixels.
//
// These two are the first of the timeline's SwiftUI debt to come across,
// and they come first because they are already clean: CoreGraphics types
// and arithmetic, no view body, no `@State`. The rest of
// `TimelineView.swift` (4326 L) reads them.
//
// WHY THE TYPE EXISTS AT ALL. The editor used to have no viewport. Two
// functions did the mapping, and the vertical one derived its range on
// every layout from the KEYFRAME VALUES -- the min and max of the samples,
// padded 18%. That is a bug, and a specific one: a Bezier handle is not a
// keyframe value, and neither is the curve between two keys, because a
// cubic can overshoot well past both of its ends. So a handle dragged out
// any distance, and the curve it produced, mapped outside the view and
// were clipped by the frame. The curve was being cropped to fit a
// rectangle derived from something that is not the curve.
//
// THE RULE THIS TYPE ENFORCES: the curve and the viewport are
// independent. A curve may take any value it likes; the viewport is what
// moves. Nothing here ever clamps a value to fit the view -- `fitting`
// moves the view to the values instead, and it measures the CURVE,
// including its handles and its true extrema, not the keyframes.
//
// PRECISION. Everything is `double` and every mapping has an exact
// inverse, so a drag that reads a pixel, converts to time and value, and
// stores it round-trips back to the pixel it came from. Nothing rounds to
// whole frames or whole pixels on the way through, which is what keeps a
// handle dragged slowly at high zoom moving by exactly what the pointer
// moved.
//
// THE ONE DIVERGENCE: `GraphMetrics.touchScale` is `#if os(iOS)` in Swift.
// The core has no platform, so it is a parameter -- see `GraphMetrics`.

#include <limits>
#include <optional>
#include <vector>

namespace umeshcore {

// A closed range, sanitised on the way in. Its own type because both axes
// need the same guards and a pair of doubles would let a caller build one
// that divides by nothing.
struct GraphRange {
    double lower = 0.0;
    double upper = 1.0;

    constexpr double span() const { return upper - lower; }
    constexpr bool operator==(const GraphRange&) const = default;
};

// The extent of what is actually DRAWN -- keys, handles and the curve
// between them.
//
// The distinction that matters: a cubic Bezier between two keys is not
// bounded by those keys, and it is not bounded by its control points
// either. It is bounded by its own extrema, which are the roots of its
// derivative. Fitting a view to the keyframe values is how a curve ends up
// drawn outside its own editor.
class GraphBounds {
public:
    double minTime() const { return minTime_; }
    double maxTime() const { return maxTime_; }
    double minValue() const { return minValue_; }
    double maxValue() const { return maxValue_; }

    bool isValid() const { return minTime_ <= maxTime_ && minValue_ <= maxValue_; }
    double timeSpan() const { return isValid() ? maxTime_ - minTime_ : 0.0; }
    double valueSpan() const { return isValid() ? maxValue_ - minValue_ : 0.0; }

    void include(double time, double value);
    void formUnion(const GraphBounds& other);

    struct Point {
        double x = 0.0;
        double y = 0.0;
    };

    // Include a whole cubic segment: its ends, its control points, and its
    // true extrema.
    //
    // The control points are included because they are DRAWN and DRAGGED
    // -- a handle the artist cannot see is a handle they cannot grab. The
    // extrema are included because the curve goes there even though no
    // control point does.
    void includeCubic(const Point& p0, const Point& c1, const Point& c2, const Point& p3);

    static double cubic(double t, double p0, double p1, double p2, double p3);

    // Where the cubic turns, SOLVED rather than sampled:
    // y'(t)/3 = A + 2(B-A)t + (A-2B+C)t^2, with A = p1-p0, B = p2-p1,
    // C = p3-p2. Sampling would miss a narrow spike between samples and
    // would cost more; the quadratic is exact and is two roots.
    static std::vector<double> extremaParameters(double p0, double p1, double p2, double p3);

private:
    double minTime_ = std::numeric_limits<double>::infinity();
    double maxTime_ = -std::numeric_limits<double>::infinity();
    double minValue_ = std::numeric_limits<double>::infinity();
    double maxValue_ = -std::numeric_limits<double>::infinity();
};

class GraphViewport {
public:
    // Below this the ranges are degenerate and every mapping divides by
    // nothing. It bounds how far in a zoom may go, and it is far finer
    // than anything an artist can express.
    static constexpr double kMinimumSpan = 1e-6;

    GraphViewport() = default;
    GraphViewport(const GraphRange& timeRange, const GraphRange& valueRange);

    static GraphViewport neutral() { return GraphViewport(GraphRange{0, 60}, GraphRange{-1, 1}); }

    // Visible span in frames. Fractional on purpose: at high zoom a single
    // frame can be wider than the editor.
    const GraphRange& timeRange() const { return timeRange_; }
    // Visible span in the property's own units.
    const GraphRange& valueRange() const { return valueRange_; }
    double timeSpan() const { return timeRange_.span(); }
    double valueSpan() const { return valueRange_.span(); }

    // ---- Mapping, both ways ----
    double xForTime(double time, double width) const;
    double timeForX(double x, double width) const;
    // Y grows downward in the view and values grow upward, so this flips.
    double yForValue(double value, double height) const;
    double valueForY(double y, double height) const;

    // How much value a vertical drag of `points` is worth -- the
    // DERIVATIVE of the mapping, so a drag and the mapping can never
    // disagree.
    double valueDeltaForPoints(double points, double height) const;
    double timeDeltaForPoints(double points, double width) const;

    // ---- Navigating ----

    // Zoom about a point that stays put. The anchor is in view
    // coordinates, and the time and value under it are the same before and
    // after -- which is what "zoom at the cursor" means, and why it is
    // expressed as a fixed point rather than as a scale applied to the
    // centre.
    //
    // The two axes scale independently, because a curve's interesting span
    // in time and its interesting span in value have nothing to do with
    // each other.
    void zoom(double timeFactor, double valueFactor, double anchorX, double anchorY,
              double width, double height);

    // Drag the view by a distance in points. Exactly the inverse of the
    // mapping, so content stays under the finger with no accumulating
    // slip.
    void pan(double translationX, double translationY, double width, double height);

    // ---- Fitting ----

    // A viewport showing `bounds`, with a margin so nothing sits on the
    // edge.
    static GraphViewport fitting(const GraphBounds& bounds, double margin = 0.12);

    // Widen just enough to contain `bounds`, keeping the current view
    // where it already is -- for keeping a selected key and its handles on
    // screen without throwing away the framing the artist chose.
    void extendToInclude(const GraphBounds& bounds, double margin = 0.06);

    // ---- Grid ----

    // The step a grid line should sit on, in the axis's own units: a
    // "nice" number -- 1, 2 or 5 times a power of ten -- chosen so the
    // visible span holds roughly `targetDivisions` of them. Zooming in
    // therefore SUBDIVIDES on its own: the step falls to the next nice
    // number rather than the same lines drifting apart.
    static double gridStep(double span, double targetDivisions = 6.0);

    // Grid positions inside a range, on the step's own multiples so a line
    // at zero is always AT zero.
    static std::vector<double> gridLines(const GraphRange& range, double step, int limit = 512);

private:
    // A usable range: finite, and never narrower than the floor.
    //
    // `anchor`, when given, is a point that must stay where it is in the
    // view. Without it the floor RE-CENTRES -- and every zoom step past
    // the floor then drags the picture, so the point under the cursor
    // walks away. The Swift harness measured ninety zoom steps moving it
    // 262% of the view's width. The floor decides how WIDE the view is; it
    // has no business deciding where it sits.
    static GraphRange sanitised(
        const GraphRange& range, std::optional<double> anchor = std::nullopt);

    GraphRange timeRange_{0, 60};
    GraphRange valueRange_{-1, 1};
};

// What the graph editor draws, and what it lets you grab.
//
// They are deliberately different numbers. A keyframe drawn at eleven
// points is small and quiet on a dense curve; eleven points is also a
// target you have to aim at. Separating the two is what lets the drawing
// stay elegant while the interaction stays forgiving.
//
// PRIORITY, stated here because it is a property of these numbers and not
// of whichever view happens to be drawn last: a handle beats a keyframe, a
// keyframe beats the curve. The grab sizes are ordered to match, so the
// z-order and the tolerances agree instead of quietly contradicting each
// other -- before this, a handle's 20 points sat under a keyframe's 22,
// and only the drawing order saved it.
namespace GraphMetrics {

// ---- Drawn ----
inline constexpr double kKeyframeVisualPx = 11.0;
inline constexpr double kHandleVisualPx = 9.0;
inline constexpr double kCurveVisualPx = 1.8;

// ---- Grabbed ----
//
// A finger is not a mouse, and a stylus tip is not a cursor: the same
// tolerance on both platforms is what makes one of them feel imprecise.
// SCALED, never redefined, so the ORDER below cannot come apart between
// platforms.
//
// In Swift this is `#if os(iOS)`. The core has no platform, so the shell
// passes it -- which is strictly better here, because a tablet-mode
// Windows shell wants the touch scale on the same machine that wants the
// pointer one.
inline constexpr double kPointerTouchScale = 1.0;
inline constexpr double kFingerTouchScale = 1.6;

// A handle, biggest, because it is the smallest thing drawn and the one an
// animator reaches for most.
inline constexpr double handleGrabPx(double touchScale) { return 26.0 * touchScale; }
// A keyframe, under it.
inline constexpr double keyframeGrabPx(double touchScale) { return 22.0 * touchScale; }
// The curve, under both -- it is an area, not a point, so it needs least.
inline constexpr double curveGrabPx(double touchScale) { return 14.0 * touchScale; }

// The order the tolerances are in, as a fact rather than a hope. If
// someone raises the keyframe's tolerance past a handle's, a handle
// sitting on top of its own keyframe becomes ungrabbable -- which is the
// failure an artist reports as "I know where it is and I cannot pick it
// up".
inline constexpr bool respectsPriority(double touchScale) {
    return handleGrabPx(touchScale) > keyframeGrabPx(touchScale) &&
           keyframeGrabPx(touchScale) > curveGrabPx(touchScale);
}

} // namespace GraphMetrics

} // namespace umeshcore
