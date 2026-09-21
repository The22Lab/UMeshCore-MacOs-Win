import Foundation

/// The move gizmo's geometry, in one place, for the drawing AND the hit test.
///
/// `RotateGizmoMetrics` exists for this reason and records it: "This used to
/// carry a 58 and a 50 of its own, which corresponded to nothing that was
/// drawn: the artist aimed at the ring they could see and the grab band was
/// eight pixels somewhere else." Translate had the same fault and it was worse,
/// because the two handles it confuses sit on top of each other.
///
/// What it was: a centre disc drawn at 16 px and grabbed at 22, multiplied on
/// iPad by `touchHitScale` — `displayScale * 1.85`, which is 5.55 on a 3x
/// screen. That is a grab radius of 122 px around a disc drawn at 16, over an
/// axis 96 long. `verify_move_gizmo_precision.py` measures the result: on a 3x
/// iPad, NONE of the X axis answered as X. All of it was the blue circle.
///
/// Device pixels, before the camera zoom divides them: the gizmo is chrome and
/// keeps its size on screen however far in or out the canvas is.
enum MoveGizmoMetrics {

    // MARK: - What is drawn

    /// The blue disc at the centre — drag both axes at once.
    static let centerRadiusPx: Float = 16.0
    /// Its darker core.
    static let centerInnerScale: Float = 0.70
    /// Where an axis starts. Outside the disc, so the drawing never puts one
    /// on top of the other.
    static var axisInnerPx: Float { centerRadiusPx * 1.03 }
    /// How far an axis reaches.
    static let axisLengthPx: Float = 96.0

    // MARK: - What is grabbed

    /// How far from a handle a press still counts, before touch scaling.
    ///
    /// This widens the axis bands ACROSS, which is what makes a thin line
    /// catchable with a finger.
    static let grabMarginPx: Float = 11.0

    /// The most of the axis the centre disc is allowed to claim.
    ///
    /// The cap is the whole point. The axis is a fixed length, so a centre
    /// whose grab radius scales with touch does not become easier to hit — it
    /// eats the axes, and at 3x it ate them entirely. Capped, the same share of
    /// the axis stays grabbable on every device: 78% measured, on a Mac and on
    /// a 3x iPad alike.
    static let centerShareOfAxis: Float = 0.22

    /// The centre's grab radius at this touch scale.
    static func centerGrabPx(hitScale: Float) -> Float {
        min(centerRadiusPx + grabMarginPx * hitScale * 0.5,
            axisLengthPx * centerShareOfAxis)
    }

    /// Where an axis band starts: outside the disc, never inside it.
    static func axisGrabInnerPx(hitScale: Float) -> Float {
        max(axisInnerPx, centerGrabPx(hitScale: hitScale))
    }

    /// Where it ends — a little past the tip, so the very end is catchable.
    static func axisGrabOuterPx(hitScale: Float) -> Float {
        axisLengthPx + grabMarginPx * hitScale
    }

    /// How far to the side of an axis a press still counts.
    static func axisGrabAcrossPx(hitScale: Float) -> Float {
        grabMarginPx * hitScale
    }
}
