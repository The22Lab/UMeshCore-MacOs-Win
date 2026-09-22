#pragma once

// 1:1 port of `Core/Tools/RotateTool.swift`.
//
// NOTE (verified against the Swift source, not assumed): despite the name,
// this tool never references `RotationGizmoState`/`ArcHitTest` (a separate
// 3D-tilt gizmo/tool this port has not identified or touched). Its only
// interaction with 3D rotation is zeroing `SceneImage::rotation3D` when the
// tool grabs a sprite, so that gizmo's effect is disabled while this one is
// in control. Nothing here is blocked by that other gizmo being unported.

#include <optional>
#include <unordered_map>
#include <vector>

#include "umeshcore/Editor/Tool.h"

namespace umeshcore {

class RotateTool final : public Tool {
public:
    ActiveTool type() const override { return ActiveTool::Rotate; }

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
    // Every selected bone, parents first -- same order/reason as MoveTool
    // and ScaleTool's group drags.
    std::vector<Uuid> boneDragOrder_;
    std::unordered_map<Uuid, float, UuidHash> boneStartRotations_;
    float startRotation_ = 0.0f;
    float startAngle_ = 0.0f;
    Vec2 boneStart_ = Vec2::zero();
    float boneLength_ = 0.0f;
    // Sprite rotation eases toward this after mouse-up, same "settle"
    // pattern as ScaleTool.
    std::optional<float> settleTarget_;
    std::optional<Uuid> settleID_;
    std::optional<Vec2> mouseDownPosition_;
    bool didDrag_ = false;

    static constexpr float kSettleFactor = 0.22f;
    static constexpr float kSnapStepDegrees = 15.0f;
    static constexpr float kDragThreshold = 4.0f;

    bool ensureDragStarted(const Vec2& currentPosition);
};

} // namespace umeshcore
