import Foundation

/// Every size the rotate gizmo is drawn and grabbed at.
///
/// The proportions are the reference drawing's, measured off it: a pivot ring
/// of radius 40.5px with a 10px stroke, a dotted track at 153.5px, and a
/// needle 45px across its base. Kept as ratios of the pivot radius rather than
/// transcribed as four numbers, so the gizmo can be resized as one object.
///
/// One place because the hit test used to carry its own `58.0` and `50.0`,
/// which corresponded to nothing in the drawing — the artist aimed at what
/// they could see and the grab band was somewhere else.
///
/// Device pixels, before the camera zoom divides them: the gizmo is chrome and
/// keeps its size on screen however far in or out the canvas is.
enum RotateGizmoMetrics {

    // MARK: - The pivot

    /// The small ring at the centre of rotation.
    static let pivotRadiusPx: Float = 13.0
    /// Its stroke. A quarter of the radius, as in the reference.
    static let pivotStrokePx: Float = 3.2
    /// The bump on the ring that marks the same angle as the needle, so the
    /// angle is still readable when the needle runs off the viewport.
    static let nubRadiusPx: Float = 2.6

    // MARK: - The track

    /// Where the dots sit. 3.79 x the pivot radius, as in the reference.
    static let trackRadiusPx: Float = 49.0
    /// A dot is as heavy as the ring's stroke — that is what makes the two
    /// read as one drawing rather than as two unrelated marks.
    static let dotRadiusPx: Float = 1.6
    /// One every 15 degrees: enough to read as a ring, and a step an artist
    /// can count in while dragging.
    static let dotCount = 24

    // MARK: - The needle

    /// It starts outside the ring, not through it.
    static let needleInnerPx: Float = 18.0
    /// And reaches well past the track.
    ///
    /// A deliberate departure from the reference, which is a hero render: its
    /// needle is 4.9x the track radius, which on a canvas would reach halfway
    /// across the viewport and cover the artwork being rotated.
    static let needleOuterPx: Float = 88.0
    /// Half the base width. 0.556 x the pivot radius, as in the reference.
    static let needleHalfWidthPx: Float = 7.2

    // MARK: - Drawing

    /// The dark outline under every part.
    ///
    /// What lets the accent stay a BRIGHT yellow. No yellow clears 3:1 against
    /// this canvas's near-white checker square — darkened until it does it is
    /// olive, not yellow — so the mark is given an edge instead of being
    /// dimmed, exactly as the mesh nodes are. Thinner than the stroke it
    /// outlines, or it stops being an outline and starts being the mark.
    static let contourPx: Float = 1.3

    /// The alpha ramp along every edge.
    ///
    /// This is the whole reason the gizmo stopped looking pixelated. The rings
    /// used to be Metal `.line` primitives: one device pixel, binary coverage,
    /// no antialiasing, so the perceived edge jumped a whole pixel at a time.
    /// A one-pixel ramp lands it within an eighth of one. Not a free
    /// parameter — thinner and the staircase comes back, thicker and it is a
    /// blur. See `verify_rotate_gizmo.py`.
    static let featherPx: Float = 1.0
    /// Enough that the pivot ring shows no flat side at 2x.
    static let ringSegments = 72
    /// ...and a dot, which is far smaller, needs far fewer.
    static let dotSegments = 14

    // MARK: - Grabbing

    /// How far either side of the track a click still means "rotate".
    static let grabTolerancePx: Float = 14.0

    /// Whether a click at `distance` from the pivot lands on the track.
    static func grabsTrack(distancePx: Float, hitScale: Float) -> Bool {
        abs(distancePx - trackRadiusPx) <= grabTolerancePx * hitScale
    }

    /// Whether a click lands on the needle itself, which is the biggest thing
    /// on screen and the obvious thing to point at.
    static func grabsNeedle(distancePx: Float,
                            angleDelta: Float,
                            hitScale: Float) -> Bool {
        guard distancePx >= needleInnerPx, distancePx <= needleOuterPx else { return false }
        // Half the base width, plus a little slop, as an angle at this radius.
        let halfWidth = needleHalfWidthPx + grabTolerancePx * 0.5 * hitScale
        return abs(angleDelta) <= atan2(halfWidth, max(distancePx, 1))
    }
}
