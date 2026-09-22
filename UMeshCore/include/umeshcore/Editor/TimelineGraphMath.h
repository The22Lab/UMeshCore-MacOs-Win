#pragma once

// Port of the graph editor's math, extracted from the body of
// `TimelineView.swift` (4326 L): tangents, control points, the two screen
// mappings the graph uses, and the hit tests for a handle, a keyframe and a
// curve segment.
//
// Extracted rather than left where it is for the reason CLAUDE.md gives for
// the whole SwiftUI debt (Risk #6): this is real math living inside a
// SwiftUI view body, and porting it from there -- once a WinUI shell needs
// the equivalent -- is far riskier than lifting it into the core first,
// while the Swift is still next to it to compare against.
//
// What stays in the view: everything that is a gesture, a Path, a colour or
// a `sceneManager` call. What comes here is every number those need.
//
// TWO DIVERGENCES, both forced by the platform and both deliberate:
//
// 1. `graphCurveHitArea` hit-tests by handing SwiftUI a `strokedPath`
//    contentShape and letting it answer "did the pointer land on this
//    curve". There is no such service in the core, and a Windows shell has
//    no equivalent either, so the question is answered here numerically:
//    `distanceToCurve` flattens the drawn path and measures. Same question,
//    same grab width (`GraphMetrics::curveGrabPx`), answered by us.
//
// 2. Swift's `graphCurveHitArea`, `graphBezierHandles` and `nearestKeyframe`
//    each reach into `sceneManager` for the keyframes of the selected
//    track. Per convention #2, nothing here takes a scene: a caller passes
//    the samples, the keyframe, or the frames it already has.
//
// NOT extracted, on purpose: `smoothAutoTangent` is already DELETED in the
// Swift (its own comment says why -- it was a second, disagreeing answer to
// what `AnimationCurve::autoSlope` answers), so there is nothing to port.

#include <cstddef>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "umeshcore/Animation/AnimationCurve.h"
#include "umeshcore/Animation/AnimationTrackProperty.h"
#include "umeshcore/Animation/Keyframe.h"
#include "umeshcore/Core/Uuid.h"
#include "umeshcore/Editor/GraphViewport.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore::TimelineGraph {

// Which end of a keyframe a handle belongs to. `GraphHandleKind` in Swift.
enum class HandleKind { In, Out };

// A point in view space (pixels). Doubles, like `GraphViewport`'s, because
// a mapping that must invert exactly cannot round-trip through float.
struct Point {
    double x = 0.0;
    double y = 0.0;
};

// ---- Which tangent pair a channel uses ----

// THE one rule, `GraphSample.usesPrimaryTangents` in Swift. A keyframe
// carries two pairs: the primary pair for x and scalar channels, the
// secondary pair for y. Its Swift comment records what restating the rule
// at eleven call sites cost: `constraint.flag`, which is neither `.x` nor
// `.scalar` and so takes the SECONDARY pair, was put on the primary one.
bool usesPrimaryTangents(std::string_view channelID);

// ---- One channel's view of a keyframe ----

// `GraphSample` in Swift, minus the SwiftUI identity. The tangents are
// CARRIED rather than looked up: building one from the keyframe is where
// the channel is known, and the alternative (Swift's original) was a linear
// scan of the track run twice per segment inside a bounds computation.
struct Sample {
    Uuid keyframeID;
    int frame = 0;
    float value = 0.0f;
    KeyframeInterpolation interpolation = KeyframeInterpolation::Linear;
    // This channel's pair, already chosen.
    std::optional<Vec2> outTangent;
    std::optional<Vec2> inTangent;
};

Sample sampleFor(const Keyframe& keyframe, float value, std::string_view channelID);

// ---- Tangents ----

// The handle a keyframe with no tangent is drawn with: four frames wide,
// flat. Swift's `defaultGraphTangent`.
Vec2 defaultTangent(HandleKind handle);

// This channel's stored tangent, or nullopt when the keyframe has none.
std::optional<Vec2> tangentFor(
    const Keyframe& keyframe, std::string_view channelID, HandleKind handle);

// The four "which of the keyframe's four tangents does this drag write"
// helpers. Each returns the field's NEW value -- the dragged one for the
// field the channel and handle select, the field's existing value for the
// other three -- so a caller writes all four back unconditionally.
std::optional<Vec2> updatedPrimaryInTangent(
    const Keyframe& keyframe, std::string_view channelID, HandleKind handle,
    Vec2 updatedTangent);
std::optional<Vec2> updatedPrimaryOutTangent(
    const Keyframe& keyframe, std::string_view channelID, HandleKind handle,
    Vec2 updatedTangent);
std::optional<Vec2> updatedSecondaryInTangent(
    const Keyframe& keyframe, std::string_view channelID, HandleKind handle,
    Vec2 updatedTangent);
std::optional<Vec2> updatedSecondaryOutTangent(
    const Keyframe& keyframe, std::string_view channelID, HandleKind handle,
    Vec2 updatedTangent);

// ---- Control points: THROUGH the evaluator ----

// The segment between `samples[index]` and `samples[index + 1]`, resolved
// by `AnimationCurve::segment` -- the same call playback makes.
//
// Swift's `graphControlPoints` comment records what the graph's own copy
// of this geometry got wrong before it was routed here, and each item is a
// visible bug: no turning-point clamp, so it drew a curve climbing to
// 100.65 past a key of 100 that playback holds at exactly 100; no clamp of
// a control point into its segment, so a handle dragged past the next key
// drew an S-bend differing from what played by 90 units; and a 0.35/0.65
// fallback against the evaluator's third. The artist was shown a curve
// nobody plays.
//
// The NEIGHBOURS are why this takes the whole array and an index rather
// than two samples: an auto tangent is derived from them, and the graph has
// them -- the evaluator, working a segment at a time, does not, which is
// exactly where the two used to disagree.
AnimationCurve::Segment controlPoints(const std::vector<Sample>& samples, std::size_t index);

// ---- The two screen mappings ----
//
// They are NOT symmetric, and that is not an oversight; the Swift header
// spells it out. X stays the clip fraction because the graph sits under the
// timeline ruler and shares the playhead's mapping -- fitting X to the
// curve would put the graph on a different horizontal scale from the frame
// numbers above it. Y, which is what the viewport is for, goes through the
// value range.

double xForFrame(double frame, double width, int totalFrames);
double yForValue(float value, const GraphRange& valueRange, double height);
// Pixels of vertical drag -> units of value. Signless: the caller applies
// the sign, because a tangent drag subtracts it and a value drag adds it.
float valueDelta(double translationY, const GraphRange& valueRange, double height);

// Where a keyframe's handle is drawn, or nullopt when the channel has no
// value at that keyframe.
std::optional<Point> handlePoint(
    const Keyframe& keyframe, std::optional<float> channelValue, std::string_view channelID,
    HandleKind handle, double width, double height, int totalFrames,
    const GraphRange& valueRange);

// A handle drag, in the tangent's own units.
//
// The clamp is the load-bearing part: an in-handle must stay left of its
// keyframe and an out-handle right of it (-0.1 / +0.1), or the segment's
// x(t) stops being monotonic and one time maps to two values.
Vec2 updatedTangent(
    Vec2 initialTangent, double translationX, double translationY, HandleKind handle,
    const GraphRange& valueRange, double width, double height, int totalFrames, bool snapEnabled);

// ---- Bounds ----

// The extent of a channel: every key, plus the TRUE extrema of every bezier
// segment between them. A `GraphViewport::fitting` of this is what the
// editor frames when the artist has not navigated.
GraphBounds curveBounds(const std::vector<Sample>& samples);

// ---- Hit testing ----

// A keyframe's x in the TIMELINE's mapping (`framePosition` in Swift),
// which is a spacing and a zoom, not the graph's clip fraction: the track
// rows and the ruler are laid out from it.
double framePosition(double frame, double frameSpacing, double zoomScale, double leadingInset);

// Grab radius of a keyframe diamond in the track rows. 11 in Swift, where
// it is a local constant inside `nearestKeyframe`.
inline constexpr double kNearestKeyframePx = 11.0;

// The nearest keyframe within `kNearestKeyframePx` of `x`, as an index into
// `frames`, or nullopt. Ties go to the earlier index, as Swift's `min(by:)`
// does with a strict `<`.
std::optional<std::size_t> nearestKeyframe(
    double x, const std::vector<int>& frames, double frameSpacing, double zoomScale,
    double leadingInset);

// Distance in pixels from `point` to the curve as DRAWN between two
// samples -- a step for hold, a line for linear, the flattened cubic for
// bezier. This is the numeric answer to what SwiftUI's stroked-path
// contentShape answers for the Mac (divergence 1, above); compare it
// against `GraphMetrics::curveGrabPx(touchScale) / 2`.
double distanceToCurve(
    Point point, const std::vector<Sample>& samples, std::size_t index, double width,
    double height, int totalFrames, const GraphRange& valueRange, int flattenSamples = 24);

// ---- Writing a dragged value back ----

// The new `KeyframeValue` for a channel dragged to `scalarValue`.
//
// `existing` is the keyframe's current value when there is one; passing
// nullopt is Swift's "the keyframe could not be found" branch, which builds
// a fresh value of the property's shape rather than refusing the edit.
//
// Two guards worth not losing: a scale component is floored at 0.001 (a
// zero scale is a non-invertible matrix, not a small sprite), and a scalar
// goes through `clamped(property, ...)` so a drag cannot write a value the
// inspector would reject.
KeyframeValue updatedKeyframeValue(
    AnimationTrackProperty property, std::string_view channelID, float scalarValue,
    const std::optional<KeyframeValue>& existing);

} // namespace umeshcore::TimelineGraph
