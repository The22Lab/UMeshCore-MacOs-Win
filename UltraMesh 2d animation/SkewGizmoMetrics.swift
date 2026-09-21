import Foundation

/// Every size the shear gizmo is drawn and grabbed at.
///
/// A FIXED track radius, which is the whole point of this type. The radius
/// used to come from `skewGizmoOuterRadiusPixels`, which measured the sprite's
/// TRANSFORMED corners — so shearing the sprite moved its corners, which
/// changed the radius, which redrew the gizmo bigger, on every frame of the
/// drag. `lockedSkewGizmoRadius` was meant to freeze it and never did: it
/// ignored the cache it was handed and called `compute()` straight through.
/// That was the "animation".
///
/// Device pixels, before the camera zoom divides them.
enum SkewGizmoMetrics {

    /// Where the two arcs sit.
    static let trackRadiusPx: Float = 62.0
    /// Their weight.
    static let arcWidthPx: Float = 4.0
    /// The dot at the end of an arc, which is what the artist aims at.
    static let handleRadiusPx: Float = 5.5
    /// The quiet ring the arcs are read against, so zero is visible.
    static let guideWidthPx: Float = 1.6

    /// The arcs sweep from their axis out to the shear angle. Past this they
    /// would wrap and stop meaning anything, so the drawing clamps — the value
    /// does not.
    static let maxSweepDegrees: Float = 89.0

    /// Enough that a 62px arc shows no flat side at 2x.
    static let arcSegments = 96

    /// How far either side of the track a click still finds an arc.
    static let grabTolerancePx: Float = 14.0

    static func grabsTrack(distancePx: Float, hitScale: Float) -> Bool {
        abs(distancePx - trackRadiusPx) <= grabTolerancePx * hitScale
    }
}
