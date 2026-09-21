import Foundation
import QuartzCore
import MetalKit
import Combine

/// Decides when the canvas is allowed to STOP rendering.
///
/// Until now the viewport was free-running: `isPaused = false`,
/// `enableSetNeedsDisplay = false`, so MTKView's display link called
/// `draw(in:)` on every vsync forever. That is 120 frames a second with a rig
/// sitting perfectly still — and a frame is not cheap here. Each one solves the
/// whole skeleton through the constraint stack (IK, FABRIK, paths, physics),
/// resolves and sanitizes every mesh, runs linear-blend skinning over every
/// vertex and projects it all to screen. On a laptop that is a fan; on an iPad
/// it is the battery.
///
/// The saving is not "fewer frames". It is that an idle canvas does NO work at
/// all — no GPU, no CPU, and no display-link wakeup keeping the SoC out of its
/// idle states.
///
/// # Why this is queried and not counted
///
/// The obvious shape is a counter or an OptionSet of holds: begin an
/// interaction, end an interaction. Every one of those has the same failure —
/// an unbalanced pair. A hold acquired and never released pins the canvas at
/// 120Hz forever, which silently undoes the whole feature; a hold released
/// twice sleeps the canvas mid-gesture, which looks like the app freezing.
/// Neither shows up in a test that exercises the happy path.
///
/// So nothing here is tracked over time. At the end of every frame the canvas
/// ASKS three questions — is a finger down, is the animation playing, is the
/// camera flying — and each answer is derived from state that already exists
/// and is already correct. There is no pairing to get wrong, and a probe that
/// throws an exception, returns a stale value or is never set can only ever
/// make the canvas render MORE than it needs to, never less.
///
/// # Why sleeping is safe
///
/// A canvas that sleeps through a change shows the wrong thing, which is worse
/// than any battery cost. The safety argument is not "we thought of every
/// mutation" — it is that everything which can change the picture arrives
/// through one of five doors, and all five are wired:
///
///  1. **Input.** Every callback in `ViewportMetalView.bindShared` and
///     `bindTouchExtras` wakes, so every mouse, touch, Pencil and gesture path
///     does — before running the command, not after, so a handler that happens
///     to change nothing this time still counts as the user being here.
///  2. **The camera.** `CameraState` wakes from inside its own mutators, so no
///     caller can navigate without waking — including the ones that never touch
///     the viewport, like Frame Selected from a menu or a restored project.
///     Nothing about the camera is `@Published` (publishing it would invalidate
///     every observer on every pan), so door 3 does not cover it.
///  3. **The model.** `objectWillChange` on `SceneManager`, `ToolManager` and
///     `AssetManager` — every `@Published` write in the editor, whether it came
///     from the inspector, the timeline, the hierarchy, a menu command or undo.
///     This is the catch-all, and it is what lets the other doors stay small.
///  4. **Time.** Playback and camera animation change the picture with no event
///     at all. They are the probes below, asked once a frame.
///  5. **The view.** A resize, a rotation, a split view dragged, a move to a
///     display with a different scale. These publish nothing and are nobody's
///     input; `mtkView(_:drawableSizeWillChange:)` and
///     `viewDidChangeBackingProperties` wake for them.
///
/// The residual risk is a mutation of NON-published state that no input caused
/// and no clock drove. `AssetManager.atlasPages` was exactly that, and rather
/// than argue that its rebuild always coincides with a published write, it was
/// made `@Published` so door 3 covers it by construction.
///
/// `verify_canvas_idle.py` enumerates all five doors against the source, so a
/// sixth cannot be added quietly — and models the sleep policy so that a door
/// left unwired shows up as a stale canvas rather than as nothing.
///
/// Not `@MainActor`, matching `CameraState`, which calls into it from its own
/// non-isolated mutators. Every caller is on the main thread by construction —
/// AppKit and UIKit event handlers, `draw(in:)`, and Combine sinks delivered on
/// the main queue — and nothing here touches anything a background thread owns.
final class CanvasActivity {

    /// How long the canvas keeps drawing after the last sign of activity.
    ///
    /// One frame would be enough to show a single change. The window is for
    /// SEQUENCES: a gesture that publishes as it goes, a texture that lands in
    /// pieces, a change that settles over two runloop turns. Half a second is
    /// long enough that no such sequence is ever cut off mid-way, and short
    /// enough that a hand leaving the glass stops the GPU while it still feels
    /// like the same moment.
    static let idleGrace: CFTimeInterval = 0.5

    /// The three things that change the picture and are still true between
    /// events, so a grace window alone would not catch them.
    struct Probes {
        /// A finger, Pencil or mouse button is down on the canvas.
        var isInteracting: () -> Bool = { false }
        /// The animation is running, so the pose changes with the clock.
        var isPlaying: () -> Bool = { false }
        /// The camera is flying to a framing, so the view changes with the clock.
        var isCameraAnimating: () -> Bool = { false }
    }

    var probes = Probes()

    private weak var view: MTKView?
    /// When the DISPLAY LINK last delivered a frame — not when a frame was last
    /// drawn. The two differ exactly when this matters: a hand-drawn frame must
    /// not count as evidence that the link is alive, or the first hand-drawn
    /// frame silences the guard for a frame interval and the drag runs at half
    /// rate. It measured 62fps instead of 120 before this distinction existed.
    private var lastLinkFrameTime: CFTimeInterval = 0
    /// True for the duration of a hand-drawn frame, so `settleAfterFrame` knows
    /// the frame it is ending did not come from the link.
    private var isDrawingByHand = false
    private var cancellables: [AnyCancellable] = []
    private var observed: [ObjectIdentifier] = []
    private var lastActivity: CFTimeInterval = CACurrentMediaTime()
    /// Off-screen: backgrounded on iPadOS, or a fully occluded window on macOS.
    /// Distinct from idle — an occluded canvas does not get a grace window,
    /// because there is nobody to show the last frame to.
    private var isOnScreen = true

    func attach(to view: MTKView) {
        self.view = view
        wake()
    }

    /// Door 3: every `@Published` write on the objects the renderer reads.
    ///
    /// This is the catch-all, and it is why the other doors can stay small.
    /// An inspector field, a timeline scrub, a hierarchy drag, a menu command
    /// and an undo all end in a published write on one of these, so none of
    /// them needs to know the canvas exists.
    ///
    /// Re-binding is idempotent: SwiftUI calls `updateNSView`/`updateUIView`
    /// constantly, and re-subscribing on each one would leak a subscription per
    /// layout pass.
    func observe(scene: SceneManager, tools: ToolManager, assets: AssetManager) {
        let identity = [ObjectIdentifier(scene), ObjectIdentifier(tools), ObjectIdentifier(assets)]
        guard identity != observed else { return }
        observed = identity
        cancellables = [
            scene.objectWillChange.sink { [weak self] _ in self?.wake() },
            tools.objectWillChange.sink { [weak self] _ in self?.wake() },
            assets.objectWillChange.sink { [weak self] _ in self?.wake() },
        ]
    }

    /// Something changed. Draw it on the next vsync, and keep drawing through
    /// the grace window. Cheap enough to call from `objectWillChange`.
    func wake() {
        lastActivity = CACurrentMediaTime()
        guard isOnScreen, let view, view.isPaused else { return }
        view.isPaused = false
    }

    /// Draw a frame ONLY if the display link has gone quiet.
    ///
    /// macOS runs a modal event-tracking run loop while a mouse button is down,
    /// and MTKView's display link does not deliver into it. So for the whole of
    /// a drag the canvas stops repainting: the rig follows the cursor in the
    /// model and appears frozen, then snaps to its final pose on release. That
    /// is what "rotate only moves when you let go" was. The hand-drawn frames
    /// that used to be in every mouse handler were hiding it; removing them for
    /// the iPad's sake uncovered it, and only on the Mac, because UIKit has no
    /// equivalent modal mode and its link keeps firing through a touch.
    ///
    /// The point of the guard is that this is NOT the old unconditional call
    /// coming back. When the link is healthy a frame has just happened, so this
    /// returns having done nothing, and the iPad — where the link never stalls —
    /// never draws an extra frame. It takes over only for as long as the link
    /// is not delivering, which is exactly the interval that was frozen.
    ///
    /// One and a half frame intervals: long enough that a frame merely running
    /// late does not trigger a second one, short enough that a stall is caught
    /// on the first event after it starts.
    func drawIfDisplayLinkStalled() {
        guard isOnScreen, let view, !view.isPaused else { return }
        let fps = Double(max(view.preferredFramesPerSecond, 30))
        guard CACurrentMediaTime() - lastLinkFrameTime > (1.5 / fps) else { return }
        isDrawingByHand = true
        view.draw()
        isDrawingByHand = false
    }

    /// The window was occluded or the app was backgrounded.
    func setOnScreen(_ onScreen: Bool) {
        guard onScreen != isOnScreen else { return }
        isOnScreen = onScreen
        if onScreen {
            wake()
        } else {
            view?.isPaused = true
        }
    }

    /// Called at the end of every frame — the only place the canvas is ever put
    /// to sleep, so a sleeping canvas has always drawn at least one frame of
    /// whatever it is about to stop drawing.
    func settleAfterFrame() {
        if !isDrawingByHand { lastLinkFrameTime = CACurrentMediaTime() }
        guard let view, isOnScreen else { return }
        if probes.isInteracting() || probes.isPlaying() || probes.isCameraAnimating() {
            lastActivity = CACurrentMediaTime()
            return
        }
        if CACurrentMediaTime() - lastActivity > Self.idleGrace {
            view.isPaused = true
        }
    }
}
