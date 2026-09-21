#pragma once

// 1:1 port of `ToolInput` from `Core/Tooling.swift` -- the platform-neutral
// input boundary. Platform views (SwiftUI+AppKit/UIKit today, WinUI3
// tomorrow) translate native pointer/keyboard events into this struct;
// everything downstream (ToolManager, the 8 tools) is pure C++ logic with
// no platform event types in it.

#include <optional>

#include "umeshcore/Editor/CameraState.h"
#include "umeshcore/Editor/GizmoHandle.h"
#include "umeshcore/Math/Vec.h"

namespace umeshcore {

struct ToolInput {
    Vec2 position;
    Vec2 startPosition;
    Vec2 screenPosition;
    Vec2 previousScreenPosition;
    Vec2 screenDelta;
    Vec2 startScreenPosition;
    Vec2 viewSize;
    bool isDragging = false;
    bool isShiftPressed = false;
    bool isCommandPressed = false;
    int clickCount = 0;
    std::optional<GizmoHandle> hoveredHandle;
    std::optional<GizmoHandle> activeHandle;
    // Non-owning; the platform adapter/ToolManager owns the CameraState.
    CameraState* camera = nullptr;
    // True when ToolManager's selection block moved the selected sprite on
    // this very mouse-down -- a tool that edits the selected sprite reads
    // this to know the click was spent on selecting, not editing.
    bool didChangeSelection = false;
};

} // namespace umeshcore
