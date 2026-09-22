#pragma once

// Port of `Core/Tools/MoveTool.swift`.
//
// NOT PORTED: the mesh-vertex-drag branch (dragging a selected mesh
// vertex directly, without the Move gizmo). Blocked on two gaps, both
// already tracked in ROADMAP.md: the branch's own entry condition reads
// `assets.asset(for: image.assetID)` (the asset/texture pipeline, Phase
// 4/5), and its per-frame write goes through `updateMeshVertex`, which
// needs `Mesh::clampedPositionInsideHullIfNeeded` (itself needing
// `hullVertexIndices`/`pointInsideHull`/`pointOnHullBoundary` -- not
// ported). Bone dragging and sprite dragging, this tool's other two
// branches, have neither dependency and are ported here in full.

#include <optional>
#include <unordered_map>
#include <vector>

#include "umeshcore/Editor/Tool.h"

namespace umeshcore {

class MoveTool final : public Tool {
public:
    ActiveTool type() const override { return ActiveTool::Move; }

    void onMouseDown(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
        bool touchOptimized) override;
    void onMouseDrag(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
        bool touchOptimized) override;
    void onMouseUp(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
        bool touchOptimized) override;

private:
    std::optional<Uuid> activeID_;
    std::optional<Uuid> activeBoneID_;
    // Every selected bone, parents first -- `moveBoneRoot` converts a world
    // point into PARENT space, so a parent already moved is the frame the
    // child has to be written in.
    std::vector<Uuid> boneDragOrder_;
    // Where each of them started, so the drag translates the group rather
    // than stacking every bone onto the active one's position.
    std::unordered_map<Uuid, Vec2, UuidHash> boneStartPositions_;
    Vec2 startPosition_ = Vec2::zero();
    Vec2 dragPosition_ = Vec2::zero();
    Vec2 grabOffsetScreen_ = Vec2::zero();
    std::optional<Vec2> mouseDownPosition_;
    bool didDrag_ = false;

    static constexpr float kGridSize = 1.0f;
    static constexpr float kDragThreshold = 4.0f;

    bool ensureDragStarted(const Vec2& currentPosition);
    Vec2 computeDragPosition(const ToolInput& input, const Vec2& startPosition) const;
};

} // namespace umeshcore
