#pragma once

// 1:1 port of `Core/Tools/PhysicsPreviewTool.swift` (59 L) -- drag a bone
// while the physics simulation runs, for immediate secondary-motion
// feedback.
//
// ## The pose override has no consumer, in Swift either
//
// The Swift file's own header says a drag "temporarily overrides its world
// position via a pose override stored in SceneManager, which
// `baseWorldMatrices()` reads to feed correct 'rest' targets into the
// physics solver". That second half is not true of the code as it stands.
// Verified by grep over the entire Swift source rather than by reading:
// `physicsPreviewOverrides` has exactly three mentions -- its declaration
// and the two `SceneManager` methods that write it -- and
// `baseWorldMatrices()` never consults it. `PhysicsConstraintSystem` calls
// `baseWorldMatrices()` twice and gets the undisturbed skeleton both
// times.
//
// So dragging a bone with this tool selected stores a position and changes
// nothing. The tool itself is LIVE -- `ToolManager` constructs it, the
// "y" key selects it, and the constraints menu toggles it -- so this is an
// unfinished feature rather than dead code, which is why it is ported
// (unlike `ArcGeometryBuilder` and the rotation-hover methods, which had
// zero call sites and were not).
//
// This also corrects the port's earlier diagnosis. `CLAUDE.md` recorded
// this tool as blocked on `EditorScene` owning a live
// `PhysicsConstraintSystem`; it is not. A live system would read
// `baseWorldMatrices()` like the Swift one does and still never see an
// override. What the feature actually needs is the missing READ -- a
// decision about how a dragged bone should enter the solver's rest pose --
// and that is a design question for whoever finishes it, not a
// transcription gap. Ported as it is, documented as it is.
//
// The hit-test is real geometry and is ported exactly: both ENDS of every
// bone are candidates, within a fixed 14-point screen radius, nearest
// wins. Note what that means and is worth preserving rather than
// "improving": the segment between the joints is not hittable at all, and
// a bone's tip is as grabbable as its root -- unlike `BoneTool`, whose
// own hit-test gives a joint priority over a numerically closer segment.
// Two tools, two deliberate rules.
//
// The radius is NOT scaled by `hitScale` here, matching Swift, where it is
// a plain `let jointR: Float = 14` rather than one of the
// `#if os(iOS)`-selected constants `BoneTool` uses. A touch build
// therefore gets the same 14 points this tool has always used.

#include <optional>

#include "umeshcore/Editor/Tool.h"

namespace umeshcore {

class PhysicsPreviewTool final : public Tool {
public:
    ActiveTool type() const override { return ActiveTool::PhysicsPreview; }

    void onMouseDown(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest,
        float hitScale, bool touchOptimized) override;
    void onMouseDrag(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest,
        float hitScale, bool touchOptimized) override;
    void onMouseUp(
        const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest,
        float hitScale, bool touchOptimized) override;

    // The bone currently being dragged, if any. Exposed for tests and for
    // a shell that wants to draw the drag; Swift keeps it private, but
    // nothing there reads it either.
    const std::optional<Uuid>& draggingBoneID() const { return draggingBoneID_; }

    // Screen radius, in points, within which a bone END counts as hit.
    static constexpr float kJointRadius = 14.0f;

private:
    std::optional<Uuid> draggingBoneID_;
};

} // namespace umeshcore
