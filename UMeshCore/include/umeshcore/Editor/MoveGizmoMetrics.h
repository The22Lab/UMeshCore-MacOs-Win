#pragma once

// 1:1 port of `MoveGizmoMetrics.swift`. Device pixels, before the camera
// zoom divides them: the gizmo is chrome and keeps its size on screen
// however far in or out the canvas is. Every numeric constant here is
// named to match its Swift counterpart exactly, per UMeshCore/ROADMAP.md's
// guidance to keep gizmo tuning values greppable across the port.

#include <algorithm>

namespace umeshcore::MoveGizmoMetrics {

// --- What is drawn ---
constexpr float kCenterRadiusPx = 16.0f;
constexpr float kCenterInnerScale = 0.70f;
inline float axisInnerPx() { return kCenterRadiusPx * 1.03f; }
constexpr float kAxisLengthPx = 96.0f;

// --- What is grabbed ---
constexpr float kGrabMarginPx = 11.0f;
constexpr float kCenterShareOfAxis = 0.22f;

inline float centerGrabPx(float hitScale) {
    return std::min(kCenterRadiusPx + kGrabMarginPx * hitScale * 0.5f, kAxisLengthPx * kCenterShareOfAxis);
}

inline float axisGrabInnerPx(float hitScale) { return std::max(axisInnerPx(), centerGrabPx(hitScale)); }

inline float axisGrabOuterPx(float hitScale) { return kAxisLengthPx + kGrabMarginPx * hitScale; }

inline float axisGrabAcrossPx(float hitScale) { return kGrabMarginPx * hitScale; }

} // namespace umeshcore::MoveGizmoMetrics
