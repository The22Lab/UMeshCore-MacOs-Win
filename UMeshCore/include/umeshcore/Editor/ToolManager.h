#pragma once

// Port of `Core/ToolManager.swift` -- the central input dispatcher: resolves
// what a click/drag/release means (gizmo grab vs. selection change vs. tool
// action) and forwards it to whichever `Tool` is active.
//
// Tools currently wired in (`tools_`): Select, Bone, Move, Rotate, Scale,
// Skew. NOT wired in, and looked up the same way Swift's own
// `tools[currentTool]?.onMouseDown(...)` already handles a missing entry
// (silently does nothing) -- so selecting either of these is a real, safe
// no-op today, not a crash waiting to happen:
//   - `.Mesh`: `MeshTool` is not ported. Confirmed (by direct research
//     against the Swift source and this port's current `EditorScene`/
//     `ToolUtilities` surface) to be blocked on the asset/alpha pipeline
//     AND on a family of mesh-editing mutators
//     (`updateMeshVertex`/`insertMeshVertex`/`deleteSelectedMeshVertices`/
//     etc.) that don't exist yet -- every one of its sub-modes (Bind Mode,
//     Weight Paint, hull creation, vertex edit) routes through at least one
//     of those two gaps. Phase 4/5 scope; see ROADMAP.md.
//   - `.PhysicsPreview`: `PhysicsPreviewTool`'s own mouse-handling logic is
//     small and self-contained (hit-test a bone, store/clear a world-space
//     override while dragging), but the override has no consumer today --
//     `EditorScene` doesn't own a live `PhysicsConstraintSystem` instance,
//     and nothing in `SceneAnimator`'s pose evaluation reads a "preview
//     override" map. Porting the tool's mouse handlers without that
//     integration would compile and run but visibly do nothing, which is
//     worse than not having it; deferred until `EditorScene` (or whatever
//     eventually plays a live-rig-instance role) owns a physics sim state.
//
// Also NOT ported, and why: the IK-builder-picking intercept
// (`scene.ikBuilder?.pickingSlot`) and the Bind-Mode intercept
// (`scene.isBindingBonesMode`) at the top of `handleMouseDown`/
// `handleMouseMove` -- neither subsystem is modeled in `EditorScene` (see
// its file header). The sprite marquee-select branch of `handleMouseDrag`
// (`updateSelectionRect`, Select tool, not Pose mode) is also not ported:
// it depends on `ToolUtilities::hitTestRect`, which -- like
// `hitTestScreen`/`hitTestSelectionTarget` -- needs the same not-yet-built
// alpha/asset pipeline. The bone marquee (Pose mode) has no such
// dependency (`ToolUtilities::bonesIntersecting` is pure geometry) and IS
// ported. The on-iOS haptic feedback call, and the `skewState`/
// `rotationState` UI-observable mirroring Swift's own `ToolManager` does,
// are both platform/UI chrome with no model effect and are not ported,
// consistent with `SkewTool`'s/`RotateTool`'s own choices.
//
// One more finding, verified by grepping the whole Swift source tree (no
// other file references them): `ToolManager.swift`'s own
// `updateRotationHover`/`handleRotationMouseDown`/`handleRotationMouseDrag`/
// `syncRotationState` are private methods with ZERO call sites anywhere,
// including within `ToolManager` itself -- provably dead code, not merely
// unlikely to run (contrast with the `BoneTool` "Shift resizes the tip"
// finding, which IS reachable in principle, just not from the current
// caller). Not ported.
//
// Quick-switch (`activateQuickSwitchTool`/`endQuickSwitchOverlay`): the
// state-setting half is ported; the ~1.1s auto-clear timer is not, since it
// needs a platform scheduler this core library doesn't have one of. A
// caller wanting the auto-clear behavior schedules its own timer that
// calls `endQuickSwitchOverlay()`, the same "caller's concern" pattern this
// port already applies to physics stepping.

#include <memory>
#include <optional>
#include <unordered_map>

#include "umeshcore/Editor/CanvasPicking.h"
#include "umeshcore/Editor/EditorScene.h"
#include "umeshcore/Editor/Tool.h"
#include "umeshcore/Editor/ToolInput.h"
#include "umeshcore/Editor/ToolType.h"

namespace umeshcore {

class ToolManager {
public:
    ToolManager();

    ActiveTool currentTool = ActiveTool::Select;
    std::optional<ActiveTool> quickSwitchTool;
    std::optional<Vec2> quickSwitchCursorPosition;
    std::optional<ToolInput> lastInput;
    std::optional<GizmoHandle> hoveredHandle;
    std::optional<GizmoHandle> activeHandle;
    std::optional<ToolUtilities::ScreenRect> selectionRect;

    // Non-owning; the platform adapter owns the CameraState.
    CameraState* camera = nullptr;

    void setTool(EditorScene& scene, ActiveTool tool);
    void activateQuickSwitchTool(EditorScene& scene, ActiveTool tool, std::optional<Vec2> cursorPosition = std::nullopt);
    void endQuickSwitchOverlay();

    void handlePointerExit(EditorScene& scene);

    void handleMouseMove(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
        bool touchOptimized);
    void handleMouseDown(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
        bool touchOptimized);
    void handleMouseDrag(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
        bool touchOptimized);
    void handleMouseUp(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
        bool touchOptimized);
    void update(EditorScene& scene);

private:
    std::unordered_map<ActiveTool, std::unique_ptr<Tool>> tools_;

    void updateBoneSelectionRect(const ToolInput& input, EditorScene& scene);
    static std::optional<ToolUtilities::ScreenRect> marqueeRect(const ToolInput& input);
};

} // namespace umeshcore
