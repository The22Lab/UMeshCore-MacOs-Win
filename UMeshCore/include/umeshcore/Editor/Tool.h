#pragma once

// 1:1 port of the `Tool` protocol from `Core/Tooling.swift`.
//
// DEVIATION FROM THE SWIFT SOURCE, DELIBERATE: each method there takes
// `scene: SceneManager, assets: AssetManager`; here they take
// `EditorScene&` (see EditorScene.h) plus an `ImageHitTestFn` (see
// CanvasPicking.h) for the one thing a tool might need from the not-yet-
// ported asset pipeline -- alpha-based image hit-testing. A concrete tool
// that needs neither simply ignores the parameter it doesn't use.
//
// Also added, absent from Swift's `Tool` protocol: `hitScale`/
// `touchOptimized`. In Swift, `ToolUtilities.hitTestBoneDetailed`/
// `hitTestGizmo` read `touchHitScale`/`#if os(iOS)` directly from the
// platform (`UITraitCollection`, compile-time OS). This port's
// `ToolUtilities.h` already externalizes both as explicit parameters
// (documented there) since C++ has no such platform API to read from --
// this interface threads them the rest of the way, from whatever calls a
// tool's methods (`ToolManager`, not yet ported) down to the tool, exactly
// as `ToolUtilitiesTests.cpp` already passes them explicitly at every
// picking call site.

#include "umeshcore/Editor/CanvasPicking.h"
#include "umeshcore/Editor/EditorScene.h"
#include "umeshcore/Editor/ToolInput.h"
#include "umeshcore/Editor/ToolType.h"

namespace umeshcore {

class Tool {
public:
    virtual ~Tool() = default;

    virtual ActiveTool type() const = 0;

    virtual void onMouseDown(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
        bool touchOptimized) = 0;
    virtual void onMouseDrag(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
        bool touchOptimized) = 0;
    virtual void onMouseUp(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
        bool touchOptimized) = 0;

    // Swift's `Tool` protocol extension default -- most tools have nothing
    // to do per-frame outside a mouse event.
    virtual void update(EditorScene&) {}
};

} // namespace umeshcore
