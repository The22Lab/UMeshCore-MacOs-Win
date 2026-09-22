#include "umeshcore/Editor/Tools/BoneTool.h"

#include <limits>

namespace umeshcore {

BoneTool::Radii BoneTool::radiiFor(bool touchOptimized) {
    // iOS: larger targets for comfortable finger + Pencil use. Drawable
    // pixels; at 2x display scale: joint ~26pt, segment ~16pt.
    if (touchOptimized) return Radii{52.0f, 32.0f, 8.0f};
    return Radii{12.0f, 9.0f, 4.0f};
}

bool BoneTool::ensureDragStarted(const Vec2& currentPosition, float clickDragThreshold) {
    if (moveThresholdExceeded_) return true;
    if (!mouseDownPosition_.has_value()) return false;
    if (length(currentPosition - *mouseDownPosition_) >= clickDragThreshold) {
        moveThresholdExceeded_ = true;
        return true;
    }
    return false;
}

std::optional<BoneTool::Interaction> BoneTool::interactionForHit(const BoneHit& hit, const ToolInput& input) {
    if (hit.part == BoneHitPart::Start || hit.part == BoneHitPart::Segment) {
        Interaction i;
        i.kind = InteractionKind::MoveRoot;
        i.boneID = hit.id;
        return i;
    }
    // A tip means "carry on from here": a plain drag chains a new child
    // bone; Shift resizes the existing one instead. NOTE: as of the
    // current onMouseDown (which returns early on
    // isShiftPressed/isCommandPressed before ever reaching this function --
    // see BoneTool.h's file header), `isShiftPressed` is always false by
    // the time this runs, so this branch is presently unreachable. Ported
    // as-is rather than removed, since the intent is clear and removing it
    // would silently diverge further from the Swift source if that call
    // site's ordering is ever fixed upstream.
    if (input.isShiftPressed) {
        Interaction i;
        i.kind = InteractionKind::MoveTip;
        i.boneID = hit.id;
        return i;
    }
    Interaction i;
    i.kind = InteractionKind::Create;
    i.parentID = hit.id;
    i.start = input.position;
    return i;
}

std::optional<BoneHit> BoneTool::hitTestBonePart(
    const Vec2& screenPoint, const Vec2& viewSize, const Skeleton& skeleton, CameraState* camera,
    float jointRadius, float lineRadius) {
    const auto segments = skeleton.worldLineSegments();
    if (segments.empty()) return std::nullopt;

    // Joints and segments are tracked separately so joints always win when
    // both overlap -- a segment at 8px never beats a joint at 12px.
    std::optional<BoneHit> bestJointHit;
    float bestJointDist = std::numeric_limits<float>::max();
    std::optional<BoneHit> bestSegHit;
    float bestSegDist = std::numeric_limits<float>::max();

    for (const auto& seg : segments) {
        const Vec2 startScreen =
            camera != nullptr ? camera->worldToScreen(seg.start, viewSize) : seg.start + viewSize * 0.5f;
        const Vec2 endScreen =
            camera != nullptr ? camera->worldToScreen(seg.end, viewSize) : seg.end + viewSize * 0.5f;

        const float startDist = length(screenPoint - startScreen);
        if (startDist <= jointRadius && startDist < bestJointDist) {
            bestJointDist = startDist;
            bestJointHit = BoneHit{seg.bone.id, BoneHitPart::Start};
        }
        const float endDist = length(screenPoint - endScreen);
        if (endDist <= jointRadius && endDist < bestJointDist) {
            bestJointDist = endDist;
            bestJointHit = BoneHit{seg.bone.id, BoneHitPart::End};
        }
        const float lineDist = ToolUtilities::distancePointToSegment(screenPoint, startScreen, endScreen);
        if (lineDist <= lineRadius && lineDist < bestSegDist) {
            bestSegDist = lineDist;
            bestSegHit = BoneHit{seg.bone.id, BoneHitPart::Segment};
        }
    }

    // Joints take absolute priority -- a joint hit always beats a segment hit.
    return bestJointHit.has_value() ? bestJointHit : bestSegHit;
}

void BoneTool::onMouseDown(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& /*imageHitTest*/, float /*hitScale*/,
    bool touchOptimized) {
    scene.beginInteraction();
    const Radii radii = radiiFor(touchOptimized);
    const auto hit =
        hitTestBonePart(input.screenPosition, input.viewSize, scene.skeleton, input.camera, radii.jointRadius,
                        radii.lineRadius);

    if (hit.has_value()) {
        if (input.isCommandPressed || input.isShiftPressed) {
            // Cmd-click toggles the bone in the multi-selection without
            // starting a drag -- matches macOS finder/list conventions.
            scene.toggleBoneSelection(hit->id);
            interaction_ = std::nullopt;
            currentPreview_ = std::nullopt;
            scene.setBoneCreationPreview(std::nullopt, std::nullopt);
            return;
        }
        scene.selectBone(hit->id);
        currentPreview_ = std::nullopt;
        interaction_ = interactionForHit(*hit, input);
        mouseDownPosition_ = input.position;
        moveThresholdExceeded_ = false;
        if (interaction_.has_value() && interaction_->kind == InteractionKind::Create) {
            currentPreview_ = input.position;
            scene.setBoneCreationPreview(interaction_->start, input.position);
        } else {
            scene.setBoneCreationPreview(std::nullopt, std::nullopt);
        }
        return;
    }

    const std::optional<Uuid> chainParentID = scene.selectedBoneID;
    Interaction create;
    create.kind = InteractionKind::Create;
    create.parentID = chainParentID;
    create.start = input.position;
    interaction_ = create;
    currentPreview_ = input.position;
    mouseDownPosition_ = input.position;
    moveThresholdExceeded_ = true; // create mode always tracks drag from frame 0.
    scene.setBoneCreationPreview(input.position, input.position);
}

void BoneTool::onMouseDrag(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& /*imageHitTest*/, float /*hitScale*/,
    bool touchOptimized) {
    if (!interaction_.has_value()) return;
    const Radii radii = radiiFor(touchOptimized);

    switch (interaction_->kind) {
        case InteractionKind::Create:
            currentPreview_ = input.position;
            scene.setBoneCreationPreview(interaction_->start, input.position);
            break;
        case InteractionKind::MoveRoot:
            if (!ensureDragStarted(input.position, radii.clickDragThreshold)) return;
            scene.moveBoneRoot(interaction_->boneID, input.position);
            break;
        case InteractionKind::MoveTip:
            if (!ensureDragStarted(input.position, radii.clickDragThreshold)) return;
            scene.moveBoneTip(interaction_->boneID, input.position);
            break;
    }
}

void BoneTool::onMouseUp(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& /*imageHitTest*/, float /*hitScale*/,
    bool /*touchOptimized*/) {
    scene.endInteraction();

    const std::optional<Interaction> interaction = interaction_;
    const std::optional<Vec2> currentPreview = currentPreview_;

    interaction_ = std::nullopt;
    currentPreview_ = std::nullopt;
    mouseDownPosition_ = std::nullopt;
    moveThresholdExceeded_ = false;
    scene.setBoneCreationPreview(std::nullopt, std::nullopt);

    if (!interaction.has_value() || interaction->kind != InteractionKind::Create) return;
    const Vec2 end = currentPreview.has_value() ? *currentPreview : input.position;

    // A CLICK ON EMPTY CANVAS: a press and release that never travelled far
    // enough to be a bone. The same 8-unit threshold decides both "too
    // short to be a bone" and "a click that cancels" -- breaking the chain
    // (clearing selection) rather than leaving the next drag to chain off
    // whatever was selected before it.
    if (length(end - interaction->start) < 8.0f) {
        scene.selectBone(std::nullopt);
        return;
    }
    scene.addBone(interaction->start, end, interaction->parentID);
}

} // namespace umeshcore
