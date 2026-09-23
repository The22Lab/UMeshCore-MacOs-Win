#pragma once

// Port of `Core/ToolManager.swift` -- the central input dispatcher: resolves
// what a click/drag/release means (gizmo grab vs. selection change vs. tool
// action) and forwards it to whichever `Tool` is active.
//
// All eight tools are wired in (`tools_`): Select, Bone, Mesh, Move,
// Rotate, Scale, Skew, PhysicsPreview. `.Mesh` was the last to land (Phase
// 6a), once the alpha pipeline (`AssetAlphaStore`) and the mesh mutators
// (`EditorSceneMesh.cpp`) existed; with it came everything here that was
// "MeshTool-scoped": the weight-paint guards on a selection click, the
// sprite-mesh-mode branch, the mesh marquee, the hovered mesh node, and
// the real asset size / deform / weight-paint flags for the gizmo test.
// `.PhysicsPreview` is registered although its pose override has no
// reader, in Swift either -- see `PhysicsPreviewTool.h`.
//
// Also ported in Phase 6a: the IK-builder picking intercept and hover, the
// Bind-Mode intercept and hover, and the sprite marquee (`hitTestRect`).
//
// ASSETS. The texture side (sizes, alpha) is needed by the sprite marquee,
// Bind Mode, the mesh gizmo and the mesh tool. It is available only through
// the `handleMouse*(…, const AssetAlphaStore&, …)` overloads, which expose
// it for the one event they dispatch. The `ImageHitTestFn` overloads keep
// working without it, as they always did: whatever needs a texture then
// finds none and does nothing -- which is what Swift does when
// `assets.asset(for:)` fails.
//
// Not ported: the on-iOS haptic feedback call, and the `skewState`/
// `rotationState` UI-observable mirroring Swift's own `ToolManager` does --
// platform/UI chrome with no model effect, consistent with `SkewTool`'s/
// `RotateTool`'s own choices.
//
// One more finding, verified by grepping the whole Swift source tree (no
// other file references them): `ToolManager.swift`'s own
// `updateRotationHover`/`handleRotationMouseDown`/`handleRotationMouseDrag`/
// `syncRotationState` are private methods with ZERO call sites anywhere,
// including within `ToolManager` itself -- provably dead code, not merely
// unlikely to run. Not ported.
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

#include "umeshcore/Editor/AssetAlphaStore.h"
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

    // The same four, with sprites picked by alpha from `assets` -- the form
    // a shell calls (Swift cannot build the `std::function` above; these
    // bind `CanvasImagePicking::imageHit` into it here).
    void handleMouseMove(const ToolInput& input, EditorScene& scene, const AssetAlphaStore& assets, float hitScale,
                         bool touchOptimized);
    void handleMouseDown(const ToolInput& input, EditorScene& scene, const AssetAlphaStore& assets, float hitScale,
                         bool touchOptimized);
    void handleMouseDrag(const ToolInput& input, EditorScene& scene, const AssetAlphaStore& assets, float hitScale,
                         bool touchOptimized);
    void handleMouseUp(const ToolInput& input, EditorScene& scene, const AssetAlphaStore& assets, float hitScale,
                       bool touchOptimized);

    // Drop the half-drawn mesh edge, if any (the canvas prompt's Cancel).
    void cancelPendingMeshEdge(EditorScene& scene);

private:
    std::unordered_map<ActiveTool, std::unique_ptr<Tool>> tools_;
    const AssetAlphaStore* assets_ = nullptr;
    struct AssetScope;
    void setAssets(const AssetAlphaStore* store);
    std::optional<ToolUtilities::MeshProjection> selectedMeshProjection(const EditorScene& scene, const Vec2& viewSize,
                                                                        float hitScale) const;
    Vec2 selectedAssetSize(const EditorScene& scene) const;
    void updateSelectionRect(const ToolInput& input, EditorScene& scene);
    void updateMeshSelectionRect(const ToolInput& input, EditorScene& scene, float hitScale);

    void updateBoneSelectionRect(const ToolInput& input, EditorScene& scene);
    static std::optional<ToolUtilities::ScreenRect> marqueeRect(const ToolInput& input);
};

} // namespace umeshcore
