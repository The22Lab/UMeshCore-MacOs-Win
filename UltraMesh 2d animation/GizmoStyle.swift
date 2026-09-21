import Foundation

/// What every transform gizmo has in common.
///
/// Rotate was redrawn first and set the language: marks built from feathered
/// triangles, each on a near-opaque dark contour so it reads over artwork of
/// any colour, sizes stated in device pixels so the chrome keeps its size
/// however far the canvas is zoomed. Translate, Scale and Shear now read from
/// here rather than each carrying its own numbers and its own red, green and
/// blue — which is why they looked like three different tools.
enum GizmoStyle {

    /// The dark outline under every mark. Thin enough to stay an outline.
    static let contourPx: Float = 1.3

    /// The alpha ramp along every edge.
    ///
    /// Analytic antialiasing. Thinner and the staircase comes back, thicker
    /// and it is a blur; see `verify_rotate_gizmo.py`, which measures both
    /// bounds.
    static let featherPx: Float = 1.0

    /// Enough segments that a disc of gizmo size shows no flat side at 2x.
    static let discSegments = 24

    /// The ring at the centre of every gizmo — the pivot the tool acts about.
    /// The same one Rotate draws, so the four tools share a centre.
    static let pivotRadiusPx: Float = 13.0
    static let pivotStrokePx: Float = 3.2

    /// How far a click may miss a handle and still find it.
    static let grabSlopPx: Float = 6.0
}
