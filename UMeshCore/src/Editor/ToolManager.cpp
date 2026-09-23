#include "umeshcore/Editor/ToolManager.h"

#include <algorithm>
#include <cmath>
#include <variant>

#include "umeshcore/Editor/Tools/BoneTool.h"
#include "umeshcore/Editor/Tools/PhysicsPreviewTool.h"
#include "umeshcore/Editor/Tools/MoveTool.h"
#include "umeshcore/Editor/Tools/RotateTool.h"
#include "umeshcore/Editor/Tools/ScaleTool.h"
#include "umeshcore/Editor/Tools/SelectTool.h"
#include "umeshcore/Editor/Tools/SkewTool.h"

namespace umeshcore {

ToolManager::ToolManager() {
    tools_[ActiveTool::Select] = std::make_unique<SelectTool>();
    tools_[ActiveTool::Bone] = std::make_unique<BoneTool>();
    tools_[ActiveTool::Move] = std::make_unique<MoveTool>();
    tools_[ActiveTool::Rotate] = std::make_unique<RotateTool>();
    tools_[ActiveTool::Scale] = std::make_unique<ScaleTool>();
    tools_[ActiveTool::Skew] = std::make_unique<SkewTool>();
    tools_[ActiveTool::PhysicsPreview] = std::make_unique<PhysicsPreviewTool>();
    // .Mesh deliberately absent -- see the file header.
}

void ToolManager::setTool(EditorScene& scene, ActiveTool tool) {
    currentTool = tool;
    scene.canvasToolChanged(tool);
}

void ToolManager::activateQuickSwitchTool(
    EditorScene& scene, ActiveTool tool, std::optional<Vec2> cursorPosition) {
    currentTool = tool;
    scene.canvasToolChanged(tool);
    quickSwitchTool = tool;
    if (cursorPosition.has_value()) quickSwitchCursorPosition = cursorPosition;
    // The ~1.1s auto-clear timer is the caller's concern -- see file header.
}

void ToolManager::endQuickSwitchOverlay() {
    quickSwitchTool = std::nullopt;
    quickSwitchCursorPosition = std::nullopt;
}

void ToolManager::handlePointerExit(EditorScene& scene) {
    // Never mid-drag: a drag owns its state until it ends (dragging a
    // sprite off the canvas can carry the pointer off it too).
    if (activeHandle.has_value() || (lastInput.has_value() && lastInput->isDragging)) return;

    lastInput = std::nullopt;
    hoveredHandle = std::nullopt;
    if (scene.hoveredImageID.has_value()) scene.hoveredImageID = std::nullopt;
    if (scene.hoveredMeshVertexIndex.has_value()) scene.hoveredMeshVertexIndex = std::nullopt;
    if (scene.hoveredBindBoneID.has_value()) scene.hoveredBindBoneID = std::nullopt;
    // ikBuilderHoveredBoneID: not modeled (IK builder not ported).
}

void ToolManager::handleMouseMove(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
    bool touchOptimized) {
    lastInput = input;

    // IK-builder-picking hover and Bind-Mode hover: not ported, neither
    // subsystem is modeled in EditorScene -- see the file header.

    // PRE-SELECTION: resolved through the same picker a click uses, and
    // stored as what the click would RETURN, so the hover outline is a
    // promise about the next click rather than a guess about the cursor.
    // nil when a bone would win a click there.
    std::optional<Uuid> hoveredImage;
    if (const auto hit = target(
            input.screenPosition, input.viewSize, scene.skeleton, scene.selectedBoneID, camera, hitScale,
            touchOptimized, imageHitTest);
        hit.has_value() && hit->kind == SelectionTarget::Kind::Image) {
        hoveredImage = hit->id;
    }
    if (scene.hoveredImageID != hoveredImage) scene.hoveredImageID = hoveredImage;

    const SceneImage* selectedImage = scene.selectedImageID.has_value() ? scene.image(*scene.selectedImageID) : nullptr;
    const std::optional<Skeleton::LineSegment> selectedBoneSegment =
        scene.selectedBoneID.has_value() ? scene.skeleton.lineSegment(*scene.selectedBoneID) : std::nullopt;
    // Asset size / mesh-deform / weight-paint flags: only consulted by
    // hitTestGizmo's `.mesh` case, which is never the active tool today
    // (MeshTool isn't wired in) -- harmless placeholders, not a silent gap.
    hoveredHandle = ToolUtilities::hitTestGizmo(
        currentTool, input.screenPosition, input.viewSize, selectedImage, Vec2::zero(), selectedBoneSegment,
        scene.selectedBoneID, &scene.skeleton, /*showMeshDeformed=*/false, /*weightPainting=*/false, camera,
        hitScale, touchOptimized);
    // A handle under the cursor means the click grabs the gizmo, not a
    // sprite, so the pre-selection has to agree with that.
    if (hoveredHandle.has_value() && scene.hoveredImageID.has_value()) scene.hoveredImageID = std::nullopt;

    // Skew hover-arc tracking and mesh-vertex hover: not ported (UI-only
    // gizmo state / MeshTool-scoped, respectively -- see file header).
}

void ToolManager::handleMouseDown(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
    bool touchOptimized) {
    // IK-builder-picking intercept and Bind-Mode intercept: not ported,
    // neither subsystem is modeled in EditorScene -- see the file header.

    const SceneImage* selectedImageForGizmo =
        scene.selectedImageID.has_value() ? scene.image(*scene.selectedImageID) : nullptr;
    const std::optional<Skeleton::LineSegment> selectedBoneSegment =
        scene.selectedBoneID.has_value() ? scene.skeleton.lineSegment(*scene.selectedBoneID) : std::nullopt;
    hoveredHandle = ToolUtilities::hitTestGizmo(
        currentTool, input.screenPosition, input.viewSize, selectedImageForGizmo, Vec2::zero(),
        selectedBoneSegment, scene.selectedBoneID, &scene.skeleton, false, false, camera, hitScale,
        touchOptimized);
    activeHandle = hoveredHandle;
    // Skew hover-arc tracking on grab: not ported (UI-only, see file header).

    const std::optional<Uuid> currentSelectionID =
        scene.selectedBoneID.has_value() ? scene.selectedBoneID : scene.selectedImageID;
    const bool hasFocusedSelection = currentSelectionID.has_value();
    const std::optional<Uuid> imageSelectedBeforeClick = scene.selectedImageID;

    // Weight paint / Bind-Mode "holds its target" guards, and the
    // "bones arm the weight-paint brush" guard: MeshTool-scoped, not
    // modeled (always false while MeshTool isn't wired in).
    const bool holdsSelectionForPainting = false;
    const bool bonesArmTheBrush = false;

    // Touch has no hover and no double-click convention: a tap switches
    // selection immediately, matching the Swift source's #if os(iOS)
    // branch (Mesh mode excluded there too, though it's moot here since
    // MeshTool isn't wired in). Desktop: only the Select tool switches on
    // a single click; any other tool needs a double click.
    const bool allowSelectionChange =
        touchOptimized ? (currentTool != ActiveTool::Mesh || input.clickCount >= 2)
                        : (currentTool == ActiveTool::Select || input.clickCount >= 2);

    const auto hitTarget = target(
        input.screenPosition, input.viewSize, scene.skeleton, scene.selectedBoneID, camera, hitScale,
        touchOptimized, imageHitTest);

    if (!activeHandle.has_value()) {
        if (hitTarget.has_value()) {
            if (hitTarget->kind == SelectionTarget::Kind::Image) {
                const Uuid hitID = hitTarget->id;
                const bool canSwitch =
                    !holdsSelectionForPainting &&
                    (!hasFocusedSelection || allowSelectionChange || currentSelectionID == hitID);
                if (canSwitch) {
                    // isSpriteMeshMode (a whole-canvas "always edit the
                    // mesh" mode) is MeshTool-scoped and not modeled;
                    // isMeshLayerSelected IS modeled, so that half of the
                    // Swift condition is preserved.
                    if (scene.isMeshLayerSelected && scene.selectedImageID.has_value() &&
                        *scene.selectedImageID == hitID) {
                        scene.selectMeshLayer(hitID);
                    } else if (
                        currentTool == ActiveTool::Select || !scene.selectedImageID.has_value() ||
                        currentSelectionID != hitID) {
                        scene.setSelection({hitID}, hitID, input.isShiftPressed);
                    }
                }
                if (scene.selectedImageID.has_value() && *scene.selectedImageID == hitID) {
                    if (currentTool == ActiveTool::Bone) {
                        activeHandle = std::nullopt;
                    } else if (currentTool == ActiveTool::Rotate) {
                        activeHandle = GizmoHandleFactory::rotateRing();
                    } else if (currentTool == ActiveTool::Mesh) {
                        activeHandle = hoveredHandle;
                    } else if (currentTool == ActiveTool::Scale) {
                        activeHandle = GizmoHandleFactory::scaleCorner(2);
                    } else {
                        activeHandle = ToolUtilities::defaultHandle(currentTool);
                    }
                }
            } else {
                const Uuid hitID = hitTarget->id;
                const bool canSwitch =
                    !holdsSelectionForPainting && !bonesArmTheBrush &&
                    (!hasFocusedSelection || allowSelectionChange || currentSelectionID == hitID);
                if (canSwitch) scene.selectBone(hitID);
            }
        } else {
            if (currentTool == ActiveTool::Bone) {
                activeHandle = std::nullopt;
            } else if (
                currentTool == ActiveTool::Rotate &&
                (scene.selectedImageID.has_value() || scene.selectedBoneID.has_value())) {
                activeHandle = GizmoHandleFactory::rotateRing();
            } else if (currentTool == ActiveTool::Mesh) {
                activeHandle = std::nullopt;
            } else if (
                currentTool == ActiveTool::Scale &&
                (scene.selectedImageID.has_value() || scene.selectedBoneID.has_value())) {
                activeHandle = GizmoHandleFactory::scaleCorner(2);
            } else if (currentTool == ActiveTool::Select) {
                scene.clearSelection();
            }
        }
    }

    // On-device haptic feedback on a selection change: platform UI, not
    // ported. Mesh weight-paint selection-rect clearing: MeshTool-scoped,
    // not ported.

    ToolInput enriched = input;
    enriched.hoveredHandle = hoveredHandle;
    enriched.activeHandle = activeHandle;
    enriched.camera = camera;
    // Decided HERE, where the switch happened, rather than re-derived
    // inside the tool: by the time the tool runs, selectedImageID is
    // already the new sprite and the tool has nothing to compare against.
    enriched.didChangeSelection = scene.selectedImageID != imageSelectedBeforeClick;
    lastInput = enriched;

    if (auto it = tools_.find(currentTool); it != tools_.end()) {
        it->second->onMouseDown(enriched, scene, imageHitTest, hitScale, touchOptimized);
    }
}

void ToolManager::handleMouseDrag(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
    bool touchOptimized) {
    if (!activeHandle.has_value()) {
        if (currentTool == ActiveTool::Select) {
            // Pose mode is about the skeleton, so the marquee there takes
            // bones; everywhere else it takes sprites.
            if (scene.isPoseMode) {
                updateBoneSelectionRect(input, scene);
            } else {
                // Sprite marquee (updateSelectionRect): not ported -- needs
                // ToolUtilities::hitTestRect, blocked on the same
                // not-yet-built asset pipeline as hitTestScreen/
                // hitTestSelectionTarget. See the file header.
                selectionRect = marqueeRect(input);
            }
        }
        // Mesh selection-rect (Select+Mesh modify mode): MeshTool-scoped,
        // not ported.
    }

    ToolInput enriched = input;
    enriched.hoveredHandle = hoveredHandle;
    enriched.activeHandle = activeHandle;
    enriched.camera = camera;
    lastInput = enriched;

    if (auto it = tools_.find(currentTool); it != tools_.end()) {
        it->second->onMouseDrag(enriched, scene, imageHitTest, hitScale, touchOptimized);
    }
}

void ToolManager::handleMouseUp(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
    bool touchOptimized) {
    ToolInput enriched = input;
    enriched.hoveredHandle = hoveredHandle;
    enriched.activeHandle = activeHandle;
    enriched.camera = camera;
    lastInput = enriched;

    if (auto it = tools_.find(currentTool); it != tools_.end()) {
        it->second->onMouseUp(enriched, scene, imageHitTest, hitScale, touchOptimized);
    }
    activeHandle = std::nullopt;
    selectionRect = std::nullopt;
    // Skew hover-arc clear on release: not ported (UI-only, see file header).
}

void ToolManager::update(EditorScene& scene) {
    if (auto it = tools_.find(currentTool); it != tools_.end()) {
        it->second->update(scene);
    }
}

std::optional<ToolUtilities::ScreenRect> ToolManager::marqueeRect(const ToolInput& input) {
    const float dx = input.screenPosition.x - input.startScreenPosition.x;
    const float dy = input.screenPosition.y - input.startScreenPosition.y;
    if (!(std::abs(dx) >= 3.0f || std::abs(dy) >= 3.0f)) return std::nullopt;
    const float minX = std::min(input.startScreenPosition.x, input.screenPosition.x);
    const float maxX = std::max(input.startScreenPosition.x, input.screenPosition.x);
    const float minY = std::min(input.startScreenPosition.y, input.screenPosition.y);
    const float maxY = std::max(input.startScreenPosition.y, input.screenPosition.y);
    return ToolUtilities::ScreenRect{Vec2(minX, minY), Vec2(maxX, maxY)};
}

void ToolManager::updateBoneSelectionRect(const ToolInput& input, EditorScene& scene) {
    const auto rect = marqueeRect(input);
    if (!rect.has_value()) {
        selectionRect = std::nullopt;
        return;
    }
    selectionRect = rect;

    const std::vector<Uuid> ids = ToolUtilities::bonesIntersecting(*rect, input.viewSize, scene.skeleton, camera);
    // The bone being worked on survives a box that still contains it, so
    // re-dragging the marquee does not hand the inspector to a neighbour
    // halfway through posing.
    const bool containsSelected =
        scene.selectedBoneID.has_value() &&
        std::find(ids.begin(), ids.end(), *scene.selectedBoneID) != ids.end();
    std::optional<Uuid> primary = containsSelected ? scene.selectedBoneID : std::nullopt;
    if (!containsSelected && !ids.empty()) primary = ids.front();
    scene.setBoneSelection(ids, primary, input.isShiftPressed || input.isCommandPressed);
}

} // namespace umeshcore
