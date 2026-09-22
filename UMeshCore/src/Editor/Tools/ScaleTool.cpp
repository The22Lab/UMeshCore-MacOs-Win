#include "umeshcore/Editor/Tools/ScaleTool.h"

#include <algorithm>
#include <cmath>
#include <variant>

namespace umeshcore {

bool ScaleTool::ensureDragStarted(const Vec2& currentPosition) {
    if (didDrag_) return true;
    if (!mouseDownPosition_.has_value()) return false;
    if (length(currentPosition - *mouseDownPosition_) >= kDragThreshold) {
        didDrag_ = true;
        return true;
    }
    return false;
}

void ScaleTool::onMouseDown(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float /*hitScale*/,
    bool /*touchOptimized*/) {
    if (!input.activeHandle.has_value() || !std::holds_alternative<ScaleCornerHandle>(*input.activeHandle)) return;
    scene.beginInteraction();
    mouseDownPosition_ = input.position;
    didDrag_ = false;

    if (scene.selectedBoneID.has_value()) {
        const auto segment = scene.skeleton.lineSegment(*scene.selectedBoneID);
        if (segment.has_value()) {
            activeBoneID_ = scene.selectedBoneID;
            activeHandle_ = input.activeHandle;
            boneStart_ = segment->start;
            startBoneLength_ = std::max(length(segment->end - segment->start), 12.0f);
            const Bone* bone = scene.skeleton.bone(*scene.selectedBoneID);
            startBoneScale_ = bone != nullptr ? Vec2(bone->localTransform.scale.x, bone->localTransform.scale.y)
                                               : Vec2::one();
            startVector_ = input.startPosition - segment->start;
            startDistance_ = std::max(1.0f, length(startVector_));
            boneDragOrder_ = scene.selectedBonesInDepthOrder();
            boneStartScales_.clear();
            boneStartLengths_.clear();
            for (Uuid id : boneDragOrder_) {
                const Bone* b = scene.skeleton.bone(id);
                if (b == nullptr) continue;
                boneStartScales_[id] = Vec2(b->localTransform.scale.x, b->localTransform.scale.y);
                boneStartLengths_[id] = b->length;
            }
            return;
        }
    }

    const std::optional<ImageHit> imageHit =
        imageHitTest ? imageHitTest(input.screenPosition, input.viewSize, input.camera) : std::nullopt;
    const std::optional<Uuid> hit =
        scene.selectedImageID.has_value() ? scene.selectedImageID
        : (imageHit.has_value() ? std::optional<Uuid>(imageHit->id) : std::nullopt);
    if (!hit.has_value()) return;
    SceneImage* image = scene.image(*hit);
    if (image == nullptr) return;

    scene.selectedImageID = *hit;
    activeID_ = *hit;
    activeHandle_ = input.activeHandle;
    startScale_ = image->scale;
    settleTarget_ = std::nullopt;
    settleID_ = std::nullopt;
    startVector_ = Vec2(input.startPosition.x - image->position.x, input.startPosition.y - image->position.y);
    startDistance_ = std::max(1.0f, length(startVector_));
}

void ScaleTool::onMouseDrag(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& /*imageHitTest*/, float /*hitScale*/,
    bool /*touchOptimized*/) {
    if (!ensureDragStarted(input.position)) return;

    if (activeBoneID_.has_value()) {
        const Vec2 vector = input.position - boneStart_;
        const float distance = std::max(1.0f, length(vector));
        const std::vector<Uuid> scaled = boneDragOrder_.empty() ? std::vector<Uuid>{*activeBoneID_} : boneDragOrder_;

        if (scene.isAnimationEditingEnabled) {
            Vec2 scale(
                std::max(startBoneScale_.x * std::max(distance / startDistance_, 0.001f), 0.001f),
                startBoneScale_.y);
            if (input.isShiftPressed) scale = ToolUtilities::snapScale(scale, kSnapStep);
            // Read back off the ACTIVE bone after snapping, so Shift snaps
            // that bone and the group keeps its proportions instead of each
            // bone landing on its own step.
            const float appliedFactor = scale.x / std::max(startBoneScale_.x, 0.001f);
            for (Uuid id : scaled) {
                auto it = boneStartScales_.find(id);
                const Vec2 start = it != boneStartScales_.end() ? it->second : startBoneScale_;
                scene.setBoneScale(id, Vec2(std::max(start.x * appliedFactor, 0.001f), start.y));
            }
        } else {
            float len = startBoneLength_ * (distance / startDistance_);
            if (input.isShiftPressed) len = ToolUtilities::snapScale(len, kSnapStep);
            const float appliedFactor = len / std::max(startBoneLength_, 0.001f);
            for (Uuid id : scaled) {
                auto it = boneStartLengths_.find(id);
                const float start = it != boneStartLengths_.end() ? it->second : startBoneLength_;
                scene.setBoneLength(id, start * appliedFactor);
            }
        }
        return;
    }

    if (!activeID_.has_value() || !activeHandle_.has_value()) return;
    SceneImage* image = scene.image(*activeID_);
    if (image == nullptr) return;

    const Vec2 vector(input.position.x - image->position.x, input.position.y - image->position.y);
    Vec2 scale = startScale_;
    const auto* corner = std::get_if<ScaleCornerHandle>(&*activeHandle_);
    const int cornerIndex = corner != nullptr ? corner->index : -1;
    if (cornerIndex == 0) {
        const float factor = std::max(0.05f, std::abs(vector.x) / std::max(1.0f, std::abs(startVector_.x)));
        scale.x = std::max(0.05f, startScale_.x * factor);
    } else if (cornerIndex == 1) {
        const float factor = std::max(0.05f, std::abs(vector.y) / std::max(1.0f, std::abs(startVector_.y)));
        scale.y = std::max(0.05f, startScale_.y * factor);
    } else {
        const float distance = std::max(1.0f, length(vector));
        const float factor = distance / startDistance_;
        scale = Vec2(std::max(0.05f, startScale_.x * factor), std::max(0.05f, startScale_.y * factor));
    }
    if (input.isShiftPressed) scale = ToolUtilities::snapScale(scale, kSnapStep);
    scene.setImageScale(*activeID_, scale);
}

void ScaleTool::onMouseUp(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& /*imageHitTest*/, float /*hitScale*/,
    bool /*touchOptimized*/) {
    scene.endInteraction();

    const std::optional<Uuid> boneID = activeBoneID_;
    const std::optional<Uuid> imageID = activeID_;
    const std::vector<Uuid> boneDragOrder = boneDragOrder_;
    const bool didDrag = didDrag_;

    activeBoneID_ = std::nullopt;
    boneDragOrder_.clear();
    boneStartScales_.clear();
    boneStartLengths_.clear();
    activeID_ = std::nullopt;
    activeHandle_ = std::nullopt;
    mouseDownPosition_ = std::nullopt;
    didDrag_ = false;

    if (!didDrag) return;

    if (boneID.has_value()) {
        if (scene.isAnimationEditingEnabled) {
            const std::vector<Uuid> ids = boneDragOrder.empty() ? std::vector<Uuid>{*boneID} : boneDragOrder;
            for (Uuid id : ids) {
                const Bone* bone = scene.skeleton.bone(id);
                if (bone == nullptr) continue;
                const Vec2 scale(bone->localTransform.scale.x, bone->localTransform.scale.y);
                scene.commitKeyframe(id, AnimationTrackProperty::Scale, ScaleValue{scale});
            }
        }
        return;
    }

    if (!imageID.has_value()) return;
    SceneImage* image = scene.image(*imageID);
    if (image == nullptr) return;
    const Vec2 raw = image->scale;
    const Vec2 target = input.isShiftPressed ? ToolUtilities::snapScale(raw, kSnapStep) : raw;
    settleTarget_ = target;
    settleID_ = imageID;
    scene.commitKeyframe(*imageID, AnimationTrackProperty::Scale, ScaleValue{target});
}

void ScaleTool::update(EditorScene& scene) {
    if (!settleID_.has_value() || !settleTarget_.has_value()) return;
    SceneImage* image = scene.image(*settleID_);
    if (image == nullptr) return;
    const Vec2 current = image->scale;
    const Vec2 next = current + (*settleTarget_ - current) * kSettleFactor;
    scene.setImageScale(*settleID_, next);
    if (length(next - *settleTarget_) < 0.001f) {
        scene.setImageScale(*settleID_, *settleTarget_);
        settleTarget_ = std::nullopt;
        settleID_ = std::nullopt;
    }
}

} // namespace umeshcore
