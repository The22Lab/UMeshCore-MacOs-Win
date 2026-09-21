import MetalKit

/// The single input contract shared by every platform viewport view.
///
/// `ToolInputMTKView` (macOS: mouse, keyboard, hover, scroll) and
/// `TouchInputMTKView` (iPadOS: touch, Apple Pencil, multitouch gestures)
/// are thin platform input adapters. Each translates native events into
/// `ToolInput` and the callbacks below, so both platforms end up invoking
/// exactly the same core editor operations (`ToolManager`, `SceneManager`,
/// `CameraState`).
///
/// The SwiftUI bridge (`ViewportMetalView`) binds this contract once, in
/// shared code, instead of duplicating the wiring per platform. Anything a
/// platform adds on top of this contract (e.g. `onPinchZoom`, `onUndo`,
/// `onRedo` for touch) is bound in a small platform-specific extension —
/// but the destination is always the same shared core command.
protocol ViewportInputContract: MTKView {
    var camera: CameraState? { get set }

    /// The canvas sleeps when nothing is happening. This is how it knows a
    /// gesture is still in flight — a finger, Pencil or mouse button down —
    /// which is the one kind of "happening" that produces no events while it
    /// lasts. Asked once per frame and derived from state the view already
    /// keeps, so there is no begin/end pair to leave unbalanced.
    var isInteracting: Bool { get }

    /// Set once when the view is bound. The view wakes the canvas on the two
    /// things only it can see: becoming visible again, and going off-screen.
    var activity: CanvasActivity? { get set }

    var onMouseDown: ((ToolInput) -> Void)? { get set }
    var onMouseDrag: ((ToolInput) -> Void)? { get set }
    var onMouseUp: ((ToolInput) -> Void)? { get set }
    var onPan: ((CGPoint) -> Void)? { get set }
    var onZoom: ((CGFloat, CGPoint) -> Void)? { get set }
    var onFrameAll: ((CGSize) -> Void)? { get set }
    var onDeselect: (() -> Void)? { get set }
    /// The pointer left the canvas: an Apple Pencil lifted out of hover range,
    /// or a mouse moved off the view.
    ///
    /// In the contract rather than in each surface's private arrangement,
    /// because it is the half of hovering that is easy to forget — both
    /// platforms had `onMouseDrag` for "the pointer is here" and neither had
    /// anything for "it is gone", which is how a preview dot ends up painted
    /// on the canvas for the rest of the session.
    var onPointerExit: (() -> Void)? { get set }
    var onDelete: (() -> Void)? { get set }
    var onSelectTool: ((ActiveTool) -> Void)? { get set }
    var onQuickSelectTool: ((ActiveTool, CGPoint) -> Void)? { get set }
    var onQuickSelectEnd: (() -> Void)? { get set }
}

#if os(macOS)
extension ToolInputMTKView: ViewportInputContract {}
#else
extension TouchInputMTKView: ViewportInputContract {}
#endif
