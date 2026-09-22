#include "umeshcore/Editor/Tools/RotateTool.h"

#include <cmath>
#include <variant>

namespace umeshcore {

bool RotateTool::ensureDragStarted(const Vec2& currentPosition) {
    if (didDrag_) return true;
    if (!mouseDownPosition_.has_value()) return false;
    if (length(currentPosition - *mouseDownPosition_) >= kDragThreshold) {
        didDrag_ = true;
        return true;
    }
    return false;
}

void RotateTool::onMouseDown(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float /*hitScale*/,
    bool /*touchOptimized*/) {
    if (!input.activeHandle.has_value() || !std::holds_alternative<RotateRingHandle>(*input.activeHandle)) return;
    scene.beginInteraction();
    mouseDownPosition_ = input.position;
    didDrag_ = false;

    if (scene.selectedBoneID.has_value()) {
        const auto segment = scene.skeleton.lineSegment(*scene.selectedBoneID);
        if (segment.has_value()) {
            activeBoneID_ = scene.selectedBoneID;
            boneStart_ = segment->start;
            boneLength_ = std::max(length(segment->end - segment->start), 12.0f);
            const Vec2 vector = input.startPosition - segment->start;
            startAngle_ = std::atan2(vector.y, vector.x);
            const auto worldRotation = scene.skeleton.worldRotation(*scene.selectedBoneID);
            startRotation_ = worldRotation.has_value() ? *worldRotation : 0.0f;
            // The whole selection turns, not only the bone the ring is drawn
            // on. Depth order because setBoneRotation converts a world angle
            // against the parent's CURRENT world rotation.
            boneDragOrder_ = scene.selectedBonesInDepthOrder();
            boneStartRotations_.clear();
            for (Uuid id : boneDragOrder_) {
                if (const auto r = scene.skeleton.worldRotation(id)) boneStartRotations_[id] = *r;
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
    startRotation_ = image->rotation;
    if (length(image->rotation3D) > 0.0001f) {
        scene.setImageRotation3D(*hit, Vec3::zero());
        image = scene.image(*hit); // setImageRotation3D may have moved the vector; re-fetch.
    }
    settleTarget_ = std::nullopt;
    settleID_ = std::nullopt;
    const Vec2 vector = input.startPosition - image->position;
    startAngle_ = std::atan2(vector.y, vector.x);
}

void RotateTool::onMouseDrag(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& /*imageHitTest*/, float /*hitScale*/,
    bool /*touchOptimized*/) {
    if (!ensureDragStarted(input.position)) return;

    if (activeBoneID_.has_value()) {
        const Vec2 vector = input.position - boneStart_;
        const float angle = std::atan2(vector.y, vector.x);
        const float delta = angle - startAngle_;
        float rotation = startRotation_ + delta;
        if (input.isShiftPressed) rotation = ToolUtilities::snapAngle(rotation, kSnapStepDegrees);
        // Taken from the ACTIVE bone after snapping, so Shift snaps that
        // bone to the grid and the rest of the selection follows rigidly.
        const float appliedDelta = rotation - startRotation_;
        if (boneDragOrder_.empty()) {
            scene.setBoneRotation(*activeBoneID_, rotation);
            return;
        }
        for (Uuid id : boneDragOrder_) {
            auto it = boneStartRotations_.find(id);
            if (it == boneStartRotations_.end()) continue;
            scene.setBoneRotation(id, it->second + appliedDelta);
        }
        return;
    }

    if (!activeID_.has_value()) return;
    SceneImage* image = scene.image(*activeID_);
    if (image == nullptr) return;
    const Vec2 vector = input.position - image->position;
    const float angle = std::atan2(vector.y, vector.x);
    const float delta = angle - startAngle_;
    float rotation = startRotation_ + delta;
    if (input.isShiftPressed) rotation = ToolUtilities::snapAngle(rotation, kSnapStepDegrees);
    scene.setImageRotation(*activeID_, rotation);
}

void RotateTool::onMouseUp(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& /*imageHitTest*/, float /*hitScale*/,
    bool /*touchOptimized*/) {
    scene.endInteraction();

    const std::optional<Uuid> boneID = activeBoneID_;
    const std::optional<Uuid> imageID = activeID_;
    const std::vector<Uuid> boneDragOrder = boneDragOrder_;
    const bool didDrag = didDrag_;

    activeBoneID_ = std::nullopt;
    boneDragOrder_.clear();
    boneStartRotations_.clear();
    activeID_ = std::nullopt;
    mouseDownPosition_ = std::nullopt;
    didDrag_ = false;

    if (!didDrag) return;

    if (boneID.has_value()) {
        // A key for each bone that moved -- committing only the active one
        // would record a pose where the rest of the selection turned on
        // screen and nowhere in the animation.
        const std::vector<Uuid> ids = boneDragOrder.empty() ? std::vector<Uuid>{*boneID} : boneDragOrder;
        for (Uuid id : ids) {
            scene.commitKeyframe(id, AnimationTrackProperty::Rotate);
        }
        return;
    }

    if (!imageID.has_value()) return;
    SceneImage* image = scene.image(*imageID);
    if (image == nullptr) return;
    const float raw = image->rotation;
    const float target = input.isShiftPressed ? ToolUtilities::snapAngle(raw, kSnapStepDegrees) : raw;
    settleTarget_ = target;
    settleID_ = imageID;
    scene.commitKeyframe(*imageID, AnimationTrackProperty::Rotate);
}

void RotateTool::update(EditorScene& scene) {
    if (!settleID_.has_value() || !settleTarget_.has_value()) return;
    SceneImage* image = scene.image(*settleID_);
    if (image == nullptr) return;
    const float current = image->rotation;
    const float next = current + (*settleTarget_ - current) * kSettleFactor;
    scene.setImageRotation(*settleID_, next);
    if (std::abs(next - *settleTarget_) < 0.001f) {
        scene.setImageRotation(*settleID_, *settleTarget_);
        settleTarget_ = std::nullopt;
        settleID_ = std::nullopt;
    }
}

} // namespace umeshcore
