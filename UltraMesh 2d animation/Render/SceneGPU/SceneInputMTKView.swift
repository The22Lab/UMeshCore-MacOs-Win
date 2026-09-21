#if os(macOS)
import AppKit
import MetalKit

/// The Scene canvas's trackpad, on macOS.
///
/// ## Why this exists at all
///
/// iPadOS gets every navigation gesture through `SceneInputSurface`, which owns
/// the touches and hands them out. macOS had nothing equivalent: SwiftUI has no
/// scroll-wheel gesture, so a two-finger drag on the trackpad — the one gesture
/// an artist reaches for first — did nothing at all in Scene, while the rig
/// canvas next door has had it since `ToolInputMTKView.scrollWheel`.
///
/// ## And why it also fixes the freeze
///
/// `CanvasActivity.drawIfDisplayLinkStalled` documents the fault in as many
/// words: on macOS a continuous gesture runs the run loop in a modal tracking
/// mode, the display link stops delivering, and the picture stops with it until
/// the hand lets go — "rotate only moves when you let go". UIKit has no
/// equivalent mode, which is why the same build is smooth on an iPad and frozen
/// on a Mac.
///
/// The rig canvas already solved it by drawing by hand for exactly as long as
/// the link is stalled. Scene could not, because its view was paused and
/// redrawn on demand and so had no link to stall — it depended on AppKit
/// getting round to a `needsDisplay`, which during tracking it does not. Now it
/// is display-link driven like the rig canvas, and every event here nudges it.
final class SceneInputMTKView: MTKView {

    /// Two-finger drag, in view points. Orbits or pans, as the mode decides.
    var onPan: ((CGPoint) -> Void)?
    /// Scroll-wheel notches, for a mouse rather than a trackpad.
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    /// Pinch magnification, as a multiplier around a point.
    var onPinch: ((CGFloat, CGPoint) -> Void)?
    /// Set while a gesture is in progress, so the canvas is not put to sleep
    /// between two events of the same drag.
    var onInteractingChanged: ((Bool) -> Void)?

    weak var activity: CanvasActivity?

    override var acceptsFirstResponder: Bool { true }

    /// Window coordinates to this view's, Y DOWN.
    ///
    /// `NSView` is y-up from its bottom-left and every other coordinate in this
    /// app is y-down from the top — SwiftUI's, `fittedRect`'s, `viewPoint`'s,
    /// the quads'. Handing out AppKit's convention would put a pinch's anchor
    /// as far from the pointer as the pointer is from the middle, mirrored, and
    /// that reads as the zoom drifting rather than as a flipped axis.
    private func viewPoint(_ locationInWindow: NSPoint) -> CGPoint {
        let local = convert(locationInWindow, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

    override func scrollWheel(with event: NSEvent) {
        let location = viewPoint(event.locationInWindow)

        // A TRACKPAD OR A MOUSE, told apart the way the rig canvas tells them
        // apart. Precise deltas or a gesture phase mean fingers on glass, and
        // fingers pan; a notched wheel has no phase and zooms.
        if event.phase != [] || event.momentumPhase != [] || event.hasPreciseScrollingDeltas {
            // Y inverted so the content follows the fingers, which is what the
            // iPad does and what every compositor does.
            onPan?(CGPoint(x: event.scrollingDeltaX, y: -event.scrollingDeltaY))
            // The gesture's own phases bracket the interaction; momentum keeps
            // it awake while the content is still gliding.
            if event.phase.contains(.began) { onInteractingChanged?(true) }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled)
                || event.momentumPhase.contains(.ended) {
                onInteractingChanged?(false)
            }
        } else {
            onZoom?(event.scrollingDeltaY, location)
        }
        activity?.drawIfDisplayLinkStalled()
    }

    override func magnify(with event: NSEvent) {
        // `magnification` is a DELTA around zero, not a scale, so it becomes
        // one here rather than at the other end where it would be mistaken for
        // an absolute zoom.
        onPinch?(1 + event.magnification, viewPoint(event.locationInWindow))
        if event.phase.contains(.began) { onInteractingChanged?(true) }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            onInteractingChanged?(false)
        }
        activity?.drawIfDisplayLinkStalled()
    }
}
#endif
