import SwiftUI

/// The measurements both inspector panels are drawn to.
///
/// The Mesh and Weights drawings are the same render at the same size, so they
/// are the same panel with different controls in it — and they have to come out
/// the same size on screen. They did not: each panel carried its own `Metrics`
/// with its own content width (528 against 244) and its own numbers, so the two
/// sat side by side in the inspector with different type sizes, different pill
/// heights and different corner radii. Two measurement systems for one drawn
/// panel is the same mistake as two constants for one drawn colour.
///
/// Every number is the drawing's own measurement over its content width, so the
/// COMPOSITION holds at whatever width the inspector gives the panel. Only the
/// three at the bottom belong to one panel each; the rest are shared, and a
/// change to any of them moves both panels together, which is the point.
struct InspectorMetrics {
    /// Card width minus its padding, in the drawing's pixels.
    static let mockContent: CGFloat = 244
    /// Below this the drawing's 11px label falls under 9pt and stops being
    /// readable, so the composition stops shrinking and `minimumScaleFactor`
    /// takes over. The inspector's narrowest column is 220pt.
    static let minimumUnit: CGFloat = 0.82
    /// What a panel assumes before it has measured itself. The inspector column
    /// is 220-320pt, so the first pass is close and settles in one step.
    static let defaultWidth: CGFloat = 268

    let width: CGFloat

    /// One drawing pixel, in points.
    var unit: CGFloat {
        max(max(width - 2 * cardPadding, 1) / Self.mockContent, Self.minimumUnit)
    }

    var cardPadding: CGFloat { max(width * 0.045, 8) }
    var corner: CGFloat { unit * 13 }

    var headingSize: CGFloat { unit * 9 }
    var labelSize: CGFloat { unit * 11 }
    var buttonSize: CGFloat { unit * 10.5 }
    var pillHeight: CGFloat { unit * 26 }
    /// Taller than the drawing's 21, at the author's request: Add / Modify /
    /// Eliminate are the mode switch for the whole panel and were the smallest
    /// thing in it. `segmentSize` goes with it — the type in a taller pill has
    /// to grow too or the button only gets emptier.
    var segmentHeight: CGFloat { unit * 28 }
    var segmentSize: CGFloat { unit * 12 }
    var track: CGFloat { unit * 13 }
    var knob: CGFloat { unit * 13 }
    var check: CGFloat { unit * 14 }
    var gap: CGFloat { unit * 6 }
    var rowGap: CGFloat { unit * 10 }
    var sectionGap: CGFloat { unit * 12 }

    // MARK: - Weights only

    var listHeight: CGFloat { unit * 203 }
    var boneDot: CGFloat { unit * 15 }

    // MARK: - Mesh only

    /// The checkbox block is deliberately airy: the two rows sit about two
    /// checkbox-heights apart, not one.
    var checkRowGap: CGFloat { unit * 38 }
    /// Between the tick and its word, and between the two columns. The block
    /// used to be inset 20px each side as well, which is what pushed "Show
    /// deformed" past the end of its column and truncated it.
    var checkGap: CGFloat { unit * 8 }
    /// The vertex count sits at the foot of the card, and keeps at least this
    /// much clear of the block above it when there is no room to spare.
    var footerGap: CGFloat { unit * 18 }
}
