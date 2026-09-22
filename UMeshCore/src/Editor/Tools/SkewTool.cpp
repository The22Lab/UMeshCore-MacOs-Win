#include "umeshcore/Editor/Tools/SkewTool.h"

#include <algorithm>
#include <cmath>
#include <variant>

#include "umeshcore/Math/MatrixUtilities.h"

namespace umeshcore {

bool SkewTool::ensureDragStarted(const Vec2& currentPosition) {
    if (didDrag_) return true;
    if (!mouseDownPosition_.has_value()) return false;
    if (length(currentPosition - *mouseDownPosition_) >= kDragThreshold) {
        didDrag_ = true;
        return true;
    }
    return false;
}

std::optional<ShearAxis> SkewTool::axisFor(const GizmoHandle& handle) {
    const auto* edge = std::get_if<SkewEdgeHandle>(&handle);
    if (edge == nullptr) return std::nullopt;
    if (edge->index == 0) return ShearAxis::ShearX;
    if (edge->index == 1) return ShearAxis::ShearY;
    return ShearAxis::ShearZ;
}

namespace {
float normalizedDegrees(float d) {
    while (d > 180.0f) d -= 360.0f;
    while (d < -180.0f) d += 360.0f;
    return d;
}

Vec2 appliedSkew(ShearAxis axis, const Vec2& startSkew, float d) {
    Vec2 next = startSkew;
    switch (axis) {
        case ShearAxis::ShearX:
            next.x = std::clamp(startSkew.x + d, -180.0f, 180.0f);
            break;
        case ShearAxis::ShearY:
            next.y = std::clamp(startSkew.y + d, -180.0f, 180.0f);
            break;
        case ShearAxis::ShearZ:
            next.x = std::clamp(startSkew.x + d, -180.0f, 180.0f);
            next.y = std::clamp(startSkew.y - d, -180.0f, 180.0f);
            break;
    }
    return next;
}
} // namespace

void SkewTool::onMouseDown(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float /*hitScale*/,
    bool /*touchOptimized*/) {
    if (!input.activeHandle.has_value()) return;
    const auto axis = axisFor(*input.activeHandle);
    if (!axis.has_value()) return;

    scene.beginInteraction();
    mouseDownPosition_ = input.position;
    didDrag_ = false;

    if (scene.selectedBoneID.has_value()) {
        const auto segment = scene.skeleton.lineSegment(*scene.selectedBoneID);
        if (segment.has_value()) {
            activeBoneID_ = scene.selectedBoneID;
            const Bone* bone = scene.skeleton.bone(*scene.selectedBoneID);
            startSkew_ = bone != nullptr ? bone->localTransform.skew : Vec2::zero();
            activeAxis_ = axis;
            boneCenter_ = (segment->start + segment->end) * 0.5f;
            startAngle_ = std::atan2(input.position.y - boneCenter_.y, input.position.x - boneCenter_.x);
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
    if (image == nullptr || input.camera == nullptr) return;

    scene.selectedImageID = *hit;
    activeID_ = *hit;
    startSkew_ = image->skew;
    activeAxis_ = axis;
    const Vec2 centerScreen = input.camera->worldToScreen(image->position, input.viewSize);
    startAngle_ =
        std::atan2(input.screenPosition.y - centerScreen.y, input.screenPosition.x - centerScreen.x);
}

void SkewTool::onMouseDrag(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& /*imageHitTest*/, float /*hitScale*/,
    bool /*touchOptimized*/) {
    if (!ensureDragStarted(input.position)) return;

    if (activeBoneID_.has_value() && activeAxis_.has_value()) {
        const float currentAngle =
            std::atan2(input.position.y - boneCenter_.y, input.position.x - boneCenter_.x);
        float d = normalizedDegrees((startAngle_ - currentAngle) * 180.0f / kPi);
        if (input.isShiftPressed) d = std::round(d);
        scene.setBoneSkew(*activeBoneID_, appliedSkew(*activeAxis_, startSkew_, d));
        return;
    }

    if (!activeID_.has_value() || !activeAxis_.has_value() || input.camera == nullptr) return;
    SceneImage* image = scene.image(*activeID_);
    if (image == nullptr) return;

    const Vec2 centerScreen = input.camera->worldToScreen(image->position, input.viewSize);
    const float currentAngle =
        std::atan2(input.screenPosition.y - centerScreen.y, input.screenPosition.x - centerScreen.x);
    float d = normalizedDegrees((startAngle_ - currentAngle) * 180.0f / kPi);
    if (input.isShiftPressed) d = std::round(d);
    scene.setImageSkew(*activeID_, appliedSkew(*activeAxis_, startSkew_, d));
}

void SkewTool::onMouseUp(
    const ToolInput& /*input*/, EditorScene& scene, const ImageHitTestFn& /*imageHitTest*/, float /*hitScale*/,
    bool /*touchOptimized*/) {
    scene.endInteraction();

    const std::optional<Uuid> boneID = activeBoneID_;
    const std::optional<Uuid> imageID = activeID_;
    const bool didDrag = didDrag_;

    activeBoneID_ = std::nullopt;
    activeID_ = std::nullopt;
    activeAxis_ = std::nullopt;
    mouseDownPosition_ = std::nullopt;
    didDrag_ = false;

    if (!didDrag) return;

    if (boneID.has_value()) {
        const Bone* bone = scene.skeleton.bone(*boneID);
        if (bone != nullptr) {
            scene.commitKeyframe(*boneID, AnimationTrackProperty::Shear, ShearValue{bone->localTransform.skew});
        }
        return;
    }
    if (imageID.has_value()) {
        const SceneImage* image = scene.image(*imageID);
        if (image != nullptr) {
            scene.commitKeyframe(*imageID, AnimationTrackProperty::Shear, ShearValue{image->skew});
        }
    }
}

} // namespace umeshcore
