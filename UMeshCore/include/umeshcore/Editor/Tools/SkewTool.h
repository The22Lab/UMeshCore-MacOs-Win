#pragma once

// Port of `Core/Tools/SkewTool.swift`.
//
// NOT PORTED: `SkewGizmoState` mirroring (`skewState.mouseDown`/
// `applyDrag`/`mouseUp`, and `update()`'s idle resync). It is UI-facing,
// observable gizmo-overlay state (which arc is highlighted, drag-angle
// readout) with no effect on the model -- the same reasoning
// `MoveGizmoMetrics`/`RotateGizmoMetrics`/etc. are ported as constants but
// their `@Published` *drawing* counterparts are not. This tool's `update`
// is therefore omitted entirely (its only job in Swift is that resync).

#include <optional>

#include "umeshcore/Editor/Tool.h"

namespace umeshcore {

// Which local axis a skew-edge handle drags. Matches `Core/ShearTransform.swift`'s
// `ShearAxis`.
enum class ShearAxis { ShearX, ShearY, ShearZ };

class SkewTool final : public Tool {
public:
    ActiveTool type() const override { return ActiveTool::Skew; }

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
    Vec2 startSkew_ = Vec2::zero();
    std::optional<ShearAxis> activeAxis_;
    float startAngle_ = 0.0f;
    Vec2 boneCenter_ = Vec2::zero();
    std::optional<Vec2> mouseDownPosition_;
    bool didDrag_ = false;

    static constexpr float kDragThreshold = 4.0f;

    bool ensureDragStarted(const Vec2& currentPosition);
    static std::optional<ShearAxis> axisFor(const GizmoHandle& handle);
};

} // namespace umeshcore
