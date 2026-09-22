#pragma once

// 1:1 port of `Core/Tools/ScaleTool.swift`.

#include <optional>
#include <unordered_map>
#include <vector>

#include "umeshcore/Editor/Tool.h"

namespace umeshcore {

class ScaleTool final : public Tool {
public:
    ActiveTool type() const override { return ActiveTool::Scale; }

    void onMouseDown(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
        bool touchOptimized) override;
    void onMouseDrag(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
        bool touchOptimized) override;
    void onMouseUp(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
        bool touchOptimized) override;
    void update(EditorScene& scene) override;

private:
    std::optional<Uuid> activeID_;
    std::optional<Uuid> activeBoneID_;
    // Every selected bone, parents first -- same order/reason as MoveTool.
    std::vector<Uuid> boneDragOrder_;
    std::unordered_map<Uuid, Vec2, UuidHash> boneStartScales_;
    std::unordered_map<Uuid, float, UuidHash> boneStartLengths_;
    std::optional<GizmoHandle> activeHandle_;
    Vec2 startScale_ = Vec2::one();
    float startDistance_ = 1.0f;
    Vec2 startVector_ = Vec2::zero();
    Vec2 boneStart_ = Vec2::zero();
    float startBoneLength_ = 0.0f;
    Vec2 startBoneScale_ = Vec2::one();
    // Sprite scale eases toward this after mouse-up rather than snapping
    // instantly, so a Shift-snapped release doesn't visibly jump.
    std::optional<Vec2> settleTarget_;
    std::optional<Uuid> settleID_;
    std::optional<Vec2> mouseDownPosition_;
    bool didDrag_ = false;

    static constexpr float kSettleFactor = 0.22f;
    static constexpr float kSnapStep = 0.1f;
    static constexpr float kDragThreshold = 4.0f;

    bool ensureDragStarted(const Vec2& currentPosition);
};

} // namespace umeshcore
