#include "umeshcore/Editor/Tools/MoveTool.h"

#include <variant>

namespace umeshcore {

bool MoveTool::ensureDragStarted(const Vec2& currentPosition) {
    if (didDrag_) return true;
    if (!mouseDownPosition_.has_value()) return false;
    if (length(currentPosition - *mouseDownPosition_) >= kDragThreshold) {
        didDrag_ = true;
        return true;
    }
    return false;
}

Vec2 MoveTool::computeDragPosition(const ToolInput& input, const Vec2& startPosition) const {
    const bool constrainX =
        input.activeHandle.has_value() && std::holds_alternative<MoveXHandle>(*input.activeHandle);
    const bool constrainY =
        input.activeHandle.has_value() && std::holds_alternative<MoveYHandle>(*input.activeHandle);

    if (input.camera != nullptr) {
        const Vec2 startScreen = input.camera->worldToScreen(startPosition, input.viewSize);
        Vec2 targetScreen = input.screenPosition - grabOffsetScreen_;
        if (constrainX) {
            targetScreen.y = startScreen.y;
        } else if (constrainY) {
            targetScreen.x = startScreen.x;
        }
        return input.camera->screenToWorld(targetScreen, input.viewSize);
    }

    Vec2 rawTarget = input.position;
    if (constrainX) {
        rawTarget.y = startPosition.y;
    } else if (constrainY) {
        rawTarget.x = startPosition.x;
    }
    return rawTarget;
}

void MoveTool::onMouseDown(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float /*hitScale*/,
    bool /*touchOptimized*/) {
    scene.beginInteraction();
    mouseDownPosition_ = input.position;
    didDrag_ = false;

    // Mesh-vertex-drag branch not ported -- see this file's header comment.

    if (scene.selectedBoneID.has_value()) {
        const auto segment = scene.skeleton.lineSegment(*scene.selectedBoneID);
        if (segment.has_value()) {
            activeBoneID_ = scene.selectedBoneID;
            startPosition_ = segment->start;
            dragPosition_ = segment->start;
            if (input.camera != nullptr) {
                const Vec2 boneScreen = input.camera->worldToScreen(segment->start, input.viewSize);
                grabOffsetScreen_ = input.screenPosition - boneScreen;
            } else {
                grabOffsetScreen_ = Vec2::zero();
            }
            boneDragOrder_ = scene.selectedBonesInDepthOrder();
            boneStartPositions_.clear();
            for (Uuid id : boneDragOrder_) {
                const auto boneSegment = scene.skeleton.lineSegment(id);
                if (boneSegment.has_value()) boneStartPositions_[id] = boneSegment->start;
            }
            return;
        }
    }

    const std::optional<ImageHit> imageHit =
        imageHitTest ? imageHitTest(input.screenPosition, input.viewSize, input.camera) : std::nullopt;
    const std::optional<Uuid> hit = imageHit.has_value() ? std::optional<Uuid>(imageHit->id) : scene.selectedImageID;
    if (!hit.has_value()) return;
    SceneImage* image = scene.image(*hit);
    if (image == nullptr) return;

    if (scene.isMeshLayerSelected && scene.selectedImageID.has_value() && *scene.selectedImageID == *hit) {
        scene.selectMeshLayer(*hit);
    } else {
        scene.setSelection({*hit}, *hit, input.isShiftPressed);
    }
    activeID_ = *hit;
    startPosition_ = image->position;
    dragPosition_ = image->position;
    if (input.camera != nullptr) {
        const Vec2 imageScreen = input.camera->worldToScreen(image->position, input.viewSize);
        grabOffsetScreen_ = input.screenPosition - imageScreen;
    } else {
        grabOffsetScreen_ = Vec2::zero();
    }
}

void MoveTool::onMouseDrag(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& /*imageHitTest*/, float /*hitScale*/,
    bool /*touchOptimized*/) {
    if (!ensureDragStarted(input.position)) return;

    if (activeBoneID_.has_value()) {
        dragPosition_ = computeDragPosition(input, startPosition_);
        const Vec2 targetPosition =
            input.isShiftPressed ? ToolUtilities::snap(dragPosition_, kGridSize) : dragPosition_;
        const Vec2 appliedDelta = targetPosition - startPosition_;
        if (boneDragOrder_.empty()) {
            scene.moveBoneRoot(*activeBoneID_, targetPosition);
            return;
        }
        for (Uuid id : boneDragOrder_) {
            auto it = boneStartPositions_.find(id);
            if (it == boneStartPositions_.end()) continue;
            scene.moveBoneRoot(id, it->second + appliedDelta);
        }
        return;
    }

    if (!activeID_.has_value()) return;
    // Mesh-vertex-drag branch not ported -- see this file's header comment.

    dragPosition_ = computeDragPosition(input, startPosition_);
    const Vec2 targetPosition = input.isShiftPressed ? ToolUtilities::snap(dragPosition_, kGridSize) : dragPosition_;
    scene.setPreviewPosition(*activeID_, targetPosition);
}

void MoveTool::onMouseUp(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& /*imageHitTest*/, float /*hitScale*/,
    bool /*touchOptimized*/) {
    scene.endInteraction();

    // Captured before the reset below, matching the Swift source's `defer`
    // (which clears these same fields once the function body -- reading
    // them throughout -- has finished).
    const std::optional<Uuid> boneID = activeBoneID_;
    const std::optional<Uuid> imageID = activeID_;
    const std::vector<Uuid> boneDragOrder = boneDragOrder_;
    const std::unordered_map<Uuid, Vec2, UuidHash> boneStartPositions = boneStartPositions_;
    const Vec2 dragPosition = dragPosition_;
    const Vec2 startPosition = startPosition_;
    const bool didDrag = didDrag_;

    activeID_ = std::nullopt;
    activeBoneID_ = std::nullopt;
    boneDragOrder_.clear();
    boneStartPositions_.clear();
    dragPosition_ = Vec2::zero();
    grabOffsetScreen_ = Vec2::zero();
    mouseDownPosition_ = std::nullopt;
    didDrag_ = false;

    if (boneID.has_value()) {
        if (!didDrag) return;
        const Vec2 target = input.isShiftPressed ? ToolUtilities::snap(dragPosition, kGridSize) : dragPosition;
        const Vec2 appliedDelta = target - startPosition;
        const std::vector<Uuid> moved = boneDragOrder.empty() ? std::vector<Uuid>{*boneID} : boneDragOrder;
        for (Uuid id : moved) {
            auto it = boneStartPositions.find(id);
            const Vec2 start = it != boneStartPositions.end() ? it->second : startPosition;
            scene.moveBoneRoot(id, start + appliedDelta);
            scene.commitKeyframe(id, AnimationTrackProperty::Translate);
        }
        return;
    }

    if (!imageID.has_value()) return;
    // Mesh-vertex-drag branch not ported -- see this file's header comment.

    if (!didDrag || scene.image(*imageID) == nullptr) {
        scene.clearPreviewPosition(*imageID);
        return;
    }
    const Vec2 target = input.isShiftPressed ? ToolUtilities::snap(dragPosition, kGridSize) : dragPosition;
    scene.clearPreviewPosition(*imageID);
    scene.setImagePosition(*imageID, target);
    scene.commitKeyframe(*imageID, AnimationTrackProperty::Translate);
}

} // namespace umeshcore
