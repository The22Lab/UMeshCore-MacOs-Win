import Foundation
import QuartzCore
import Combine
import simd

final class CameraState: ObservableObject {
    var origin: CGPoint = .zero
    var zoom: CGFloat = 1.0
    var rotation: CGFloat = 0.0

    /// The canvas is allowed to sleep when nothing is happening, and moving the
    /// camera is something happening. The wake lives HERE rather than at the
    /// call sites because the call sites are not a closed set: the viewport
    /// gestures, Frame Selected from a menu, a restored project, and whatever
    /// Scene mode adds later all move the camera, and any of them that forgot
    /// to wake would leave the canvas showing the old framing.
    ///
    /// None of these are `@Published` on purpose — publishing the camera would
    /// invalidate every SwiftUI view that observes it on every pan — so the
    /// model's own `objectWillChange` door does not cover the camera. This is
    /// what covers it.
    weak var activity: CanvasActivity?

    /// True while `frame(bounds:)` is flying the camera to a new framing. The
    /// picture changes with the clock and not with any event, so the canvas
    /// cannot sleep through it; `CanvasActivity` asks this every frame.
    var isAnimating: Bool { animationStartTime != nil }

    private var lastViewSize: CGSize = .zero
    private var animationStartTime: CFTimeInterval?
    private var animationDuration: CFTimeInterval = 0.0
    private var animationStartOrigin: CGPoint = .zero
    private var animationStartZoom: CGFloat = 1.0
    private var animationTargetOrigin: CGPoint = .zero
    private var animationTargetZoom: CGFloat = 1.0

    private let minZoom: CGFloat = 0.05
    private let maxZoom: CGFloat = 20.0

    func pan(screenDelta: CGPoint) {
        activity?.wake()
        cancelAnimation()
        let worldDelta = CGPoint(x: screenDelta.x / zoom, y: screenDelta.y / zoom)
        origin.x -= worldDelta.x
        origin.y -= worldDelta.y
    }

    func zoom(at screenPoint: CGPoint, viewSize: CGSize, scrollDelta: CGFloat) {
        activity?.wake()
        cancelAnimation()
        let factor = pow(1.003, scrollDelta)
        let proposed = zoom * factor
        let clamped = min(maxZoom, max(minZoom, proposed))
        guard clamped.isFinite else { return }

        let worldBefore = screenToWorld(screenPoint, viewSize: viewSize)
        zoom = clamped
        let worldAfter = screenToWorld(screenPoint, viewSize: viewSize)
        origin.x += worldBefore.x - worldAfter.x
        origin.y += worldBefore.y - worldAfter.y
    }

    /// Applies a direct multiplicative zoom anchored at `screenPoint`.
    ///
    /// Used by touch pinch gestures: the camera zoom is multiplied by the raw
    /// gesture scale factor, so the canvas tracks the fingers exactly 1:1 with
    /// no exponential remapping, smoothing, or damping. `screenPoint` and
    /// `viewSize` must be expressed in the same units the renderer uses
    /// (drawable pixels).
    func zoomBy(scaleFactor: CGFloat, at screenPoint: CGPoint, viewSize: CGSize) {
        activity?.wake()
        cancelAnimation()
        guard scaleFactor.isFinite, scaleFactor > 0 else { return }
        let clamped = min(maxZoom, max(minZoom, zoom * scaleFactor))
        guard clamped.isFinite else { return }
        let worldBefore = screenToWorld(screenPoint, viewSize: viewSize)
        zoom = clamped
        let worldAfter = screenToWorld(screenPoint, viewSize: viewSize)
        origin.x += worldBefore.x - worldAfter.x
        origin.y += worldBefore.y - worldAfter.y
    }

    func frame(bounds: Bounds2D, viewSize: CGSize, padding: CGFloat = 40, duration: CFTimeInterval = 0.25) {
        activity?.wake()
        lastViewSize = viewSize
        let size = CGSize(width: max(CGFloat(bounds.size.x), 1.0), height: max(CGFloat(bounds.size.y), 1.0))
        let padded = CGSize(width: size.width + padding * 2, height: size.height + padding * 2)
        let zoomX = viewSize.width / max(padded.width, 1.0)
        let zoomY = viewSize.height / max(padded.height, 1.0)
        let targetZoom = min(maxZoom, max(minZoom, min(zoomX, zoomY)))
        let targetOrigin = CGPoint(x: CGFloat(bounds.center.x), y: CGFloat(bounds.center.y))

        startAnimation(to: targetOrigin, zoom: targetZoom, duration: duration)
    }

    func frame(bounds: Bounds2D, padding: CGFloat = 40, duration: CFTimeInterval = 0.25) {
        frame(bounds: bounds, viewSize: lastViewSize, padding: padding, duration: duration)
    }

    func update(deltaTime: CFTimeInterval, viewSize: CGSize) {
        lastViewSize = viewSize
        guard let startTime = animationStartTime else { return }
        let elapsed = max(0.0, CACurrentMediaTime() - startTime)
        let t = min(1.0, elapsed / max(0.0001, animationDuration))
        let eased = easeInOut(t)
        origin.x = animationStartOrigin.x + (animationTargetOrigin.x - animationStartOrigin.x) * eased
        origin.y = animationStartOrigin.y + (animationTargetOrigin.y - animationStartOrigin.y) * eased
        zoom = animationStartZoom + (animationTargetZoom - animationStartZoom) * eased
        if t >= 1.0 {
            animationStartTime = nil
        }
    }

    func screenToWorld(_ point: CGPoint, viewSize: CGSize) -> CGPoint {
        let centered = CGPoint(x: point.x - viewSize.width * 0.5, y: point.y - viewSize.height * 0.5)
        return CGPoint(x: centered.x / zoom + origin.x, y: -(centered.y / zoom) + origin.y)
    }

    func worldToScreen(_ point: CGPoint, viewSize: CGSize) -> CGPoint {
        let centered = CGPoint(x: (point.x - origin.x) * zoom, y: (point.y - origin.y) * zoom)
        return CGPoint(x: centered.x + viewSize.width * 0.5, y: -centered.y + viewSize.height * 0.5)
    }

    func screenToWorld(_ point: SIMD2<Float>, viewSize: SIMD2<Float>) -> SIMD2<Float> {
        let world = screenToWorld(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)),
                                  viewSize: CGSize(width: CGFloat(viewSize.x), height: CGFloat(viewSize.y)))
        return SIMD2<Float>(Float(world.x), Float(world.y))
    }

    func worldToScreen(_ point: SIMD2<Float>, viewSize: SIMD2<Float>) -> SIMD2<Float> {
        let screen = worldToScreen(CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)),
                                   viewSize: CGSize(width: CGFloat(viewSize.x), height: CGFloat(viewSize.y)))
        return SIMD2<Float>(Float(screen.x), Float(screen.y))
    }

    func restore(origin: CGPoint, zoom: CGFloat, rotation: CGFloat) {
        activity?.wake()
        cancelAnimation()
        self.origin = origin
        self.zoom = min(maxZoom, max(minZoom, zoom))
        self.rotation = rotation
    }

    private func startAnimation(to origin: CGPoint, zoom: CGFloat, duration: CFTimeInterval) {
        animationStartOrigin = self.origin
        animationStartZoom = self.zoom
        animationTargetOrigin = origin
        animationTargetZoom = zoom
        animationDuration = duration
        animationStartTime = CACurrentMediaTime()
    }

    private func cancelAnimation() {
        animationStartTime = nil
    }

    private func easeInOut(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }
}
