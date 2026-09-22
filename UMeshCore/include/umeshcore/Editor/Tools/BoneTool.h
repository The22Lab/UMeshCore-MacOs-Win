#pragma once

// 1:1 port of `Core/Tools/BoneTool.swift`: posing existing bones (drag the
// root, or Shift-drag the tip to resize) and authoring new ones (drag from
// empty canvas for a new root, or plain-drag from an existing tip to chain
// a new child bone from it).
//
// VERIFIED DISCREPANCY (not "fixed" -- ported as-is, per this port's
// standing rule to preserve the Swift source's actual behavior rather than
// its evident intent): `interactionForHit`'s `.end` case has a Shift-
// pressed branch returning `.moveTip` ("Shift resizes the tip"), with a
// comment explaining that design choice at length. But `onMouseDown` only
// ever calls `interactionForHit` after already checking
// `input.isCommandPressed || input.isShiftPressed` and returning early
// (toggling multi-selection instead) when either is true -- so by the time
// `interactionForHit` runs, `isShiftPressed` is always false, and its
// `.moveTip` branch is unreachable dead code in the real app today.
// Shift-clicking (or Shift-dragging) a bone's tip toggles its selection
// like any other Shift-click; it does not resize. This C++ port reproduces
// that exact reachable behavior (see `onMouseDown`'s structure in the
// .cpp), not the comment's stated intent -- flagged here for confirmation
// against the real Swift binary once Xcode access exists, the same
// standing this port already gives the `MeshKernelTests` `RingFoldsBack`/
// `RingSelfIntersecting` finding.
//
// Deliberately NOT reusing `ToolUtilities::hitTestBoneDetailed`: this tool
// has its own private hit-test with its own priority rule (a joint always
// beats a segment, even a numerically closer one) and its own radii, and it
// needs to know WHICH part of the bone was hit (start joint / end joint /
// segment) to decide root-move vs. tip-move vs. chain-from-tip -- something
// `hitTestBoneDetailed` doesn't expose. Verified against the real Swift
// source, not assumed from its name.
//
// `jointRadius`/`lineRadius`/`clickDragThreshold` are `#if os(iOS)`
// compile-time constants in Swift; `touchOptimized` selects between the two
// sets at runtime here, the same pattern `ToolUtilities.h` already uses.

#include <optional>

#include "umeshcore/Editor/Tool.h"

namespace umeshcore {

enum class BoneHitPart { Start, End, Segment };
struct BoneHit {
    Uuid id;
    BoneHitPart part;
};

class BoneTool final : public Tool {
public:
    ActiveTool type() const override { return ActiveTool::Bone; }

    void onMouseDown(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
        bool touchOptimized) override;
    void onMouseDrag(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
        bool touchOptimized) override;
    void onMouseUp(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
        bool touchOptimized) override;
    // No update() override -- BoneTool doesn't have one in Swift either.

private:
    enum class InteractionKind { Create, MoveRoot, MoveTip };
    struct Interaction {
        InteractionKind kind = InteractionKind::Create;
        // .create only:
        std::optional<Uuid> parentID;
        Vec2 start = Vec2::zero();
        // .moveRoot/.moveTip only:
        Uuid boneID;
    };

    std::optional<Interaction> interaction_;
    std::optional<Vec2> currentPreview_;
    std::optional<Vec2> mouseDownPosition_;
    bool moveThresholdExceeded_ = false;

    struct Radii {
        float jointRadius;
        float lineRadius;
        float clickDragThreshold;
    };
    static Radii radiiFor(bool touchOptimized);

    bool ensureDragStarted(const Vec2& currentPosition, float clickDragThreshold);
    static std::optional<Interaction> interactionForHit(const BoneHit& hit, const ToolInput& input);
    static std::optional<BoneHit> hitTestBonePart(
        const Vec2& screenPoint, const Vec2& viewSize, const Skeleton& skeleton, CameraState* camera,
        float jointRadius, float lineRadius);
};

} // namespace umeshcore
