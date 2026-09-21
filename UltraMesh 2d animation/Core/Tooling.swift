import Foundation
import simd

enum GizmoHandle: Equatable {
    case moveCenter
    case moveX
    case moveY
    case bone(UUID)
    case meshVertex(Int)
    case meshInternalEdge(Int)
    case rotateRing
    case scaleCorner(Int)
    case skewEdge(Int)
}

struct ToolInput {
    var position: SIMD2<Float>
    var startPosition: SIMD2<Float>
    var screenPosition: SIMD2<Float>
    var previousScreenPosition: SIMD2<Float>
    var screenDelta: SIMD2<Float>
    var startScreenPosition: SIMD2<Float>
    var viewSize: SIMD2<Float>
    var isDragging: Bool
    var isShiftPressed: Bool
    var isCommandPressed: Bool = false
    var clickCount: Int
    var hoveredHandle: GizmoHandle?
    var activeHandle: GizmoHandle?
    var camera: CameraState?
    /// True when `ToolManager`'s selection block moved `selectedImageID` on
    /// this very mouse-down. A tool that edits the selected sprite reads it to
    /// decide that this click was spent on choosing the sprite and must not
    /// also edit it — the Mesh tool's Add sub-mode used to put a node exactly
    /// where the artist clicked to select a different PNG. Defaulted so the
    /// input adapters, which cannot know, need not say.
    var didChangeSelection: Bool = false
}

protocol Tool {
    var type: ActiveTool { get }
    func onMouseDown(input: ToolInput, scene: SceneManager, assets: AssetManager)
    func onMouseDrag(input: ToolInput, scene: SceneManager, assets: AssetManager)
    func onMouseUp(input: ToolInput, scene: SceneManager, assets: AssetManager)
    func update(scene: SceneManager, assets: AssetManager)
}

extension Tool {
    func update(scene: SceneManager, assets: AssetManager) {
    }
}
