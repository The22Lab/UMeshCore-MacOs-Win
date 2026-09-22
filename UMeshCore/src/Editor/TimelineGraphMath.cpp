#include "umeshcore/Editor/TimelineGraphMath.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace umeshcore::TimelineGraph {
namespace {

bool hasSuffix(std::string_view s, std::string_view suffix) {
    return s.size() >= suffix.size() && s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

// The frame axis is clamped to at least one frame the same way everywhere
// in the Swift (`max(totalFrames, 1)`): a clip of length zero would divide
// the whole graph by nothing.
double frameAxis(int totalFrames) { return static_cast<double>(std::max(totalFrames, 1)); }

double distanceToSegment(Point p, Point a, Point b) {
    const double dx = b.x - a.x;
    const double dy = b.y - a.y;
    const double lengthSquared = dx * dx + dy * dy;
    if (lengthSquared <= 0.0) {
        return std::hypot(p.x - a.x, p.y - a.y);
    }
    double t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared;
    t = std::min(std::max(t, 0.0), 1.0);
    return std::hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
}

double cubicAt(double t, double p0, double p1, double p2, double p3) {
    const double u = 1.0 - t;
    return u * u * u * p0 + 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t * p3;
}

} // namespace

bool usesPrimaryTangents(std::string_view channelID) {
    return hasSuffix(channelID, ".x") || hasSuffix(channelID, ".scalar");
}

Sample sampleFor(const Keyframe& keyframe, float value, std::string_view channelID) {
    const bool primary = usesPrimaryTangents(channelID);
    Sample sample;
    sample.keyframeID = keyframe.id;
    sample.frame = keyframe.frame;
    sample.value = value;
    sample.interpolation = keyframe.interpolation;
    sample.outTangent = primary ? keyframe.outTangent : keyframe.secondaryOutTangent;
    sample.inTangent = primary ? keyframe.inTangent : keyframe.secondaryInTangent;
    return sample;
}

Vec2 defaultTangent(HandleKind handle) {
    constexpr float kFrameLength = 4.0f;
    return handle == HandleKind::In ? Vec2(-kFrameLength, 0.0f) : Vec2(kFrameLength, 0.0f);
}

std::optional<Vec2> tangentFor(
    const Keyframe& keyframe, std::string_view channelID, HandleKind handle) {
    if (usesPrimaryTangents(channelID)) {
        return handle == HandleKind::In ? keyframe.inTangent : keyframe.outTangent;
    }
    return handle == HandleKind::In ? keyframe.secondaryInTangent : keyframe.secondaryOutTangent;
}

std::optional<Vec2> updatedPrimaryInTangent(
    const Keyframe& keyframe, std::string_view channelID, HandleKind handle, Vec2 updated) {
    if (!usesPrimaryTangents(channelID) || handle != HandleKind::In) return keyframe.inTangent;
    return updated;
}

std::optional<Vec2> updatedPrimaryOutTangent(
    const Keyframe& keyframe, std::string_view channelID, HandleKind handle, Vec2 updated) {
    if (!usesPrimaryTangents(channelID) || handle != HandleKind::Out) return keyframe.outTangent;
    return updated;
}

std::optional<Vec2> updatedSecondaryInTangent(
    const Keyframe& keyframe, std::string_view channelID, HandleKind handle, Vec2 updated) {
    if (usesPrimaryTangents(channelID) || handle != HandleKind::In) {
        return keyframe.secondaryInTangent;
    }
    return updated;
}

std::optional<Vec2> updatedSecondaryOutTangent(
    const Keyframe& keyframe, std::string_view channelID, HandleKind handle, Vec2 updated) {
    if (usesPrimaryTangents(channelID) || handle != HandleKind::Out) {
        return keyframe.secondaryOutTangent;
    }
    return updated;
}

AnimationCurve::Segment controlPoints(const std::vector<Sample>& samples, std::size_t index) {
    const Sample& lhs = samples[index];
    const Sample& rhs = samples[index + 1];

    std::optional<AnimationCurve::FrameSample> beforeStart;
    if (index > 0) {
        beforeStart = AnimationCurve::FrameSample{samples[index - 1].frame, samples[index - 1].value};
    }
    std::optional<AnimationCurve::FrameSample> afterEnd;
    if (index + 2 < samples.size()) {
        afterEnd = AnimationCurve::FrameSample{samples[index + 2].frame, samples[index + 2].value};
    }

    // Only a bezier key's OWN out-tangent counts; a linear or hold key's
    // stored tangent is not what it is drawn with. The in-tangent is taken
    // as stored either way, exactly as Swift does -- the right-hand key's
    // interpolation describes the segment AFTER it, not this one.
    const std::optional<Vec2> outTangent =
        lhs.interpolation == KeyframeInterpolation::Bezier ? lhs.outTangent : std::nullopt;

    return AnimationCurve::segment(
        AnimationCurve::FrameSample{lhs.frame, lhs.value},
        AnimationCurve::FrameSample{rhs.frame, rhs.value}, outTangent, rhs.inTangent, beforeStart,
        afterEnd);
}

double xForFrame(double frame, double width, int totalFrames) {
    return width * (frame / frameAxis(totalFrames));
}

double yForValue(float value, const GraphRange& valueRange, double height) {
    const double span = std::max(valueRange.upper - valueRange.lower, 0.0001);
    const double normalised = (static_cast<double>(value) - valueRange.lower) / span;
    return height - normalised * height;
}

float valueDelta(double translationY, const GraphRange& valueRange, double height) {
    if (height <= 0.0) return 0.0f;
    const double unitsPerPoint = (valueRange.upper - valueRange.lower) / height;
    return static_cast<float>(translationY * unitsPerPoint);
}

std::optional<Point> handlePoint(
    const Keyframe& keyframe, std::optional<float> channelValue, std::string_view channelID,
    HandleKind handle, double width, double height, int totalFrames,
    const GraphRange& valueRange) {
    if (!channelValue.has_value()) return std::nullopt;

    const Vec2 tangent =
        tangentFor(keyframe, channelID, handle).value_or(defaultTangent(handle));
    const double frame = static_cast<double>(keyframe.frame) + static_cast<double>(tangent.x);
    const float value = *channelValue + tangent.y;

    return Point{
        xForFrame(frame, width, totalFrames), yForValue(value, valueRange, height)};
}

Vec2 updatedTangent(
    Vec2 initialTangent, double translationX, double translationY, HandleKind handle,
    const GraphRange& valueRange, double width, double height, int totalFrames,
    bool snapEnabled) {
    const double framesPerPoint = frameAxis(totalFrames) / std::max(width, 1.0);
    const float rawDeltaFrames = static_cast<float>(translationX * framesPerPoint);
    const float deltaFrames = snapEnabled ? std::round(rawDeltaFrames) : rawDeltaFrames;
    const float dValue = valueDelta(translationY, valueRange, height);

    Vec2 tangent = initialTangent;
    tangent.x += deltaFrames;
    // Screen y grows downward and value grows upward, so a drag DOWN must
    // lower the handle's value.
    tangent.y -= dValue;

    if (handle == HandleKind::In) {
        tangent.x = std::min(tangent.x, -0.1f);
    } else {
        tangent.x = std::max(tangent.x, 0.1f);
    }
    return tangent;
}

GraphBounds curveBounds(const std::vector<Sample>& samples) {
    GraphBounds bounds;
    for (const Sample& sample : samples) {
        bounds.include(static_cast<double>(sample.frame), static_cast<double>(sample.value));
    }
    if (samples.size() < 2) return bounds;

    for (std::size_t index = 0; index + 1 < samples.size(); ++index) {
        if (samples[index].interpolation != KeyframeInterpolation::Bezier) continue;
        const AnimationCurve::Segment segment = controlPoints(samples, index);
        bounds.includeCubic(
            GraphBounds::Point{segment.start.x, segment.start.y},
            GraphBounds::Point{segment.control1.x, segment.control1.y},
            GraphBounds::Point{segment.control2.x, segment.control2.y},
            GraphBounds::Point{segment.end.x, segment.end.y});
    }
    return bounds;
}

double framePosition(double frame, double frameSpacing, double zoomScale, double leadingInset) {
    return frame * frameSpacing * zoomScale + leadingInset;
}

std::optional<std::size_t> nearestKeyframe(
    double x, const std::vector<int>& frames, double frameSpacing, double zoomScale,
    double leadingInset) {
    std::optional<std::size_t> best;
    double bestDistance = 0.0;
    for (std::size_t i = 0; i < frames.size(); ++i) {
        const double distance = std::abs(
            framePosition(static_cast<double>(frames[i]), frameSpacing, zoomScale, leadingInset) -
            x);
        if (distance > kNearestKeyframePx) continue;
        // Strictly less: a tie keeps the earlier index, which is what
        // Swift's `min(by:)` with a strict `<` does.
        if (!best.has_value() || distance < bestDistance) {
            best = i;
            bestDistance = distance;
        }
    }
    return best;
}

double distanceToCurve(
    Point point, const std::vector<Sample>& samples, std::size_t index, double width,
    double height, int totalFrames, const GraphRange& valueRange, int flattenSamples) {
    const Sample& lhs = samples[index];
    const Sample& rhs = samples[index + 1];
    const Point start{
        xForFrame(static_cast<double>(lhs.frame), width, totalFrames),
        yForValue(lhs.value, valueRange, height)};
    const Point end{
        xForFrame(static_cast<double>(rhs.frame), width, totalFrames),
        yForValue(rhs.value, valueRange, height)};

    switch (lhs.interpolation) {
        case KeyframeInterpolation::Hold: {
            // Two legs: the value is held to the right-hand key's frame and
            // then steps. The step itself is grabbable, which matches what
            // the Swift path draws and hit-tests.
            const Point corner{end.x, start.y};
            return std::min(
                distanceToSegment(point, start, corner), distanceToSegment(point, corner, end));
        }
        case KeyframeInterpolation::Linear:
            return distanceToSegment(point, start, end);
        case KeyframeInterpolation::Bezier:
            break;
    }

    const AnimationCurve::Segment segment = controlPoints(samples, index);
    const Point c1{
        xForFrame(static_cast<double>(segment.control1.x), width, totalFrames),
        yForValue(segment.control1.y, valueRange, height)};
    const Point c2{
        xForFrame(static_cast<double>(segment.control2.x), width, totalFrames),
        yForValue(segment.control2.y, valueRange, height)};

    const int steps = std::max(flattenSamples, 1);
    double best = std::numeric_limits<double>::infinity();
    Point previous = start;
    for (int i = 1; i <= steps; ++i) {
        const double t = static_cast<double>(i) / static_cast<double>(steps);
        const Point current{
            cubicAt(t, start.x, c1.x, c2.x, end.x), cubicAt(t, start.y, c1.y, c2.y, end.y)};
        best = std::min(best, distanceToSegment(point, previous, current));
        previous = current;
    }
    return best;
}

KeyframeValue updatedKeyframeValue(
    AnimationTrackProperty property, std::string_view channelID, float scalarValue,
    const std::optional<KeyframeValue>& existing) {
    using P = AnimationTrackProperty;
    const bool isX = hasSuffix(channelID, ".x");

    if (!existing.has_value()) {
        switch (property) {
            case P::Translate: return TranslateValue{Vec2(scalarValue, 0.0f)};
            case P::Rotate: return RotateValue{scalarValue};
            case P::Scale: return ScaleValue{Vec2(scalarValue, scalarValue)};
            case P::Shear: return ShearValue{Vec2(scalarValue, 0.0f)};
            case P::MeshDeform: return MeshDeformValue{};
            case P::DrawOrder: return DrawOrderValue{};
            case P::Event: return EventValue{AnimationEventPayload{}};
            default: break;
        }
        switch (valueKind(property)) {
            case TrackValueKind::Scalar: return ScalarValue{clamped(property, scalarValue)};
            case TrackValueKind::Flag: return FlagValue{scalarValue >= 0.5f};
            case TrackValueKind::Vector2: return Vector2Value{Vec2(scalarValue, 0.0f)};
            case TrackValueKind::Deform:
            case TrackValueKind::DrawOrder:
            case TrackValueKind::Event:
            case TrackValueKind::Attachment:
                return MeshDeformValue{};
        }
        return MeshDeformValue{};
    }

    switch (property) {
        case P::Translate: {
            Vec2 value = simd2Value(*existing).value_or(Vec2(0.0f, 0.0f));
            (isX ? value.x : value.y) = scalarValue;
            return TranslateValue{value};
        }
        case P::Rotate:
            return RotateValue{scalarValue};
        case P::Scale: {
            Vec2 value = simd2Value(*existing).value_or(Vec2(1.0f, 1.0f));
            // A zero scale is not a small sprite, it is a matrix that no
            // longer inverts -- and skinning, picking and the gizmos all
            // invert it.
            (isX ? value.x : value.y) = std::max(scalarValue, 0.001f);
            return ScaleValue{value};
        }
        case P::Shear: {
            Vec2 value = simd2Value(*existing).value_or(Vec2(0.0f, 0.0f));
            (isX ? value.x : value.y) = scalarValue;
            return ShearValue{value};
        }
        case P::MeshDeform:
        case P::DrawOrder:
        case P::Event:
        case P::Attachment:
            return *existing;
        default:
            break;
    }

    switch (valueKind(property)) {
        case TrackValueKind::Scalar:
            return ScalarValue{clamped(property, scalarValue)};
        case TrackValueKind::Flag:
            return FlagValue{scalarValue >= 0.5f};
        case TrackValueKind::Vector2: {
            Vec2 value = simd2Value(*existing).value_or(Vec2(0.0f, 0.0f));
            (isX ? value.x : value.y) = scalarValue;
            return Vector2Value{value};
        }
        case TrackValueKind::Deform:
        case TrackValueKind::DrawOrder:
        case TrackValueKind::Event:
        case TrackValueKind::Attachment:
            return *existing;
    }
    return *existing;
}

} // namespace umeshcore::TimelineGraph
