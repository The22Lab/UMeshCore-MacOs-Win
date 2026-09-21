#if os(iOS)
import MetalKit
import UIKit
import simd

/// iOS/iPadOS equivalent of ToolInputMTKView. Translates UITouch and Apple
/// Pencil events into the same ToolInput contract consumed by ToolManager.
///
/// Design goals (matching Procreate / Nomad Sculpt / Affinity behaviour):
/// - Pinch zoom and two-finger pan are delivered 1:1 in drawable pixels, with
///   no exponential remapping, damping, or smoothing anywhere in the path.
/// - Apple Pencil input is instantaneous and always wins over finger input
///   (palm rejection: a pencil landing while a palm/finger interaction is in
///   flight takes over immediately).
/// - Single-finger tool input is deferred by an imperceptible window (~70 ms
///   or until the finger moves past a small slop) so that a second finger
///   landing for navigation never triggers a stray selection or edit.
/// - Two-finger tap = undo, three-finger tap = redo (standard iPad idiom).
/// - Apple Pencil hover (M2 iPads + Pencil 2 / Pencil Pro) and trackpad
///   pointers drive the same hover-highlight path the Mac uses for the mouse.
///
/// NOBODY HERE ASKS FOR A FRAME. `ViewportView.configure` leaves the view
/// free-running (`isPaused = false`, `enableSetNeedsDisplay = false`), so the
/// display link already calls `draw(in:)` every vsync — 120 times a second on
/// a ProMotion iPad. A handler that also called `view.draw()` was not reducing
/// latency by any amount anyone can perceive; it was adding a whole extra
/// synchronous frame on the main thread, inside `nextDrawable()`, which with
/// `maximumDrawableCount = 2` and `allowsNextDrawableTimeout = false` BLOCKS
/// until the compositor hands one back.
///
/// That is what made two-finger navigation judder while dragging a sprite
/// stayed smooth. Dragging is one finger and asked for one extra frame;
/// navigating is two, and pan and pinch recognize simultaneously (by design,
/// just below), so a single two-finger movement asked for two. Three draws per
/// 8.33ms tick left each one 2.78ms of main thread instead of 8.33ms, and past
/// that line the thread blocks, the next touch is delivered late, and the
/// canvas lags the fingers and then jumps.
///
/// See `Editor/verify_canvas_navigation_pacing.py`. If the view is ever paused
/// to save power, these calls have to come back in the same commit — the
/// harness checks the two facts together for exactly that reason.
final class TouchInputMTKView: MTKView {

    // MARK: - Callbacks (same contract as ToolInputMTKView)

    var onMouseDown: ((ToolInput) -> Void)?
    var onMouseDrag: ((ToolInput) -> Void)?
    var onMouseUp: ((ToolInput) -> Void)?
    var onPan: ((CGPoint) -> Void)?
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    /// 1:1 pinch zoom. Delivers the raw gesture scale factor and the pinch
    /// anchor in drawable pixels. Preferred over `onZoom` for touch.
    var onPinchZoom: ((CGFloat, CGPoint) -> Void)?
    var onFrameAll: ((CGSize) -> Void)?
    var onDeselect: (() -> Void)?
    var onPointerExit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onSelectTool: ((ActiveTool) -> Void)?
    var onQuickSelectTool: ((ActiveTool, CGPoint) -> Void)?
    var onQuickSelectEnd: (() -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var camera: CameraState?
    weak var activity: CanvasActivity?

    /// Finger navigates, Pencil does everything else — the gesture Clip Studio
    /// Paint puts behind its finger button.
    ///
    /// On: one finger pans, two pinch, and a finger NEVER reaches a tool. The
    /// Pencil keeps every tool it had. Off: today's behaviour, where one finger
    /// is a tool and two navigate.
    ///
    /// Pushed down from SwiftUI rather than read from `UserDefaults` here, so
    /// the view has one source for it and the preference lives in one place.
    var fingerNavigationOnly = false {
        didSet {
            guard fingerNavigationOnly != oldValue else { return }
            // A finger mid-gesture under the old rule has to be let go of, or
            // it finishes as a tool drag the new rule would never have started.
            cancelPendingFingerDown()
            if activeTouchHash != nil, !activeTouchIsPencil {
                if toolDownCommitted { deliverMouseUp(at: lastDragScreen) }
                clearActiveTouch()
            }
            panRecognizer?.minimumNumberOfTouches = fingerNavigationOnly ? 1 : 2
            activity?.wake()
        }
    }

    /// Anything on the glass, committed or not, plus a navigation gesture in
    /// flight. All four are state the view already keeps for its own reasons,
    /// read rather than tracked, so there is no begin/end pair to unbalance —
    /// and a wrong answer here can only keep the canvas rendering when it need
    /// not, never stop it rendering when it must.
    var isInteracting: Bool {
        activeTouchHash != nil
            || pendingFingerDown != nil
            || isNavigationGestureActive
            || isQuickSwitchActive
    }

    // MARK: - Private state

    private var dragStartWorld = SIMD2<Float>(repeating: 0)
    private var dragStartScreen = SIMD2<Float>(repeating: 0)
    private var lastDragScreen = SIMD2<Float>(repeating: 0)

    /// Hash of the active tool-input touch (pencil preferred, then first finger).
    private var activeTouchHash: Int?
    private var activeTouchIsPencil = false
    /// `UITouch.tapCount` of the touch that began the interaction. It is what
    /// `clickCount` carries on iPadOS, so a double tap reaches the tools as a
    /// double click. It was hardcoded to 1, which made every "double-click to
    /// switch" rule unreachable from the glass.
    private var downTapCount = 1
    /// True once the active tool touch has actually delivered its mouse-down.
    private var toolDownCommitted = false
    private var isDraggingTool = false

    /// A single finger has landed but its mouse-down has not been delivered
    /// yet. It commits after `fingerDownDelay`, or immediately once the finger
    /// moves past `fingerDownSlop` — and it is silently discarded if a second
    /// finger (navigation) or the Pencil (palm rejection) arrives first.
    private struct PendingFingerDown {
        let touchHash: Int
        let startLocal: CGPoint
    }
    private var pendingFingerDown: PendingFingerDown?
    /// True while the two-finger pan or pinch recognizer is between `.began`
    /// and its end. A pinch held still mid-gesture emits no callbacks, and the
    /// canvas must not fall asleep under two resting fingers.
    private var isNavigationGestureActive = false
    private var pendingFingerCommitTask: Task<Void, Never>?
    /// Hardware-keyboard modifiers captured when the tool touch began, so a
    /// deferred mouse-down still honours Shift-tap (additive selection).
    private var downModifiers: UIKeyModifierFlags = []
    /// Delay before an ambiguous single-finger touch becomes tool input.
    /// Short enough to be imperceptible on tap, long enough for the second
    /// finger of a navigation gesture to land.
    private let fingerDownDelay: UInt64 = 70_000_000 // ns
    /// Movement (in points) past which a pending finger commits immediately.
    private let fingerDownSlop: CGFloat = 6

    // Quick-switch gesture state — triggered by Apple Pencil double-tap.
    private var isQuickSwitchActive = false
    private var isQuickSwitchPending = false   // armed after pencil double-tap
    private var quickSwitchStartScreen: CGPoint = .zero
    private var lastQuickSwitchTool: ActiveTool?

    // Last known Apple Pencil tip position (used to anchor the tool wheel).
    private var lastPencilLocation: CGPoint = .zero

    // Gesture recognizers (kept for delegate disambiguation).
    private weak var panRecognizer: UIPanGestureRecognizer?
    private weak var pinchRecognizer: UIPinchGestureRecognizer?

    // Haptics. Prepared lazily; UIKit keeps the Taptic Engine warm briefly.
    private let selectionHaptic = UISelectionFeedbackGenerator()
    private let impactHaptic = UIImpactFeedbackGenerator(style: .light)

    // MARK: - Setup

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePreferredFrameRate()
        setupGestureRecognizers()
        setupPencilInteraction()
        observeAppVisibility()
    }

    private func setupGestureRecognizers() {
        guard panRecognizer == nil else { return }

        // Two-finger pan → canvas pan (finger-only; the Pencil never navigates).
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        // One finger when the finger is navigation, two otherwise. Set from the
        // flag rather than hardcoded, because SwiftUI can push the preference
        // down before this view ever moves to a window.
        pan.minimumNumberOfTouches = fingerNavigationOnly ? 1 : 2
        pan.maximumNumberOfTouches = 2
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pan.delegate = self
        addGestureRecognizer(pan)
        panRecognizer = pan

        // Pinch → zoom (finger-only).
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pinch.delegate = self
        addGestureRecognizer(pinch)
        pinchRecognizer = pinch

        // Two-finger tap → undo, three-finger tap → redo.
        let undoTap = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap(_:)))
        undoTap.numberOfTouchesRequired = 2
        undoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        undoTap.delegate = self
        addGestureRecognizer(undoTap)

        let redoTap = UITapGestureRecognizer(target: self, action: #selector(handleRedoTap(_:)))
        redoTap.numberOfTouchesRequired = 3
        redoTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        redoTap.delegate = self
        addGestureRecognizer(redoTap)

        // Apple Pencil hover / trackpad pointer → same hover-highlight path
        // the Mac drives with mouse-moved events.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        addGestureRecognizer(hover)
    }

    private func setupPencilInteraction() {
        // Apple Pencil double-tap arms the quick-switch tool wheel.
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
    }

    // MARK: - Touch handling (single-touch tool operations)

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pencilTouch = touches.first(where: { $0.type == .pencil })

        // Track pencil tip position for wheel anchoring.
        if let pencilTouch {
            lastPencilLocation = pencilTouch.location(in: self)
        }

        // If the Pencil double-tap armed the wheel, enter quick-switch drag mode.
        //
        // Locked, only the Pencil may drive it. The wheel picks a TOOL, and
        // "a finger never reaches a tool" has to hold here too or it is not an
        // invariant, just a habit. The wheel is armed by a Pencil double-tap
        // anyway, so the Pencil is already in hand.
        if isQuickSwitchPending,
           let touch = pencilTouch ?? (fingerNavigationOnly ? nil : touches.first) {
            isQuickSwitchPending = false
            isQuickSwitchActive = true
            activeTouchHash = touch.hash
            activeTouchIsPencil = touch.type == .pencil
            quickSwitchStartScreen = overlayPoint(for: touch.location(in: self))
            lastQuickSwitchTool = nil
            return  // Don't fire normal tool-down
        }

        // ── Palm rejection: the Pencil always takes over from a finger. ──
        if let pencilTouch {
            if pendingFingerDown != nil {
                // The earlier finger was a palm — discard it silently.
                cancelPendingFingerDown()
            } else if let hash = activeTouchHash, !activeTouchIsPencil, toolDownCommitted {
                // A committed finger interaction is in flight; close it out
                // cleanly at its current position before the Pencil begins.
                if let fingerTouch = event?.allTouches?.first(where: { $0.hash == hash }) {
                    deliverMouseUp(at: screenPoint(for: fingerTouch))
                } else {
                    deliverMouseUp(at: lastDragScreen)
                }
                clearActiveTouch()
            }
            // A palm that landed BEFORE the Pencil has already started a pan;
            // `gestureRecognizerShouldBegin` cannot refuse what it allowed a
            // moment ago, so the gesture is taken away instead.
            if fingerNavigationOnly { cancelNavigationGestures() }
            guard activeTouchHash == nil else { return }
            beginToolTouch(pencilTouch, deferring: false, event: event)
            return
        }

        // ── Finger input ──

        // Locked: a finger is navigation and nothing else. Returning here is
        // the whole of it — the pan and pinch recognizers do the work, and
        // because no tool touch is ever begun there is no deferral to cancel,
        // no palm to reject and no stray edit to undo.
        if fingerNavigationOnly { return }

        // A second finger landing while another is pending means navigation
        // (pan, pinch, or undo/redo tap) — discard the pending tool-down.
        if let pending = pendingFingerDown,
           touches.contains(where: { $0.type == .direct && $0.hash != pending.touchHash }) {
            cancelPendingFingerDown()
            return
        }

        guard activeTouchHash == nil, pendingFingerDown == nil,
              let touch = touches.first(where: { $0.type == .direct }) ?? touches.first else {
            return
        }

        // A second simultaneous finger means navigation, not tool input.
        let directCount = event?.allTouches?.filter {
            $0.type == .direct && ($0.phase == .began || $0.phase == .moved || $0.phase == .stationary)
        }.count ?? touches.count
        guard directCount <= 1 else { return }

        beginToolTouch(touch, deferring: true, event: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Track pencil position continuously.
        if let pencilTouch = touches.first(where: { $0.type == .pencil }) {
            lastPencilLocation = pencilTouch.location(in: self)
        }

        // Quick-switch drag direction determines which tool to highlight.
        if isQuickSwitchActive, let touch = activeTouch(from: touches) {
            let anchor = overlayPoint(for: touch.location(in: self))
            let dx = anchor.x - quickSwitchStartScreen.x
            let dy = anchor.y - quickSwitchStartScreen.y
            let threshold: CGFloat = 12
            let diagonalMargin: CGFloat = 6
            guard abs(dx) >= threshold || abs(dy) >= threshold else { return }
            let horizontalDominant = abs(dx) - abs(dy) > diagonalMargin
            let verticalDominant   = abs(dy) - abs(dx) > diagonalMargin
            guard horizontalDominant || verticalDominant else { return }
            let tool: ActiveTool
            if horizontalDominant { tool = dx >= 0 ? .skew : .move }
            else { tool = dy >= 0 ? .scale : .rotate }
            guard tool != lastQuickSwitchTool else { return }
            lastQuickSwitchTool = tool
            selectionHaptic.selectionChanged()
            onQuickSelectTool?(tool, anchor)
            return
        }

        // A pending finger that moves past the slop is unambiguously tool
        // input — commit its mouse-down at the original location, then let
        // the drag flow through below.
        if let pending = pendingFingerDown,
           let touch = touches.first(where: { $0.hash == pending.touchHash }) {
            let loc = touch.location(in: self)
            let dx = loc.x - pending.startLocal.x
            let dy = loc.y - pending.startLocal.y
            if (dx * dx + dy * dy) >= fingerDownSlop * fingerDownSlop {
                commitPendingFingerDown()
            } else {
                return
            }
        }

        guard toolDownCommitted, let touch = activeTouch(from: touches) else { return }

        let pt = screenPoint(for: touch)
        let world = worldPosition(at: pt)
        let viewSz = currentViewSize()
        let prev = lastDragScreen
        let delta = SIMD2<Float>(pt.x - prev.x, pt.y - prev.y)
        lastDragScreen = pt
        isDraggingTool = true

        onMouseDrag?(ToolInput(
            position: world,
            startPosition: dragStartWorld,
            screenPosition: pt,
            previousScreenPosition: prev,
            screenDelta: delta,
            startScreenPosition: dragStartScreen,
            viewSize: viewSz,
            isDragging: true,
            isShiftPressed: event?.modifierFlags.contains(.shift) ?? false,
            isCommandPressed: event?.modifierFlags.contains(.command) ?? false,
            clickCount: 1,
            hoveredHandle: nil,
            activeHandle: nil,
            camera: camera
        ))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        // End quick-switch mode.
        if isQuickSwitchActive, activeTouch(from: touches) != nil {
            isQuickSwitchActive = false
            lastQuickSwitchTool = nil
            clearActiveTouch()
            onQuickSelectEnd?()
            return
        }

        // A pending finger lifting is a tap: deliver down + up back to back so
        // taps select instantly with zero perceived latency. If other fingers
        // are on the glass it was navigation instead — discard silently.
        if let pending = pendingFingerDown,
           touches.contains(where: { $0.hash == pending.touchHash }) {
            let hasOtherDirectTouch = event?.allTouches?.contains(where: {
                $0.type == .direct && $0.hash != pending.touchHash && $0.phase != .cancelled
            }) ?? false
            if hasOtherDirectTouch {
                cancelPendingFingerDown()
                return
            }
            commitPendingFingerDown()
        }

        guard let touch = activeTouch(from: touches) else { return }
        let wasCommitted = toolDownCommitted
        clearActiveTouch()
        guard wasCommitted else { return }

        let pt = screenPoint(for: touch)
        deliverMouseUp(at: pt, event: event)
        lastDragScreen = pt
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isQuickSwitchActive {
            isQuickSwitchActive = false
            isQuickSwitchPending = false
            lastQuickSwitchTool = nil
            clearActiveTouch()
            onQuickSelectEnd?()
            return
        }

        // A pending finger cancelled by a navigation gesture never became tool
        // input — discard it with no side effects. This is what prevents
        // two-finger pan/zoom from leaving stray selections or edits behind.
        if let pending = pendingFingerDown,
           touches.contains(where: { $0.hash == pending.touchHash }) {
            cancelPendingFingerDown()
            return
        }

        // A committed interaction that gets cancelled is closed out at its
        // last known position so tool state never dangles.
        if let touch = activeTouch(from: touches) {
            let wasCommitted = toolDownCommitted
            clearActiveTouch()
            if wasCommitted {
                deliverMouseUp(at: screenPoint(for: touch), event: event)
            }
        }
    }

    // MARK: - Tool touch lifecycle

    private func beginToolTouch(_ touch: UITouch, deferring: Bool, event: UIEvent?) {
        downModifiers = event?.modifierFlags ?? []
        downTapCount = max(touch.tapCount, 1)
        activeTouchHash = touch.hash
        activeTouchIsPencil = touch.type == .pencil
        toolDownCommitted = false
        isDraggingTool = false

        let pt = screenPoint(for: touch)
        dragStartScreen = pt
        lastDragScreen = pt
        dragStartWorld = worldPosition(at: pt)

        if deferring {
            pendingFingerDown = PendingFingerDown(
                touchHash: touch.hash,
                startLocal: touch.location(in: self)
            )
            pendingFingerCommitTask?.cancel()
            let delay = fingerDownDelay
            pendingFingerCommitTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.commitPendingFingerDown() }
            }
        } else {
            deliverMouseDown()
        }
    }

    private func commitPendingFingerDown() {
        guard pendingFingerDown != nil else { return }
        pendingFingerCommitTask?.cancel()
        pendingFingerCommitTask = nil
        pendingFingerDown = nil
        deliverMouseDown()
    }

    private func cancelPendingFingerDown() {
        pendingFingerCommitTask?.cancel()
        pendingFingerCommitTask = nil
        pendingFingerDown = nil
        clearActiveTouch()
    }

    private func clearActiveTouch() {
        activeTouchHash = nil
        activeTouchIsPencil = false
        toolDownCommitted = false
        isDraggingTool = false
    }

    private func deliverMouseDown() {
        guard !toolDownCommitted else { return }
        toolDownCommitted = true
        let pt = dragStartScreen
        let world = dragStartWorld
        let viewSz = currentViewSize()

        onMouseDown?(ToolInput(
            position: world,
            startPosition: world,
            screenPosition: pt,
            previousScreenPosition: pt,
            screenDelta: .zero,
            startScreenPosition: pt,
            viewSize: viewSz,
            isDragging: false,
            isShiftPressed: downModifiers.contains(.shift),
            isCommandPressed: downModifiers.contains(.command),
            clickCount: downTapCount,
            hoveredHandle: nil,
            activeHandle: nil,
            camera: camera
        ))
    }

    private func deliverMouseUp(at pt: SIMD2<Float>, event: UIEvent? = nil) {
        let world = worldPosition(at: pt)
        let viewSz = currentViewSize()
        onMouseUp?(ToolInput(
            position: world,
            startPosition: dragStartWorld,
            screenPosition: pt,
            previousScreenPosition: lastDragScreen,
            screenDelta: .zero,
            startScreenPosition: dragStartScreen,
            viewSize: viewSz,
            isDragging: false,
            isShiftPressed: event?.modifierFlags.contains(.shift) ?? false,
            isCommandPressed: event?.modifierFlags.contains(.command) ?? false,
            clickCount: 1,
            hoveredHandle: nil,
            activeHandle: nil,
            camera: camera
        ))
    }

    // MARK: - Gesture recognizers

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        updateNavigationGestureState()
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        // Translation arrives in points; the camera works in drawable pixels.
        // Converting keeps the canvas glued 1:1 to the fingers on Retina
        // displays instead of trailing them at half speed.
        let translation = recognizer.translation(in: self)
        let sx = bounds.width  > 0 ? drawableSize.width  / bounds.width  : 1
        let sy = bounds.height > 0 ? drawableSize.height / bounds.height : 1
        onPan?(CGPoint(x: translation.x * sx, y: -translation.y * sy))
        recognizer.setTranslation(.zero, in: self)
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        updateNavigationGestureState()
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        // Deliver the raw gesture scale so the zoom tracks the fingers
        // exactly 1:1, anchored at the pinch centroid (in drawable pixels).
        let anchor = scaledScreen(recognizer.location(in: self))
        onPinchZoom?(recognizer.scale, CGPoint(x: CGFloat(anchor.x), y: CGFloat(anchor.y)))
        recognizer.scale = 1.0
    }

    @objc private func handleUndoTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        impactHaptic.impactOccurred()
        onUndo?()
    }

    @objc private func handleRedoTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        impactHaptic.impactOccurred()
        onRedo?()
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        // Pencil hover / trackpad pointer drives the same hover-highlight path
        // the Mac drives with mouse-moved events. Never during a live drag.
        guard activeTouchHash == nil else { return }
        switch recognizer.state {
        case .began, .changed:
            let pt = scaledScreen(recognizer.location(in: self))
            let world = worldPosition(at: pt)
            let viewSz = currentViewSize()
            onMouseDrag?(ToolInput(
                position: world,
                startPosition: world,
                screenPosition: pt,
                previousScreenPosition: lastDragScreen,
                screenDelta: .zero,
                startScreenPosition: pt,
                viewSize: viewSz,
                isDragging: false,
                isShiftPressed: false,
                isCommandPressed: false,
                clickCount: 1,
                hoveredHandle: nil,
                activeHandle: nil,
                camera: camera
            ))
            lastDragScreen = pt
        case .ended, .cancelled, .failed:
            // THE ONE EVENT THAT MEANS THE PENCIL LEFT, and it used to fall
            // into `default: break`. Everything the hover lit up stayed lit —
            // the mesh Create preview draws its green dot at the tool
            // manager's last input, so that dot sat wherever the Pencil last
            // hovered for the rest of the session.
            onPointerExit?()
        default:
            break
        }
    }

    // MARK: - Hardware keyboard support (external keyboard / Magic Keyboard)

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            if key.modifierFlags.contains(.command), key.charactersIgnoringModifiers.lowercased() == "z" {
                if key.modifierFlags.contains(.shift) { onRedo?() } else { onUndo?() }
                return
            }
            if key.keyCode == .keyboardF { onFrameAll?(bounds.size); return }
            if key.keyCode == .keyboardDeleteOrBackspace || key.keyCode == .keyboardDeleteForward {
                onDelete?(); return
            }
            if key.keyCode == .keyboardEscape { onDeselect?(); return }
            if let tool = toolForKey(key.characters) { onSelectTool?(tool); return }
        }
        super.pressesBegan(presses, with: event)
    }

    // MARK: - Helpers

    private func activeTouch(from touches: Set<UITouch>) -> UITouch? {
        touches.first(where: { $0.hash == activeTouchHash })
    }

    private func screenPoint(for touch: UITouch) -> SIMD2<Float> {
        // Pencil reports sub-point precision via preciseLocation; use it to
        // get maximum accuracy when dragging bone joints with the stylus.
        let loc = touch.type == .pencil
            ? touch.preciseLocation(in: self)
            : touch.location(in: self)
        return scaledScreen(loc)
    }

    private func scaledScreen(_ local: CGPoint) -> SIMD2<Float> {
        let sx = bounds.width  > 0 ? drawableSize.width  / bounds.width  : 1
        let sy = bounds.height > 0 ? drawableSize.height / bounds.height : 1
        return SIMD2<Float>(Float(local.x * sx), Float(local.y * sy))
    }

    private func overlayPoint(for local: CGPoint) -> CGPoint { local }

    private func worldPosition(at screenPt: SIMD2<Float>) -> SIMD2<Float> {
        let viewSz = currentViewSize()
        if let camera { return camera.screenToWorld(screenPt, viewSize: viewSz) }
        return screenPt - viewSz * 0.5
    }

    private func currentViewSize() -> SIMD2<Float> {
        SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
    }

    private func toolForKey(_ chars: String?) -> ActiveTool? {
        switch chars?.lowercased() {
        case "q": return .select
        case "b": return .bone
        case "a": return .mesh
        case "w": return .move
        case "e": return .rotate
        case "r": return .scale
        case "s": return .skew
        case "y": return .physicsPreview
        default:  return nil
        }
    }

    /// Derived from the recognizers themselves on every callback, including
    /// the `.ended`/`.cancelled` ones the handlers above return early from —
    /// which is why this runs before their guard, not after it.
    /// Toggling `isEnabled` is the documented way to cancel a recognizer that
    /// is already tracking: it fails the gesture, which sends `.cancelled` to
    /// the handler and puts it back in the pool for the next touch.
    private func cancelNavigationGestures() {
        for recognizer in [panRecognizer, pinchRecognizer] {
            guard let recognizer, recognizer.state == .began || recognizer.state == .changed
            else { continue }
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
        isNavigationGestureActive = false
    }

    private func updateNavigationGestureState() {
        let live: (UIGestureRecognizer?) -> Bool = { r in
            guard let r else { return false }
            return r.state == .began || r.state == .changed
        }
        isNavigationGestureActive = live(panRecognizer) || live(pinchRecognizer)
        activity?.wake()
    }

    /// An app in the background has no canvas to keep up to date. This is the
    /// clearest saving of all and the one that needs no judgement: there is
    /// nobody to show a frame to.
    private func observeAppVisibility() {
        let centre = NotificationCenter.default
        centre.removeObserver(self, name: UIApplication.didEnterBackgroundNotification, object: nil)
        centre.removeObserver(self, name: UIApplication.willEnterForegroundNotification, object: nil)
        centre.addObserver(self, selector: #selector(appWentToBackground),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        centre.addObserver(self, selector: #selector(appCameToForeground),
                           name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @objc private func appWentToBackground() { activity?.setOnScreen(false) }
    @objc private func appCameToForeground() { activity?.setOnScreen(true) }

    /// Ask for exactly what this display can do.
    ///
    /// This used to be `>= 120 ? 120 : 60`, which is right for the two rates
    /// iPads have shipped with and wrong for every other number: a 90 Hz panel
    /// would have run at 60. Handing MTKView the real maximum is correct on any
    /// of them, and MTKView clamps a request the display cannot meet.
    ///
    /// On ProMotion this asks for a fixed 120 rather than a range. Letting the
    /// system choose adaptively needs `CADisplayLink.preferredFrameRateRange`,
    /// and MTKView owns its link and does not expose it — so the choice is
    /// between MTKView with a fixed maximum, and owning the link to gain a
    /// range. For a canvas that is either idle (and paused outright by
    /// `CanvasActivity`, which is a bigger saving than any range) or animating
    /// at full rate, the fixed maximum is the right one.
    private func updatePreferredFrameRate() {
        guard let screen = window?.windowScene?.screen else { return }
        let maximumFPS = screen.maximumFramesPerSecond
        guard maximumFPS > 0 else { return }
        if preferredFramesPerSecond != maximumFPS {
            preferredFramesPerSecond = maximumFPS
        }
        // What the frame statistics judge an interval against. Without it a
        // 120 Hz display is scored as if 16.7 ms were on time.
        FrameStatistics.shared.setDisplayRefreshRate(maximumFPS)
    }
}

// MARK: - UIPencilInteractionDelegate

extension TouchInputMTKView: UIPencilInteractionDelegate {
    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        // Apple Pencil double-tap arms the quick-switch tool wheel.
        // The wheel appears at the next pencil-down position.
        isQuickSwitchPending = true
    }
}

// MARK: - UIGestureRecognizerDelegate

extension TouchInputMTKView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Pinch and pan work together for fluid two-finger navigation
        // (zoom + pan + reposition in a single continuous gesture, like
        // Apple Maps). Taps stay exclusive so undo/redo can never fire
        // in the middle of a real pinch or pan.
        let navPair = (gestureRecognizer === panRecognizer && other === pinchRecognizer)
            || (gestureRecognizer === pinchRecognizer && other === panRecognizer)
        return navPair
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let isNavigation = gestureRecognizer === panRecognizer
            || gestureRecognizer === pinchRecognizer
        guard isNavigation else { return true }

        // Once a tool drag is genuinely in flight (committed and moving),
        // navigation may not steal the touch mid-edit.
        if toolDownCommitted && isDraggingTool { return false }

        // THE PALM. With the finger locked to navigation the pan recognizer
        // takes a SINGLE touch, and a palm resting on the glass is a single
        // `.direct` touch — so a hand laid down to draw would slide the canvas
        // out from under the Pencil. Nothing rejects it for us: the deferral
        // and the Pencil-wins rule in `touchesBegan` both protect TOOL input,
        // and navigation does not go through either.
        //
        // While the Pencil is on the glass, a finger is not navigating.
        if activeTouchHash != nil && activeTouchIsPencil { return false }

        return true
    }
}
#endif
