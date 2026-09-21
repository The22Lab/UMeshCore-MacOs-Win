import MetalKit
import SwiftUI

/// The Scene canvas, presented straight from the texture the GPU drew into.
///
/// ## What this replaces
///
/// A `CGImage` built on the main thread inside SwiftUI's `body` and handed to
/// `Image(decorative:)`. That worked, and its cost was the whole reason for the
/// move: three fixed passes over every pixel plus one per layer plus three more
/// per LIT layer, on one core, competing with SwiftUI for the same thread.
///
/// ## Display-link driven, and asleep when nothing is happening
///
/// This was `isPaused` with `enableSetNeedsDisplay` — redraw on demand, which
/// looked like the frugal choice and was the wrong one. On macOS a continuous
/// gesture runs the run loop in a modal tracking mode; AppKit does not get
/// round to a `needsDisplay` until the hand lets go, so the canvas and the
/// camera preview froze for the length of every drag and then jumped to the
/// end. iPadOS has no equivalent mode, so the same build was perfect there and
/// broken on the Mac — which is exactly how it was reported.
///
/// `CanvasActivity` already carries that scar for the rig canvas, in its own
/// words: "rotate only moves when you let go ... and only on the Mac, because
/// UIKit has no equivalent modal mode". So this view now works the way that one
/// does — the link drives it, `CanvasActivity` decides when it may stop, and
/// `SceneInputMTKView` draws by hand for exactly as long as the link is
/// stalled. Being paused was never the cheap option; it was the broken one.
///
/// ## The drawable size is NOT the view's size
///
/// `autoResizeDrawable` is off and the size comes from the caller, because the
/// adaptive resolution ladder deliberately renders BELOW native while the
/// artist is dragging and climbs back when they stop. Letting MTKView size the
/// drawable to the view would quietly undo the ladder — the one thing that
/// keeps a heavy scene interactive.
struct SceneMetalView {
    let renderer: SceneMetalRenderer
    let scene: SceneManager
    let assets: AssetManager
    let composition: SceneComposition
    let frameIndex: Int
    let frame: SceneMetalRenderer.Frame

    /// Trackpad navigation, macOS only. iPadOS routes the same gestures through
    /// `SceneInputSurface`, which owns the touches; these end in the SAME
    /// `navigate` and `pinch` the touch path calls, so the two platforms cannot
    /// drift into different camera behaviour.
    var onPan: ((CGPoint) -> Void)? = nil
    var onZoom: ((CGFloat, CGPoint) -> Void)? = nil
    var onPinch: ((CGFloat, CGPoint) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(renderer: renderer) }

    final class Coordinator: NSObject, MTKViewDelegate {
        /// Everything one frame needs, handed over whole.
        ///
        /// A struct rather than a set of properties so a draw cannot ever see
        /// half of an update — the composition from this pass and the camera
        /// from the last one is a frame nothing in the app ever asked for.
        struct Request {
            var composition: SceneComposition
            var frameIndex: Int
            var frame: SceneMetalRenderer.Frame
            var scene: SceneManager
            var assets: AssetManager
        }

        let renderer: SceneMetalRenderer
        var request: Request?
        /// Owned here because `SceneMetalView` is a struct SwiftUI rebuilds on
        /// every layout pass, and the canvas's idle state has to outlive that.
        let activity = CanvasActivity()
        /// True between the phases of one trackpad gesture, so the canvas is
        /// not put to sleep in the gap between two of its events.
        var isInteracting = false

        init(renderer: SceneMetalRenderer) {
            self.renderer = renderer
            super.init()
            activity.probes.isInteracting = { [weak self] in self?.isInteracting ?? false }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Nothing to rebuild: the renderer sizes its own accumulation
            // texture from the frame it is given, and the drawable is set by
            // the caller rather than by the view resizing itself.
        }

        func draw(in view: MTKView) {
            // SETTLED AT THE END, ON EVERY PATH, so a canvas that is about to
            // sleep has always drawn at least one frame of whatever it is going
            // to stop drawing.
            defer { activity.settleAfterFrame() }
            // THE DRAWABLE LAST, after everything that could fail. Acquiring it
            // first and then returning early holds a drawable out of the pool
            // for a whole refresh, which is a stutter the rig canvas already
            // learned to avoid.
            guard let request else { return }
            guard let drawable = view.currentDrawable else { return }
            renderer.render(composition: request.composition,
                            atFrame: request.frameIndex,
                            frame: request.frame,
                            scene: request.scene,
                            assets: request.assets,
                            into: drawable.texture,
                            presenting: drawable)
        }
    }

    // MARK: - Shared bridge (identical on macOS and iPadOS)

    private func configure(_ view: MTKView, coordinator: Coordinator) {
        // THE SHARED DEVICE. `AssetManager` builds its atlas pages on it, and a
        // texture cannot be bound from a different device.
        view.device = MetalDeviceProvider.device
        view.delegate = coordinator
        view.colorPixelFormat = .bgra8Unorm
        // The renderer builds its own render pass descriptor and writes the
        // drawable as a colour attachment, so nothing here reads it back.
        view.framebufferOnly = true
        // Starts free-running. `CanvasActivity` is the only thing that ever
        // pauses it and the only thing that ever un-pauses it, so there is one
        // owner of this bit rather than a flag several places race to set.
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = false
        coordinator.activity.attach(to: view)
    }

    private func apply(_ view: MTKView, coordinator: Coordinator) {
        coordinator.request = Coordinator.Request(
            composition: composition, frameIndex: frameIndex, frame: frame,
            scene: scene, assets: assets)
        let size = CGSize(width: max(frame.pixelSize.x, 1),
                          height: max(frame.pixelSize.y, 1))
        if view.drawableSize != size { view.drawableSize = size }
        // SwiftUI only re-runs this when something the picture depends on
        // changed, so it is the one door the canvas needs besides its own
        // input: an inspector edit, a timeline scrub, a menu command and an
        // undo all arrive here.
        coordinator.activity.wake()

        // AND THE ONE PLACE THE STALLED LINK IS NUDGED FROM.
        //
        // This lived only in `SceneInputMTKView`'s trackpad handlers, and that
        // was two mistakes in one. The mouse drag goes through SwiftUI's own
        // gesture on the enclosing stack and never touches this view, so that
        // path had no hook at all; and the view was `allowsHitTesting(false)`,
        // so it received no events and the handlers it did have never ran. The
        // canvas froze for the length of every camera move while the card
        // outlines — drawn from SwiftUI, off the same `body` that calls this —
        // followed perfectly. That contrast is what identified it.
        //
        // Here it covers every path at once, because everything that can change
        // the picture ends in a SwiftUI update: mouse, trackpad, zoom,
        // playback, the inspector, undo. And the camera preview, which has no
        // input view of its own and so could never have been nudged.
        //
        // NOT an unconditional draw wearing a disguise. `drawIfDisplayLinkStalled`
        // returns having done nothing when the link has just delivered a frame,
        // so iPadOS — where it never stalls — draws not one frame extra. It
        // takes over for exactly the interval that was frozen.
        coordinator.activity.drawIfDisplayLinkStalled()
    }
}

#if os(macOS)
extension SceneMetalView: NSViewRepresentable {
    func makeNSView(context: Context) -> MTKView {
        let view = SceneInputMTKView()
        configure(view, coordinator: context.coordinator)
        bind(view, coordinator: context.coordinator)
        apply(view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        if let input = nsView as? SceneInputMTKView {
            bind(input, coordinator: context.coordinator)
        }
        apply(nsView, coordinator: context.coordinator)
    }

    /// Re-bound on every update because the closures capture this frame's
    /// state, and a stale one would navigate the camera the artist had two
    /// layout passes ago.
    private func bind(_ view: SceneInputMTKView, coordinator: Coordinator) {
        view.activity = coordinator.activity
        view.onPan = onPan
        view.onZoom = onZoom
        view.onPinch = onPinch
        view.onInteractingChanged = { [weak coordinator] interacting in
            coordinator?.isInteracting = interacting
            coordinator?.activity.wake()
        }
    }
}
#else
extension SceneMetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        configure(view, coordinator: context.coordinator)
        apply(view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        apply(uiView, coordinator: context.coordinator)
    }
}
#endif
