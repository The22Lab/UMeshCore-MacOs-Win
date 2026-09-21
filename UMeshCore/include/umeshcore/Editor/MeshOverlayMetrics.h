#pragma once

// 1:1 port of `MeshOverlayMetrics.swift`.

#include "umeshcore/Math/Vec.h"

namespace umeshcore::MeshOverlayMetrics {

// --- Nodes ---
constexpr float kNodeRadiusPx = 7.4f;
constexpr float kWeightNodeRadiusPx = 13.0f;
constexpr float kShadowScale = 1.52f;
constexpr float kRimScale = 1.24f;
constexpr int kSegments = 24;
constexpr int kPieSegments = 28;
inline Vec4 shadowInk() { return Vec4(0.04f, 0.04f, 0.05f, 0.28f); }
inline Vec4 rimInk() { return Vec4(0.09f, 0.07f, 0.12f, 0.94f); }

// --- Lines ---
constexpr float kContourWidthPx = 3.5f;
constexpr float kInternalEdgeWidthPx = 2.5f;
constexpr float kConnectionWidthPx = 1.7f;

// --- Grabbing ---
constexpr float kGrabSlopPx = 2.0f;

inline float nodeRadiusPx(bool weightPainting) { return weightPainting ? kWeightNodeRadiusPx : kNodeRadiusPx; }
inline float grabRadiusPx(bool weightPainting) { return nodeRadiusPx(weightPainting) + kGrabSlopPx; }

} // namespace umeshcore::MeshOverlayMetrics
