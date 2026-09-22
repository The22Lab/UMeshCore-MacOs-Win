#include "umeshcore/Editor/CanvasPicking.h"

namespace umeshcore {

std::optional<SelectionTarget> target(
    const Vec2& screenPoint, const Vec2& viewSize, const Skeleton& skeleton,
    std::optional<Uuid> selectedBoneID, CameraState* camera, float hitScale, bool touchOptimized,
    const ImageHitTestFn& imageHitTest, float displayScale) {
    const auto bone = ToolUtilities::hitTestBoneDetailed(
        screenPoint, viewSize, skeleton, selectedBoneID, camera, touchOptimized, displayScale);
    const std::optional<ImageHit> image = imageHitTest ? imageHitTest(screenPoint, viewSize, camera) : std::nullopt;

    if (!bone.has_value() && !image.has_value()) return std::nullopt;
    if (bone.has_value() && !image.has_value()) return SelectionTarget::bone(bone->first);
    if (!bone.has_value() && image.has_value()) return SelectionTarget::image(image->id);

    // Both hit: a bone wins whenever it's a direct hit, or the image hit
    // wasn't direct -- the same behavior this app has always had, and what
    // a rigger expects when a bone is drawn over the art it drives.
    const float boneDirectRadius = 6.0f * hitScale;
    const bool boneIsDirect = bone->second <= boneDirectRadius;
    if (boneIsDirect || !image->isDirect) return SelectionTarget::bone(bone->first);
    // The click is on an opaque pixel and the bone is merely nearby.
    return SelectionTarget::image(image->id);
}

} // namespace umeshcore
