#pragma once

// 1:1 port of `Core/Tools/SelectTool.swift`.

#include "umeshcore/Editor/Tool.h"

namespace umeshcore {

class SelectTool final : public Tool {
public:
    ActiveTool type() const override { return ActiveTool::Select; }

    void onMouseDown(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
        bool touchOptimized) override;

    void onMouseDrag(const ToolInput&, EditorScene&, const ImageHitTestFn&, float, bool) override {}
    void onMouseUp(const ToolInput&, EditorScene&, const ImageHitTestFn&, float, bool) override {}
};

} // namespace umeshcore
