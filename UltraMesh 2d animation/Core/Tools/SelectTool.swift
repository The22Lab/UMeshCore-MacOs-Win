import Foundation

final class SelectTool: Tool {
    let type: ActiveTool = .select

    func onMouseDown(input: ToolInput, scene: SceneManager, assets: AssetManager) {
        if let target = ToolUtilities.hitTestSelectionTarget(
            screenPoint: input.screenPosition,
            worldPoint: input.position,
            viewSize: input.viewSize,
            scene: scene,
            assets: assets,
            camera: input.camera
        ) {
            switch target {
            case let .image(id):
                scene.setSelection(ids: [id], primary: id, additive: input.isShiftPressed)
            case let .bone(id):
                // Bones used to ignore modifiers entirely, so `selectBone` reset
                // the multi-selection on every click and building an IK chain
                // from the viewport was impossible with the tool artists
                // actually use. Shift and Command both extend, matching how
                // images already behave here.
                if input.isShiftPressed || input.isCommandPressed {
                    scene.toggleBoneSelection(id)
                } else {
                    scene.selectBone(id)
                }
            }
        } else if !input.isShiftPressed && !input.isCommandPressed {
            // Command counts as much as Shift here. A Cmd-drag that starts on
            // empty canvas is the artist ADDING a marquee to what is already
            // selected; clearing on the press threw that away before the drag
            // had said anything, and the box came out as a plain replace.
            scene.clearSelection()
        }
    }

    func onMouseDrag(input: ToolInput, scene: SceneManager, assets: AssetManager) {
    }

    func onMouseUp(input: ToolInput, scene: SceneManager, assets: AssetManager) {
    }
}
