#pragma once

// 1:1 port of `RotateGizmoMetrics.swift`.

#include <cmath>

namespace umeshcore::RotateGizmoMetrics {

// --- The pivot ---
constexpr float kPivotRadiusPx = 13.0f;
constexpr float kPivotStrokePx = 3.2f;
constexpr float kNubRadiusPx = 2.6f;

// --- The track ---
constexpr float kTrackRadiusPx = 49.0f;
constexpr float kDotRadiusPx = 1.6f;
constexpr int kDotCount = 24;

// --- The needle ---
constexpr float kNeedleInnerPx = 18.0f;
constexpr float kNeedleOuterPx = 88.0f;
constexpr float kNeedleHalfWidthPx = 7.2f;

// --- Drawing ---
constexpr float kContourPx = 1.3f;
constexpr float kFeatherPx = 1.0f;
constexpr int kRingSegments = 72;
constexpr int kDotSegments = 14;

// --- Grabbing ---
constexpr float kGrabTolerancePx = 14.0f;

inline bool grabsTrack(float distancePx, float hitScale) {
    return std::abs(distancePx - kTrackRadiusPx) <= kGrabTolerancePx * hitScale;
}

// Whether a click lands on the needle itself.
inline bool grabsNeedle(float distancePx, float angleDelta, float hitScale) {
    if (!(distancePx >= kNeedleInnerPx) || !(distancePx <= kNeedleOuterPx)) return false;
    // Half the base width, plus a little slop, as an angle at this radius.
    const float halfWidth = kNeedleHalfWidthPx + kGrabTolerancePx * 0.5f * hitScale;
    return std::abs(angleDelta) <= std::atan2(halfWidth, std::max(distancePx, 1.0f));
}

} // namespace umeshcore::RotateGizmoMetrics
