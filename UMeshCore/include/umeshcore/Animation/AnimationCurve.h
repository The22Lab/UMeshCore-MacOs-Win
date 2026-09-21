#pragma once

// 1:1 port of `Data/AnimationCurve.swift`.
//
// The single authority for where a Bezier animation segment's control
// points go. Do not "simplify" the trigonometry/clamping here -- the Swift
// source's header comment documents three previous, mutually-disagreeing
// implementations this type replaced; each formula below is deliberate.

#include <algorithm>
#include <cmath>
#include <limits>
#include <optional>

#include "umeshcore/Math/Vec.h"

namespace umeshcore::AnimationCurve {

// A segment's four Bezier points, in (time, value).
struct Segment {
    Vec2 start;
    Vec2 control1;
    Vec2 control2;
    Vec2 end;
};

// One frame: keys live on integers, so nothing smaller is a real gap.
constexpr float kFrameSpanFloor = 1.0f;
// A normalised axis runs 0...1 whole; the floor has to be invisible against
// that range and large enough to stop a division by a gap of zero.
constexpr float kNormalisedSpanFloor = 1e-6f;

constexpr int kSolverIterations = 10;
constexpr float kSolverTolerance = 1e-7f;

struct Sample {
    float x;
    float value;
};

// The slope an un-tangented keyframe is given on a CONTINUOUS axis.
// Flattened at a turning point (`rising*falling<=0`) so an auto-curve
// cannot overshoot past a local maximum/minimum.
inline float autoSlope(
    std::optional<Sample> previous, Sample current, std::optional<Sample> next,
    float minimumSpan) {
    if (previous.has_value() && next.has_value()) {
        const float rising = current.value - previous->value;
        const float falling = next->value - current.value;
        if (rising * falling <= 0.0f) return 0.0f;
        return (next->value - previous->value) / std::max(next->x - previous->x, minimumSpan);
    }
    if (previous.has_value()) {
        return (current.value - previous->value) / std::max(current.x - previous->x, minimumSpan);
    }
    if (next.has_value()) {
        return (next->value - current.value) / std::max(next->x - current.x, minimumSpan);
    }
    return 0.0f;
}

// Frame-axis adapter (minimumSpan = kFrameSpanFloor).
struct FrameSample {
    int frame;
    float value;
};

inline float autoSlope(
    std::optional<FrameSample> previous, FrameSample current, std::optional<FrameSample> next) {
    auto toSample = [](std::optional<FrameSample> s) -> std::optional<Sample> {
        if (!s.has_value()) return std::nullopt;
        return Sample{static_cast<float>(s->frame), s->value};
    };
    return autoSlope(
        toSample(previous), Sample{static_cast<float>(current.frame), current.value},
        toSample(next), kFrameSpanFloor);
}

// The segment between two keyframes, tangents resolved and clamped, on a
// CONTINUOUS axis.
inline Segment segment(
    Sample start, Sample end, std::optional<Vec2> outTangent, std::optional<Vec2> inTangent,
    std::optional<Sample> beforeStart, std::optional<Sample> afterEnd, float minimumSpan) {
    const float span = std::max(end.x - start.x, minimumSpan);
    const Vec2 p0(start.x, start.value);
    const Vec2 p3(end.x, end.value);

    Vec2 out;
    if (outTangent.has_value()) {
        out = *outTangent;
    } else {
        const float slope = autoSlope(beforeStart, start, end, minimumSpan);
        const float x = span / 3.0f;
        out = Vec2(x, slope * x);
    }

    Vec2 incoming;
    if (inTangent.has_value()) {
        incoming = *inTangent;
    } else {
        const float slope = autoSlope(start, end, afterEnd, minimumSpan);
        const float x = -span / 3.0f;
        incoming = Vec2(x, slope * x);
    }

    Vec2 p1 = p0 + out;
    Vec2 p2 = p3 + incoming;
    // Clamp inside the segment: a control point outside it makes x(t)
    // non-monotonic, i.e. one time maps to two values.
    p1.x = std::min(std::max(p1.x, p0.x), p3.x);
    p2.x = std::min(std::max(p2.x, p0.x), p3.x);
    return Segment{p0, p1, p2, p3};
}

// Frame-axis adapter (minimumSpan = kFrameSpanFloor).
inline Segment segment(
    FrameSample start, FrameSample end, std::optional<Vec2> outTangent,
    std::optional<Vec2> inTangent, std::optional<FrameSample> beforeStart,
    std::optional<FrameSample> afterEnd) {
    auto toSample = [](FrameSample s) { return Sample{static_cast<float>(s.frame), s.value}; };
    auto toSampleOpt = [](std::optional<FrameSample> s) -> std::optional<Sample> {
        if (!s.has_value()) return std::nullopt;
        return Sample{static_cast<float>(s->frame), s->value};
    };
    return segment(
        toSample(start), toSample(end), outTangent, inTangent, toSampleOpt(beforeStart),
        toSampleOpt(afterEnd), kFrameSpanFloor);
}

// A cubic Bezier component at `t`.
inline float value(float t, float p0, float p1, float p2, float p3) {
    const float u = 1.0f - t;
    return (u * u * u * p0) + (3.0f * u * u * t * p1) + (3.0f * u * t * t * p2) +
           (t * t * t * p3);
}

// Its derivative, which Newton needs.
inline float slope(float t, float p0, float p1, float p2, float p3) {
    const float u = 1.0f - t;
    return (3.0f * u * u * (p1 - p0)) + (6.0f * u * t * (p2 - p1)) + (3.0f * t * t * (p3 - p2));
}

// The parameter at which the curve reaches time `x`: Newton's method inside
// a bisection safety bracket, keeping the best answer seen.
inline float parameter(float x, float p0, float p1, float p2, float p3) {
    float low = 0.0f;
    float high = 1.0f;
    float t = 0.5f;
    float bestT = t;
    float bestError = std::numeric_limits<float>::max();

    for (int i = 0; i < kSolverIterations; ++i) {
        const float error = value(t, p0, p1, p2, p3) - x;
        const float magnitude = std::abs(error);
        if (magnitude < bestError) {
            bestError = magnitude;
            bestT = t;
        }
        if (magnitude <= kSolverTolerance) return t;
        if (error > 0.0f) {
            high = t;
        } else {
            low = t;
        }

        const float derivative = slope(t, p0, p1, p2, p3);
        if (!(std::abs(derivative) > 1e-9f)) {
            t = (low + high) * 0.5f;
            continue;
        }
        const float step = t - error / derivative;
        t = (step >= low && step <= high) ? step : (low + high) * 0.5f;
    }
    return std::abs(value(t, p0, p1, p2, p3) - x) < bestError ? t : bestT;
}

// The value this segment holds at `time`.
inline float valueAtTime(const Segment& segment, float time) {
    const float t = parameter(
        time, segment.start.x, segment.control1.x, segment.control2.x, segment.end.x);
    return value(t, segment.start.y, segment.control1.y, segment.control2.y, segment.end.y);
}

} // namespace umeshcore::AnimationCurve
