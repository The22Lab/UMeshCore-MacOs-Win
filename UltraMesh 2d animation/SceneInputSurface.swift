#if os(iOS)
import SwiftUI
import UIKit

/// Scene's touch layer, with the canvas's law.
///
/// The viewport used to be driven by SwiftUI gestures, which cannot tell a
/// finger from a Pencil. So the rule the canvas has enforced since the finger
/// button was added — a finger navigates, the Pencil works — did not exist in
/// Scene at all: every Pencil drag orbited the set, and the button in the mode
/// switch governed the canvas and nothing else.
///
/// The recognisers here are configured exactly as `TouchInputMTKView`'s are,
/// off the same preference, so a habit learned in Editor is the habit that
/// works in Scene:
///
///   * pan and pinch accept `.direct` touches only — a Pencil never reaches
///     them, whatever it is doing;
///   * one finger pans when the button is on, two when it is not;
///   * everything else is delivered as TOOL input, with its touch type, and the
///     viewport decides what it lands on.
struct SceneInputSurface: UIViewRepresentable {

    var fingerNavigationOnly: Bool

    /// Screen points, in this view's coordinate space.
    var onNavigate: (_ translation: CGPoint, _ fingers: Int, _ phase: Phase) -> Void
    var onPinch: (_ scale: CGFloat, _ anchor: CGPoint, _ phase: Phase) -> Void
    var onToolDown: (_ point: CGPoint) -> Void
    var onToolDrag: (_ point: CGPoint) -> Void
    var onToolUp: (_ point: CGPoint) -> Void
    /// A one-finger drag with the button OFF. The viewport answers whether the
    /// point is on something worth tooling; if it is not, the touch becomes
    /// navigation so the set is never unreachable.
    var claimsTouch: (_ point: CGPoint) -> Bool

    enum Phase { case began, changed, ended }

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.coordinator = context.coordinator
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.fingerNavigationOnly = fingerNavigationOnly
        view.installRecognizers()
        return view
    }

    func updateUIView(_ view: SurfaceView, context: Context) {
        context.coordinator.parent = self
        view.fingerNavigationOnly = fingerNavigationOnly
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator {
        var parent: SceneInputSurface
        init(_ parent: SceneInputSurface) { self.parent = parent }
    }

    final class SurfaceView: UIView, UIGestureRecognizerDelegate {
        var coordinator: Coordinator?
        var fingerNavigationOnly = false {
            didSet {
                guard fingerNavigationOnly != oldValue else { return }
                // Pushed down rather than read at setup: SwiftUI can change the
                // preference long after the view exists, and a recogniser
                // configured once would keep yesterday's rule.
                pan?.minimumNumberOfTouches = fingerNavigationOnly ? 1 : 2
            }
        }

        private weak var pan: UIPanGestureRecognizer?
        /// The touch driving a tool, if any. One at a time — a second finger
        /// means navigation, and the tool touch is given up rather than fought
        /// over.
        private var toolTouch: UITouch?
        private var lastPanTranslation: CGPoint = .zero

        func installRecognizers() {
            guard pan == nil else { return }

            let panRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            panRecognizer.minimumNumberOfTouches = fingerNavigationOnly ? 1 : 2
            panRecognizer.maximumNumberOfTouches = 2
            panRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            panRecognizer.delegate = self
            addGestureRecognizer(panRecognizer)
            pan = panRecognizer

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            pinch.delegate = self
            addGestureRecognizer(pinch)
        }

        // Pan and pinch run together, the way they do on the canvas: a set is
        // moved and scaled in one gesture, not two.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// A one-finger pan is refused when the button is off AND the touch
        /// landed on something the viewport wants — a handle or a card.
        /// Everywhere else it is navigation, so empty space always moves the
        /// set whatever the button says.
        override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard !fingerNavigationOnly, let panRecognizer = g as? UIPanGestureRecognizer,
                  panRecognizer.numberOfTouches <= 1 else { return true }
            let point = panRecognizer.location(in: self)
            return !(coordinator?.parent.claimsTouch(point) ?? false)
        }

        @objc private func handlePan(_ g: UIPanGestureRecognizer) {
            let translation = g.translation(in: self)
            let phase: Phase
            switch g.state {
            case .began:
                phase = .began
                lastPanTranslation = .zero
                // A navigation gesture has started, so any tool touch in flight
                // is closed out rather than left half-done underneath it.
                if let touch = toolTouch {
                    coordinator?.parent.onToolUp(touch.location(in: self))
                    toolTouch = nil
                }
            case .changed: phase = .changed
            case .ended, .cancelled, .failed: phase = .ended
            default: return
            }
            let delta = CGPoint(x: translation.x - lastPanTranslation.x,
                                y: translation.y - lastPanTranslation.y)
            lastPanTranslation = translation
            coordinator?.parent.onNavigate(delta, g.numberOfTouches, phase)
        }

        @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
            let phase: Phase
            switch g.state {
            case .began: phase = .began
            case .changed: phase = .changed
            case .ended, .cancelled, .failed: phase = .ended
            default: return
            }
            // `center` is a point in the SUPERVIEW's space; the anchor has to
            // be in this one.
            let anchor = g.numberOfTouches >= 2
                ? g.location(in: self)
                : CGPoint(x: bounds.midX, y: bounds.midY)
            coordinator?.parent.onPinch(g.scale, anchor, phase)
            if g.state == .changed { g.scale = 1 }
        }

        // MARK: - Tool touches

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesBegan(touches, with: event)
            // The Pencil always wins a contest with a finger — the finger was a
            // palm. The canvas already works this way and the reason is the
            // same: a hand rests on the glass before the tip lands.
            let pencil = touches.first { $0.type == .pencil }
            if let pencil {
                if let existing = toolTouch, existing.type != .pencil {
                    coordinator?.parent.onToolUp(existing.location(in: self))
                }
                toolTouch = pencil
                coordinator?.parent.onToolDown(pencil.location(in: self))
                return
            }
            // A finger is a tool only when it is not navigation. With the
            // button on it never is; with it off it is, and
            // `gestureRecognizerShouldBegin` has already decided whether the pan
            // may take it instead.
            guard !fingerNavigationOnly, toolTouch == nil,
                  let touch = touches.first(where: { $0.type == .direct }) else { return }
            toolTouch = touch
            coordinator?.parent.onToolDown(touch.location(in: self))
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesMoved(touches, with: event)
            guard let touch = toolTouch, touches.contains(touch) else { return }
            coordinator?.parent.onToolDrag(touch.location(in: self))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesEnded(touches, with: event)
            finish(touches)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            super.touchesCancelled(touches, with: event)
            finish(touches)
        }

        private func finish(_ touches: Set<UITouch>) {
            guard let touch = toolTouch, touches.contains(touch) else { return }
            coordinator?.parent.onToolUp(touch.location(in: self))
            toolTouch = nil
        }
    }
}
#endif
