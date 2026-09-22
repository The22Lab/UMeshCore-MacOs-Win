#include "umeshcore/Editor/Tools/PhysicsPreviewTool.h"

#include <cmath>

namespace umeshcore {

void PhysicsPreviewTool::onMouseDown(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
    bool touchOptimized) {
    (void)imageHitTest;
    (void)hitScale;
    (void)touchOptimized;

    const std::vector<Skeleton::WorldLineSegment> segments = scene.skeleton.worldLineSegments();
    if (segments.empty()) return;

    // Both ENDS of every bone, nearest wins. The segment between them is
    // not hittable -- see the header; that is this tool's rule, not
    // `BoneTool`'s.
    std::optional<Uuid> closest;
    float closestDistance = 0.0f;
    for (const Skeleton::WorldLineSegment& segment : segments) {
        // Swift falls back to the WORLD point when there is no camera,
        // which only ever makes sense for an identity camera; reproduced
        // rather than guarded, because a caller with no camera has no
        // screen space to measure 14 points in either way.
        const Vec2 startScreen = input.camera != nullptr
                                     ? input.camera->worldToScreen(segment.start, input.viewSize)
                                     : segment.start;
        const Vec2 endScreen = input.camera != nullptr
                                   ? input.camera->worldToScreen(segment.end, input.viewSize)
                                   : segment.end;
        const float toStart = length(input.screenPosition - startScreen);
        const float toEnd = length(input.screenPosition - endScreen);
        const float best = std::min(toStart, toEnd);
        if (best <= kJointRadius && (!closest.has_value() || best < closestDistance)) {
            closest = segment.bone.id;
            closestDistance = best;
        }
    }

    if (!closest.has_value()) {
        // Cleared, so a miss cannot leave the previous drag running.
        draggingBoneID_.reset();
        return;
    }
    draggingBoneID_ = closest;
    scene.physicsPreviewOverrides[*closest] = input.position;
}

void PhysicsPreviewTool::onMouseDrag(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
    bool touchOptimized) {
    (void)imageHitTest;
    (void)hitScale;
    (void)touchOptimized;
    if (!draggingBoneID_.has_value()) return;
    scene.physicsPreviewOverrides[*draggingBoneID_] = input.position;
}

void PhysicsPreviewTool::onMouseUp(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
    bool touchOptimized) {
    (void)input;
    (void)imageHitTest;
    (void)hitScale;
    (void)touchOptimized;
    // On mouse-up the override is cleared and the simulation continues
    // from the disturbed state -- which today means it continues exactly
    // as it would have, since nothing read the override. See the header.
    if (draggingBoneID_.has_value()) scene.physicsPreviewOverrides.erase(*draggingBoneID_);
    draggingBoneID_.reset();
}

} // namespace umeshcore
