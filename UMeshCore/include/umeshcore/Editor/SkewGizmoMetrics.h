#pragma once

// 1:1 port of `SkewGizmoMetrics.swift`. A FIXED track radius on purpose --
// see the Swift source's header comment on why deriving it from the
// sprite's transformed corners was a bug (the radius grew visibly during
// the drag it was displaying).

#include <cmath>

namespace umeshcore::SkewGizmoMetrics {

constexpr float kTrackRadiusPx = 62.0f;
constexpr float kArcWidthPx = 4.0f;
constexpr float kHandleRadiusPx = 5.5f;
constexpr float kGuideWidthPx = 1.6f;
constexpr float kMaxSweepDegrees = 89.0f;
constexpr int kArcSegments = 96;
constexpr float kGrabTolerancePx = 14.0f;

inline bool grabsTrack(float distancePx, float hitScale) {
    return std::abs(distancePx - kTrackRadiusPx) <= kGrabTolerancePx * hitScale;
}

} // namespace umeshcore::SkewGizmoMetrics
