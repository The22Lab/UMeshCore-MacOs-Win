import SwiftUI

/// The picture mark used wherever the hierarchy names an image.
///
/// The bone's treatment, applied to sprites: a white body with a coloured
/// contour, no disc behind it, so a row says what kind of thing it is by its
/// SHAPE rather than by a symbol on a grey circle. Fuchsia rather than the
/// bone's purple — the two hues sit 48 degrees apart at the same luminance, so
/// neither glyph is the fainter one.
///
/// Built upright around the origin in fractions of the box. The widest point
/// with the default contour on is 0.480 of the box, so it fits its frame with
/// no padding asked of the caller — the same property the bone glyph has, and
/// for the same reason: it is drawn at 12 and 13 pt beside text, where a
/// clipped corner is the first thing that looks wrong.
struct ImageGlyphShape: Shape {
    /// Grows the plate by this much, in fractions of the box. The contour is
    /// the plate drawn once fat and once at rest, exactly as the bone is —
    /// stroking would put an edge around the punched features too.
    var outset: CGFloat = 0

    /// Cuts the sun and the two peaks out of the plate. Filled with the
    /// even-odd rule they become holes, and what shows through them is the
    /// contour pass underneath, so the mark inside is the contour's colour with
    /// nothing extra drawn.
    var punched: Bool = false

    static let plateHalfWidth: CGFloat = 0.425
    static let plateHalfHeight: CGFloat = 0.325
    static let plateCorner: CGFloat = 0.090

    static let sunCentre = CGPoint(x: -0.205, y: -0.150)
    static let sunRadius: CGFloat = 0.070

    /// Two peaks, and they MUST NOT overlap each other: under the even-odd rule
    /// an overlap is filled back in, which would put a solid white wedge in the
    /// middle of the mountains.
    static let bigPeak = [CGPoint(x: -0.300, y: 0.205),
                          CGPoint(x: -0.100, y: -0.070),
                          CGPoint(x: 0.100, y: 0.205)]
    static let smallPeak = [CGPoint(x: 0.120, y: 0.205),
                            CGPoint(x: 0.235, y: 0.060),
                            CGPoint(x: 0.350, y: 0.205)]

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let centre = CGPoint(x: rect.midX, y: rect.midY)

        func place(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: centre.x + x * side, y: centre.y + y * side)
        }

        var path = Path()

        let halfWidth = Self.plateHalfWidth + outset
        let halfHeight = Self.plateHalfHeight + outset
        let plate = CGRect(x: centre.x - halfWidth * side,
                           y: centre.y - halfHeight * side,
                           width: halfWidth * 2 * side,
                           height: halfHeight * 2 * side)
        path.addRoundedRect(in: plate,
                            cornerSize: CGSize(width: (Self.plateCorner + outset) * side,
                                               height: (Self.plateCorner + outset) * side),
                            style: .continuous)

        guard punched else { return path }

        let r = Self.sunRadius * side
        let sun = place(Self.sunCentre.x, Self.sunCentre.y)
        path.addEllipse(in: CGRect(x: sun.x - r, y: sun.y - r, width: r * 2, height: r * 2))

        for peak in [Self.bigPeak, Self.smallPeak] {
            path.move(to: place(peak[0].x, peak[0].y))
            path.addLine(to: place(peak[1].x, peak[1].y))
            path.addLine(to: place(peak[2].x, peak[2].y))
            path.closeSubpath()
        }

        return path
    }
}

/// The image as an icon.
///
/// Two passes: the plate grown by `weight` in the contour colour, then the
/// punched plate at rest in the body colour with the even-odd rule. The holes
/// show the pass underneath, so the sun and the peaks come out in the contour's
/// colour without being drawn a third time.
struct ImageGlyph: View {
    var fill: Color = UM.imageGlyphFill
    var border: Color = UM.imageGlyphBorder

    /// Contour thickness, as a fraction of the box. The bone's number, for the
    /// same reason: below about 0.05 the edge falls under a pixel at the sizes
    /// the hierarchy draws it and the glyph reads as a pale smudge.
    var weight: CGFloat = 0.055

    var body: some View {
        ZStack {
            ImageGlyphShape(outset: weight)
                .fill(border, style: FillStyle(eoFill: false))
            ImageGlyphShape(punched: true)
                .fill(fill, style: FillStyle(eoFill: true))
        }
    }
}
