#include "umeshcore/Editor/Tools/SelectTool.h"

namespace umeshcore {

void SelectTool::onMouseDown(
    const ToolInput& input, EditorScene& scene, const ImageHitTestFn& imageHitTest, float hitScale,
    bool touchOptimized) {
    const auto hitTarget = target(
        input.screenPosition, input.viewSize, scene.skeleton, scene.selectedBoneID, input.camera, hitScale,
        touchOptimized, imageHitTest);

    if (hitTarget.has_value()) {
        if (hitTarget->kind == SelectionTarget::Kind::Image) {
            scene.setSelection({hitTarget->id}, hitTarget->id, input.isShiftPressed);
        } else {
            // Bones used to ignore modifiers entirely, so `selectBone` reset
            // the multi-selection on every click and building an IK chain
            // from the viewport was impossible with the tool artists
            // actually use. Shift and Command both extend, matching how
            // images already behave here.
            if (input.isShiftPressed || input.isCommandPressed) {
                scene.toggleBoneSelection(hitTarget->id);
            } else {
                scene.selectBone(hitTarget->id);
            }
        }
    } else if (!input.isShiftPressed && !input.isCommandPressed) {
        // Command counts as much as Shift here. A Cmd-drag that starts on
        // empty canvas is the artist ADDING a marquee to what is already
        // selected; clearing on the press threw that away before the drag
        // had said anything, and the box came out as a plain replace.
        scene.clearSelection();
    }
}

} // namespace umeshcore
