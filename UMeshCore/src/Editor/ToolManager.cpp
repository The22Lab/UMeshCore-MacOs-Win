#include "umeshcore/Editor/ToolManager.h"

#include "umeshcore/Editor/CanvasImagePicking.h"

#include <algorithm>
#include <cmath>
#include <variant>

#include "umeshcore/Editor/Tools/BoneTool.h"
#include "umeshcore/Editor/Tools/MeshTool.h"
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
    tools_[ActiveTool::Mesh] = std::make_unique<MeshTool>();
}

void ToolManager::cancelPendingMeshEdge(EditorScene& scene) {
    if (auto* mesh = dynamic_cast<MeshTool*>(tools_[ActiveTool::Mesh].get())) mesh->cancelPendingCreateEdge(scene);
}

// While a store-taking overload dispatches, the store is visible to the
// whole event (this object's own hit tests, and the mesh tool's).
struct ToolManager::AssetScope {
    ToolManager& manager;
    AssetScope(ToolManager& m, const AssetAlphaStore* store) : manager(m) { manager.setAssets(store); }
    ~AssetScope() { manager.setAssets(nullptr); }
};

void ToolManager::setAssets(const AssetAlphaStore* store) {
    assets_ = store;
    if (auto* mesh = dynamic_cast<MeshTool*>(tools_[ActiveTool::Mesh].get())) mesh->assets = store;
}

std::optional<ToolUtilities::MeshProjection> ToolManager::selectedMeshProjection(const EditorScene& scene,
                                                                                   const Vec2& viewSize,
                                                                                   float hitScale) const {
    if (assets_ == nullptr) return std::nullopt;
    return CanvasImagePicking::selectedMeshProjection(scene, *assets_, camera, viewSize, hitScale);
}

Vec2 ToolManager::selectedAssetSize(const EditorScene& scene) const {
    if (assets_ == nullptr || !scene.selectedImageID.has_value()) return Vec2::zero();
    const SceneImage* image = scene.image(*scene.selectedImageID);
    const AssetAlpha* asset = image != nullptr ? assets_->find(image->assetID) : nullptr;
    return asset != nullptr ? asset->size : Vec2::zero();
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
    if (scene.ikBuilderHoveredBoneID.has_value()) scene.ikBuilderHoveredBoneID = std::nullopt;
}

void ToolManager::handleMouseMove(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
    bool touchOptimized) {
    lastInput = input;

    const auto boneUnderPointer = [&] {
        return ToolUtilities::hitTestBone(input.screenPosition, input.viewSize, scene.skeleton, scene.selectedBoneID,
                                          camera, touchOptimized);
    };

    // The bone a click would pick while the IK builder is picking. Written
    // only when it changes (a published property fires on assignment).
    if (scene.ikBuilder.has_value() && scene.ikBuilder->pickingSlot.has_value()) {
        const auto hovered = boneUnderPointer();
        if (scene.ikBuilderHoveredBoneID != hovered) scene.ikBuilderHoveredBoneID = hovered;
    } else if (scene.ikBuilderHoveredBoneID.has_value()) {
        scene.ikBuilderHoveredBoneID = std::nullopt;
    }

    // Bind Mode is about bones: the hovered bone, and no sprite
    // pre-selection competing with it.
    if (scene.isBindingBonesMode && scene.selectedImageID.has_value()) {
        const auto hovered = boneUnderPointer();
        if (scene.hoveredBindBoneID != hovered) scene.hoveredBindBoneID = hovered;
        if (scene.hoveredImageID.has_value()) scene.hoveredImageID = std::nullopt;
    } else if (scene.hoveredBindBoneID.has_value()) {
        scene.hoveredBindBoneID = std::nullopt;
    }

    // PRE-SELECTION: resolved through the same picker a click uses, and
    // stored as what the click would RETURN, so the hover outline is a
    // promise about the next click rather than a guess about the cursor.
    // nil when a bone would win a click there.
    if (!scene.isBindingBonesMode) {
        std::optional<Uuid> hoveredImage;
        if (const auto hit = target(input.screenPosition, input.viewSize, scene.skeleton, scene.selectedBoneID, camera,
                                    hitScale, touchOptimized, imageHitTest);
            hit.has_value() && hit->kind == SelectionTarget::Kind::Image) {
            hoveredImage = hit->id;
        }
        if (scene.hoveredImageID != hoveredImage) scene.hoveredImageID = hoveredImage;
    }

    const SceneImage* selectedImage = scene.selectedImageID.has_value() ? scene.image(*scene.selectedImageID) : nullptr;
    const std::optional<Skeleton::LineSegment> selectedBoneSegment =
        scene.selectedBoneID.has_value() ? scene.skeleton.lineSegment(*scene.selectedBoneID) : std::nullopt;
    hoveredHandle = ToolUtilities::hitTestGizmo(
        currentTool, input.screenPosition, input.viewSize, selectedImage, selectedAssetSize(scene),
        selectedBoneSegment, scene.selectedBoneID, &scene.skeleton, scene.isMeshOverlayDeformed(),
        scene.meshWeightPaintEnabled, camera, hitScale, touchOptimized);
    // A handle under the cursor means the click grabs the gizmo, not a
    // sprite, so the pre-selection has to agree with that.
    if (hoveredHandle.has_value() && scene.hoveredImageID.has_value()) scene.hoveredImageID = std::nullopt;

    // The hovered mesh node. With the mesh tool up, `hoveredHandle` IS the
    // hovered node (`hitTestGizmo` just ran the same test); any other tool
    // asked nothing about the mesh, so the work is done here.
    if (scene.isMeshLayerSelected) {
        std::optional<int> hoveredVertex;
        const MeshVertexHandle* node = hoveredHandle.has_value() ? std::get_if<MeshVertexHandle>(&*hoveredHandle) : nullptr;
        if (node != nullptr) {
            hoveredVertex = node->index;
        } else if (currentTool != ActiveTool::Mesh) {
            if (const auto projection = selectedMeshProjection(scene, input.viewSize, hitScale)) {
                hoveredVertex = ToolUtilities::hitTestMeshVertex(input.screenPosition, *projection);
            }
        }
        if (scene.hoveredMeshVertexIndex != hoveredVertex) scene.hoveredMeshVertexIndex = hoveredVertex;
    } else if (scene.hoveredMeshVertexIndex.has_value()) {
        scene.hoveredMeshVertexIndex = std::nullopt;
    }
    // Skew hover-arc tracking: not ported (UI-only, see file header).
}

void ToolManager::handleMouseDown(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
    bool touchOptimized) {
    const auto boneUnderPointer = [&] {
        return ToolUtilities::hitTestBone(input.screenPosition, input.viewSize, scene.skeleton, scene.selectedBoneID,
                                          camera, touchOptimized);
    };
    // IK builder intercept: while a slot is armed a click on a bone fills
    // it, with any tool. A click on nothing is swallowed too, or it would
    // clear the selection under a panel still being worked in.
    if (scene.ikBuilder.has_value() && scene.ikBuilder->pickingSlot.has_value()) {
        if (const auto boneID = boneUnderPointer()) scene.ikBuilderHandleBonePick(*boneID);
        return;
    }
    // Bind Mode intercept: a click binds or unbinds a bone on the selected
    // mesh and never changes the selection.
    if (scene.isBindingBonesMode && scene.selectedImageID.has_value()) {
        const Uuid imageID = *scene.selectedImageID;
        const SceneImage* image = scene.image(imageID);
        const AssetAlpha* asset = (image != nullptr && assets_ != nullptr) ? assets_->find(image->assetID) : nullptr;
        if (asset != nullptr) {
            if (const auto boneID = boneUnderPointer()) {
                const std::vector<Uuid> bound = scene.boundBoneIDs(imageID);
                if (std::find(bound.begin(), bound.end(), *boneID) != bound.end()) {
                    scene.unbindBoneFromImage(imageID, *boneID, scene.meshWeightMaxInfluencesPerVertex);
                    if (scene.activeWeightPaintBoneID == boneID) scene.activeWeightPaintBoneID = std::nullopt;
                } else {
                    scene.bindBoneToImage(imageID, *boneID, asset->size, scene.meshWeightMaxInfluencesPerVertex);
                }
            }
            return;
        }
    }

    const SceneImage* selectedImageForGizmo =
        scene.selectedImageID.has_value() ? scene.image(*scene.selectedImageID) : nullptr;
    const std::optional<Skeleton::LineSegment> selectedBoneSegment =
        scene.selectedBoneID.has_value() ? scene.skeleton.lineSegment(*scene.selectedBoneID) : std::nullopt;
    hoveredHandle = ToolUtilities::hitTestGizmo(
        currentTool, input.screenPosition, input.viewSize, selectedImageForGizmo, selectedAssetSize(scene),
        selectedBoneSegment, scene.selectedBoneID, &scene.skeleton, scene.isMeshOverlayDeformed(),
        scene.meshWeightPaintEnabled, camera, hitScale, touchOptimized);
    activeHandle = hoveredHandle;
    // Skew hover-arc tracking on grab: not ported (UI-only, see file header).

    const std::optional<Uuid> currentSelectionID =
        scene.selectedBoneID.has_value() ? scene.selectedBoneID : scene.selectedImageID;
    const bool hasFocusedSelection = currentSelectionID.has_value();
    const std::optional<Uuid> imageSelectedBeforeClick = scene.selectedImageID;

    // Weight paint holds its target: the brush paints the selected sprite,
    // so a click that re-selected mid-stroke moved the brush elsewhere (and
    // a tap on a bone stopped it painting anything).
    const bool holdsSelectionForPainting = currentTool == ActiveTool::Mesh && scene.isWeightPaintStroke();
    // And in Weights a bone on the canvas is a COLOUR, not a selection: the
    // click that arms it must not also take away the sprite being painted.
    // Wider than the guard above on purpose -- it protects the double click
    // that arms the FIRST bone.
    const bool bonesArmTheBrush =
        currentTool == ActiveTool::Mesh && scene.meshWeightPaintEnabled && scene.selectedImageID.has_value();

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
                    // In a sprite mode, changing sprite selects the new
                    // sprite's MESH (`setSelection` would clear the mesh
                    // layer the brush and the vertex hit test key off).
                    if (scene.isSpriteMeshMode() || (scene.isMeshLayerSelected && scene.selectedImageID.has_value() &&
                                                     *scene.selectedImageID == hitID)) {
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
    // ported.
    if (currentTool == ActiveTool::Mesh && scene.meshWeightPaintEnabled) selectionRect = std::nullopt;

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
                updateSelectionRect(input, scene);
            }
        } else if (currentTool == ActiveTool::Mesh && scene.meshEditToolMode == EditorScene::MeshEditToolMode::Modify) {
            if (scene.meshWeightPaintEnabled) {
                selectionRect = std::nullopt;
            } else {
                updateMeshSelectionRect(input, scene, hitScale);
            }
        }
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

// The sprite marquee: every sprite whose drawn silhouette the band
// touches (`hitTestRect`), front first. Without an asset store no sprite
// can be measured, and the band selects nothing.
void ToolManager::updateSelectionRect(const ToolInput& input, EditorScene& scene) {
    const auto rect = marqueeRect(input);
    if (!rect.has_value()) {
        selectionRect = std::nullopt;
        return;
    }
    selectionRect = rect;
    const std::vector<Uuid> ids =
        assets_ != nullptr ? CanvasImagePicking::hitTestRect(*rect, input.viewSize, scene, *assets_, camera)
                           : std::vector<Uuid>{};
    scene.setSelection(ids, ids.empty() ? std::nullopt : std::optional<Uuid>(ids.front()), input.isShiftPressed);
}

void ToolManager::updateMeshSelectionRect(const ToolInput& input, EditorScene& scene, float hitScale) {
    const auto rect = marqueeRect(input);
    if (!rect.has_value()) {
        selectionRect = std::nullopt;
        return;
    }
    selectionRect = rect;
    const auto projection = selectedMeshProjection(scene, input.viewSize, hitScale);
    std::unordered_set<int> hits =
        projection.has_value() ? ToolUtilities::hitTestMeshVertices(*rect, *projection) : std::unordered_set<int>{};
    if (input.isShiftPressed) hits.insert(scene.selectedMeshVertexIndices.begin(), scene.selectedMeshVertexIndices.end());
    scene.selectMeshVertices(std::move(hits));
}

void ToolManager::handleMouseMove(const ToolInput& input, EditorScene& scene, const AssetAlphaStore& assets,
                                  float hitScale, bool touchOptimized) {
    const AssetScope scope(*this, &assets);
    handleMouseMove(input, scene, CanvasImagePicking::makeImageHitTest(scene, assets, hitScale), hitScale,
                    touchOptimized);
}
void ToolManager::handleMouseDown(const ToolInput& input, EditorScene& scene, const AssetAlphaStore& assets,
                                  float hitScale, bool touchOptimized) {
    const AssetScope scope(*this, &assets);
    handleMouseDown(input, scene, CanvasImagePicking::makeImageHitTest(scene, assets, hitScale), hitScale,
                    touchOptimized);
}
void ToolManager::handleMouseDrag(const ToolInput& input, EditorScene& scene, const AssetAlphaStore& assets,
                                  float hitScale, bool touchOptimized) {
    const AssetScope scope(*this, &assets);
    handleMouseDrag(input, scene, CanvasImagePicking::makeImageHitTest(scene, assets, hitScale), hitScale,
                    touchOptimized);
}
void ToolManager::handleMouseUp(const ToolInput& input, EditorScene& scene, const AssetAlphaStore& assets,
                                float hitScale, bool touchOptimized) {
    const AssetScope scope(*this, &assets);
    handleMouseUp(input, scene, CanvasImagePicking::makeImageHitTest(scene, assets, hitScale), hitScale,
                  touchOptimized);
}

} // namespace umeshcore
