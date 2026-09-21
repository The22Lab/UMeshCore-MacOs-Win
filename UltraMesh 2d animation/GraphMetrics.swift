import CoreGraphics

/// What the graph editor draws, and what it lets you grab.
///
/// They are deliberately different numbers. A keyframe drawn at eleven points
/// is small and quiet on a dense curve; eleven points is also a target you have
/// to aim at. Separating the two is what lets the drawing stay elegant while
/// the interaction stays forgiving — the same split `MoveGizmoMetrics` makes
/// for the canvas gizmo, for the same reason.
///
/// PRIORITY, stated here because it is a property of these numbers and not of
/// whichever view happens to be drawn last: a handle beats a keyframe, a
/// keyframe beats the curve. The grab sizes are ordered to match, so the
/// z-order and the tolerances agree instead of quietly contradicting each
/// other — before this, a handle's 20 points sat under a keyframe's 22, and
/// only the drawing order saved it.
enum GraphMetrics {

    // MARK: - Drawn

    /// The diamond on the curve.
    static let keyframeVisualPx: CGFloat = 11
    /// A Bézier handle's dot.
    static let handleVisualPx: CGFloat = 9
    /// The curve itself.
    static let curveVisualPx: CGFloat = 1.8

    // MARK: - Grabbed

#if os(iOS)
    /// A finger is not a mouse, and a Pencil tip is not a cursor.
    ///
    /// The same tolerance on both platforms is what makes one of them feel
    /// imprecise: on the Mac 22 points is generous, on an iPad it is the width
    /// of the contact patch. Scaled, not redefined, so the ORDER below cannot
    /// come apart between platforms.
    static let touchScale: CGFloat = 1.6
#else
    static let touchScale: CGFloat = 1.0
#endif

    /// A handle, biggest, because it is the smallest thing drawn and the one an
    /// animator reaches for most.
    static var handleGrabPx: CGFloat { 26 * touchScale }
    /// A keyframe, under it.
    static var keyframeGrabPx: CGFloat { 22 * touchScale }
    /// The curve, under both — it is an area, not a point, so it needs least.
    static var curveGrabPx: CGFloat { 14 * touchScale }

    /// The order the tolerances are in, as a fact rather than a hope.
    ///
    /// Read by `verify_curve_authority.py`. If someone raises the keyframe's
    /// tolerance past a handle's, a handle sitting on top of its own keyframe
    /// becomes ungrabbable — which is the failure the artist reports as "I know
    /// where it is and I cannot pick it up".
    static var respectsPriority: Bool {
        handleGrabPx > keyframeGrabPx && keyframeGrabPx > curveGrabPx
    }
}
