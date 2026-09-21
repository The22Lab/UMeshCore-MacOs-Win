#if os(macOS)
import MetalKit
import AppKit
import QuartzCore
import simd

/// NOBODY HERE ASKS FOR A FRAME UNCONDITIONALLY. The view is free-running, so
/// `draw(in:)` already runs every vsync and a hand call on every event only
/// adds a synchronous frame that can block the main thread in `nextDrawable()`.
/// That is what made two-finger navigation judder on iPad, and the calls came
/// out of both views for it.
///
/// WITH ONE EXCEPTION, WHICH IS macOS-SHAPED. AppKit runs a modal event-tracking
/// run loop while a mouse button is held, and MTKView's display link does not
/// deliver into it — so through the whole of a drag the canvas stops repainting
/// and the rig snaps to its final pose on release. The hand-drawn frames were
/// covering that up; taking them away uncovered it, on the Mac only, because
/// UIKit has no equivalent mode.
///
/// So `activity.drawIfDisplayLinkStalled()` draws only when a frame has NOT just
/// happened. A healthy link means it does nothing at all — the iPad never
/// reaches it, and neither does the Mac outside a drag. It covers the frozen
/// interval and no more.
///
/// WHAT DRIVES IT MATTERS AS MUCH AS THAT IT EXISTS. It used to be driven by the
/// mouse handlers, so through a drag the Mac produced frames at the rate the
/// POINTER reported — a trackpad's ~90 Hz, a mouse's 125, coalesced by AppKit
/// and aligned to nothing. Frames arrived at irregular intervals decided by the
/// input device rather than by the display, and that is the whole of why
/// dragging felt worse on the Mac than on the iPad, where UIKit's link keeps
/// firing through a touch and no such path exists.
///
/// Now a CADisplayLink of this view's own, added to the main run loop in
/// `.common` mode, drives it. Common mode is the point: it is delivered inside
/// the modal event-tracking loop that silences MTKView's link. So a macOS drag
/// is paced by the display, exactly as it always was on iPadOS.
///
/// The mouse handlers still call it. They are harmless — the guard makes them
/// no-ops once a frame has just happened — and they cover the first instant of
/// a drag before the link's next tick.
///
/// See `Editor/verify_canvas_navigation_pacing.py` and
/// `Editor/verify_display_rate.py`.
final class ToolInputMTKView: MTKView {
    var onMouseDown: ((ToolInput) -> Void)?
    var onMouseDrag: ((ToolInput) -> Void)?
    var onMouseUp: ((ToolInput) -> Void)?
    var onPan: ((CGPoint) -> Void)?
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    var onFrameAll: ((CGSize) -> Void)?
    var onDeselect: (() -> Void)?
    var onPointerExit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSelectTool: ((ActiveTool) -> Void)?
    var onQuickSelectTool: ((ActiveTool, CGPoint) -> Void)?
    var onQuickSelectEnd: (() -> Void)?
    var camera: CameraState?
    weak var activity: CanvasActivity?

    /// Drives the canvas while AppKit's modal event loop silences MTKView's
    /// own link. See the note at the top of this file.
    private var commonModeLink: CADisplayLink?

    var isInteracting: Bool {
        isPanning || isToolInteracting || isSecondaryToolGestureActive
    }

    private var dragStartWorld = SIMD2<Float>(repeating: 0)
    private var dragStartScreen = SIMD2<Float>(repeating: 0)
    private var lastDragScreen = SIMD2<Float>(repeating: 0)
    private var isPanning = false
    /// True between mouse-down and mouse-up. `isInteracting` above is what
    /// keeps the canvas awake through a drag that pauses — a handle grabbed and
    /// held still produces no events, and a grace window alone would sleep
    /// under the cursor. If this ever leaks true the cost is a canvas that
    /// renders when it need not, never one that fails to render.
    private var isToolInteracting = false
    private var lastPanLocation: CGPoint = .zero
    private var isSecondaryToolGestureActive = false
    private var secondaryToolGestureStart: CGPoint = .zero
    private var secondaryToolGestureAnchor: CGPoint = .zero
    private var lastSecondaryGestureTool: ActiveTool?

    // MARK: - The pointer leaving

    /// Without a tracking area `mouseExited` is never sent, which is why this
    /// half of hovering was missing on the Mac as well as on the iPad: the view
    /// was told where the pointer is and never told that it had gone. The
    /// preview dot stayed on the canvas when the pointer moved to the
    /// inspector, exactly as it stayed when the Pencil lifted.
    ///
    /// `.inVisibleRect` so it resizes with the view rather than being rebuilt
    /// against stale bounds, and `.activeInKeyWindow` so a background window's
    /// canvas is not tracking a pointer that belongs to another window.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerExit?()
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        updatePreferredFrameRate()
        observeOcclusion()
        observeScreenChanges()
        startCommonModeLink()
        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
        addGestureRecognizer(pinch)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updatePreferredFrameRate()
        // Moved to a display with a different scale or refresh rate: the canvas
        // has to redraw at the new backing size even if nothing in the scene
        // changed. Door 5, view-driven — see `MetalRenderer.mtkView(_:drawableSizeWillChange:)`.
        activity?.wake()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.option) {
            isPanning = true
            lastPanLocation = screenCGPoint(for: event.locationInWindow)
            beginInteractiveRendering()
            return
        }
        let world = worldPosition(for: event)
        let screenPoint = screenPoint(for: event.locationInWindow)
        let screen = SIMD2<Float>(Float(screenPoint.x), Float(screenPoint.y))
        let viewSize = currentViewSize()
        dragStartWorld = world
        dragStartScreen = screen
        lastDragScreen = screen
        beginInteractiveRendering()
        onMouseDown?(ToolInput(position: world, startPosition: world, screenPosition: screen, previousScreenPosition: screen, screenDelta: .zero, startScreenPosition: screen, viewSize: viewSize, isDragging: false, isShiftPressed: event.modifierFlags.contains(.shift), isCommandPressed: event.modifierFlags.contains(.command), clickCount: event.clickCount, hoveredHandle: nil, activeHandle: nil, camera: camera))
    }

    override func mouseDragged(with event: NSEvent) {
        if isPanning {
            let location = screenCGPoint(for: event.locationInWindow)
            let delta = CGPoint(x: location.x - lastPanLocation.x, y: location.y - lastPanLocation.y)
            lastPanLocation = location
            onPan?(delta)
            activity?.drawIfDisplayLinkStalled()
            return
        }
        let world = worldPosition(for: event)
        let screenPoint = screenPoint(for: event.locationInWindow)
        let screen = SIMD2<Float>(Float(screenPoint.x), Float(screenPoint.y))
        let viewSize = currentViewSize()
        let previousScreen = lastDragScreen
        let delta = screenPointDelta(for: event)
        let screenDelta = SIMD2<Float>(Float(delta.x), Float(delta.y))
        lastDragScreen = screen
        onMouseDrag?(ToolInput(position: world, startPosition: dragStartWorld, screenPosition: screen, previousScreenPosition: previousScreen, screenDelta: screenDelta, startScreenPosition: dragStartScreen, viewSize: viewSize, isDragging: true, isShiftPressed: event.modifierFlags.contains(.shift), isCommandPressed: event.modifierFlags.contains(.command), clickCount: event.clickCount, hoveredHandle: nil, activeHandle: nil, camera: camera))
        activity?.drawIfDisplayLinkStalled()
    }

    override func mouseUp(with event: NSEvent) {
        if isPanning {
            isPanning = false
            activity?.drawIfDisplayLinkStalled()
            endInteractiveRendering()
            return
        }
        let world = worldPosition(for: event)
        let screenPoint = screenPoint(for: event.locationInWindow)
        let screen = SIMD2<Float>(Float(screenPoint.x), Float(screenPoint.y))
        let viewSize = currentViewSize()
        onMouseUp?(ToolInput(position: world, startPosition: dragStartWorld, screenPosition: screen, previousScreenPosition: lastDragScreen, screenDelta: .zero, startScreenPosition: dragStartScreen, viewSize: viewSize, isDragging: false, isShiftPressed: event.modifierFlags.contains(.shift), clickCount: event.clickCount, hoveredHandle: nil, activeHandle: nil, camera: camera))
        lastDragScreen = screen
        activity?.drawIfDisplayLinkStalled()
        endInteractiveRendering()
    }

    override func mouseMoved(with event: NSEvent) {
        let world = worldPosition(for: event)
        let screenPoint = screenPoint(for: event.locationInWindow)
        let screen = SIMD2<Float>(Float(screenPoint.x), Float(screenPoint.y))
        let viewSize = currentViewSize()
        onMouseDrag?(ToolInput(position: world, startPosition: dragStartWorld, screenPosition: screen, previousScreenPosition: lastDragScreen, screenDelta: .zero, startScreenPosition: dragStartScreen, viewSize: viewSize, isDragging: false, isShiftPressed: event.modifierFlags.contains(.shift), clickCount: event.clickCount, hoveredHandle: nil, activeHandle: nil, camera: camera))
        lastDragScreen = screen
        activity?.drawIfDisplayLinkStalled()
    }

    override func scrollWheel(with event: NSEvent) {
        let location = screenCGPoint(for: event.locationInWindow)
        if event.phase != [] || event.momentumPhase != [] || event.hasPreciseScrollingDeltas {
            // Match Photoshop-style trackpad panning so content follows the two-finger drag.
            let preciseDelta = screenPointScrollDelta(for: event)
            let delta = CGPoint(x: preciseDelta.x, y: -preciseDelta.y)
            onPan?(delta)
        } else {
            onZoom?(event.scrollingDeltaY, location)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers?.lowercased() == "f" {
            let viewSize = bounds.size
            onFrameAll?(viewSize)
            return
        }
        if event.keyCode == 53 {
            onDeselect?()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
            return
        }
        if let key = event.charactersIgnoringModifiers?.lowercased() {
            if let tool = toolForKey(key) {
                onSelectTool?(tool)
                return
            }
        }
        super.keyDown(with: event)
    }

    @objc private func handleMagnify(_ recognizer: NSMagnificationGestureRecognizer) {
        guard recognizer.state == .changed else { return }
        let location = screenCGPoint(for: recognizer.location(in: self))
        onZoom?(recognizer.magnification * 120, location)
        recognizer.magnification = 0
    }

    private func worldPosition(for event: NSEvent) -> SIMD2<Float> {
        let location = screenPoint(for: event.locationInWindow)
        let viewSize = currentViewSize()
        let screenPoint = SIMD2<Float>(Float(location.x), Float(location.y))
        if let camera {
            return camera.screenToWorld(screenPoint, viewSize: viewSize)
        }
        let centered = screenPoint - viewSize * 0.5
        return centered
    }

    private func toolForKey(_ key: String) -> ActiveTool? {
        switch key {
        case "q": return .select
        case "b": return .bone
        case "a": return .mesh
        case "w": return .move
        case "e": return .rotate
        case "r": return .scale
        case "s": return .skew
        case "y": return .physicsPreview
        default: return nil
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 {
            isPanning = true
            lastPanLocation = screenCGPoint(for: event.locationInWindow)
            beginInteractiveRendering()
        } else {
            super.otherMouseDown(with: event)
        }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if isPanning {
            let location = screenCGPoint(for: event.locationInWindow)
            let delta = CGPoint(x: location.x - lastPanLocation.x, y: location.y - lastPanLocation.y)
            lastPanLocation = location
            onPan?(delta)
        } else {
            super.otherMouseDragged(with: event)
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        if isPanning {
            isPanning = false
            endInteractiveRendering()
        } else {
            super.otherMouseUp(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isSecondaryToolGestureActive = true
        lastSecondaryGestureTool = nil
        secondaryToolGestureStart = screenCGPoint(for: event.locationInWindow)
        secondaryToolGestureAnchor = overlayPoint(for: event.locationInWindow)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard isSecondaryToolGestureActive else { return }

        let current = screenCGPoint(for: event.locationInWindow)
        let dx = current.x - secondaryToolGestureStart.x
        let dy = current.y - secondaryToolGestureStart.y
        let threshold: CGFloat = 12
        let diagonalMargin: CGFloat = 6

        guard abs(dx) >= threshold || abs(dy) >= threshold else { return }

        let horizontalDominant = abs(dx) - abs(dy) > diagonalMargin
        let verticalDominant = abs(dy) - abs(dx) > diagonalMargin

        if !horizontalDominant && !verticalDominant {
            return
        }

        let tool: ActiveTool
        if horizontalDominant {
            tool = dx >= 0 ? .skew : .move
        } else {
            tool = dy >= 0 ? .scale : .rotate
        }

        guard tool != lastSecondaryGestureTool else { return }
        lastSecondaryGestureTool = tool
        onQuickSelectTool?(tool, secondaryToolGestureAnchor)
        activity?.drawIfDisplayLinkStalled()
    }

    override func rightMouseUp(with event: NSEvent) {
        isSecondaryToolGestureActive = false
        lastSecondaryGestureTool = nil
        onQuickSelectEnd?()
        activity?.drawIfDisplayLinkStalled()
    }

    /// Both of these used to set `isPaused = false` on a view that was already
    /// unpaused, so they did nothing at all. They are the bracket around every
    /// mouse interaction on this platform, which is exactly what the canvas
    /// needs in order to know it may not sleep yet — so they now mark that,
    /// and wake, instead of restating a constant.
    private func beginInteractiveRendering() {
        isToolInteracting = true
        activity?.wake()
    }

    private func endInteractiveRendering() {
        isToolInteracting = false
        activity?.wake()
    }

    private func currentViewSize() -> SIMD2<Float> {
        SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
    }

    private func screenPoint(for windowLocation: CGPoint) -> CGPoint {
        let local = convert(windowLocation, from: nil)
        return screenCGPoint(for: local)
    }

    private func overlayPoint(for windowLocation: CGPoint) -> CGPoint {
        let local = convert(windowLocation, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    private func screenCGPoint(for localPoint: CGPoint) -> CGPoint {
        let scaleX = bounds.width > 0 ? drawableSize.width / bounds.width : 1.0
        let scaleY = bounds.height > 0 ? drawableSize.height / bounds.height : 1.0
        return CGPoint(
            x: localPoint.x * scaleX,
            y: (bounds.height - localPoint.y) * scaleY
        )
    }

    private func screenPointDelta(for event: NSEvent) -> CGPoint {
        let scaleX = bounds.width > 0 ? drawableSize.width / bounds.width : 1.0
        let scaleY = bounds.height > 0 ? drawableSize.height / bounds.height : 1.0
        return CGPoint(x: event.deltaX * scaleX, y: event.deltaY * scaleY)
    }

    private func screenPointScrollDelta(for event: NSEvent) -> CGPoint {
        let scaleX = bounds.width > 0 ? drawableSize.width / bounds.width : 1.0
        let scaleY = bounds.height > 0 ? drawableSize.height / bounds.height : 1.0
        return CGPoint(x: event.scrollingDeltaX * scaleX, y: event.scrollingDeltaY * scaleY)
    }

    /// A window the user cannot see is not worth a frame. Occlusion — covered
    /// by another window, minimised, on a different Space — is a stronger
    /// signal than losing focus: an unfocused window is still on screen and may
    /// still be playing back an animation the user is watching.
    private func observeOcclusion() {
        guard let window else { return }
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowOcclusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
        windowOcclusionChanged()
    }

    /// A selector rather than a closure: the method is on the view, so it is
    /// already main-actor isolated and needs no cast to say so.
    @objc private func windowOcclusionChanged() {
        activity?.setOnScreen(window?.occlusionState.contains(.visible) ?? true)
    }

    /// Ask for exactly what this display can do — not 120, not 60.
    ///
    /// This used to be `maximumFPS >= 120 ? 120 : 60`, which threw away every
    /// rate that is not one of those two: a 144 Hz monitor ran at 120, a 165 Hz
    /// at 120, and a 90 Hz display at SIXTY. MTKView clamps the request to what
    /// the display can actually deliver, so handing it the real maximum is both
    /// the simplest and the only correct thing.
    ///
    /// Falls back to the main screen while the view has no window yet — the old
    /// `?? 60` meant a view configured before it was placed stayed at 60 until
    /// something else happened to re-run this.
    private func updatePreferredFrameRate() {
        let screen = window?.screen ?? NSScreen.main
        let maximumFPS = screen?.maximumFramesPerSecond ?? 60
        guard maximumFPS > 0 else { return }
        if preferredFramesPerSecond != maximumFPS {
            preferredFramesPerSecond = maximumFPS
        }
        commonModeLink?.preferredFrameRateRange =
            CAFrameRateRange(minimum: Float(min(30, maximumFPS)),
                             maximum: Float(maximumFPS),
                             preferred: Float(maximumFPS))
        FrameStatistics.shared.setDisplayRefreshRate(maximumFPS)
    }

    /// A display link that survives the modal event loop.
    ///
    /// `NSView.displayLink(target:selector:)` is bound to the display this view
    /// is actually on and follows it across screens, so it needs no rebuilding
    /// when the window moves — but it does need rebuilding when the view
    /// changes window, which is where this is called from.
    deinit {
        commonModeLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func startCommonModeLink() {
        commonModeLink?.invalidate()
        commonModeLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(commonModeTick))
        link.add(to: .main, forMode: .common)
        commonModeLink = link
        updatePreferredFrameRate()
    }

    @objc private func commonModeTick() {
        // Does nothing whenever MTKView's own link is healthy. It takes over
        // for exactly as long as that link is silent, which is the duration of
        // a modal drag and no longer.
        activity?.drawIfDisplayLinkStalled()
    }

    /// Moving to another display, plugging in a monitor, changing a display's
    /// mode: all of them change what "as fast as possible" means.
    ///
    /// `viewDidChangeBackingProperties` alone does not cover it — it fires on a
    /// change of SCALE, so moving between two Retina displays of different
    /// refresh rates never reached it and the canvas kept the old rate.
    private func observeScreenChanges() {
        let centre = NotificationCenter.default
        centre.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: nil)
        centre.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification,
                              object: nil)
        centre.addObserver(self, selector: #selector(screenChanged),
                           name: NSWindow.didChangeScreenNotification, object: window)
        centre.addObserver(self, selector: #selector(screenChanged),
                           name: NSApplication.didChangeScreenParametersNotification,
                           object: nil)
    }

    @objc private func screenChanged() {
        updatePreferredFrameRate()
        activity?.wake()
    }
}
#endif
