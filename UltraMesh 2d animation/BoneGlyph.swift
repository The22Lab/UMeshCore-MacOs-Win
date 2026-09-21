import SwiftUI

/// The dog-bone silhouette used wherever the hierarchy names a bone.
///
/// Four lobes and a shaft, built upright around the origin and then rotated, so
/// the tilt is one number rather than sixteen hand-placed coordinates. The
/// widest point from the centre is 0.496 of the box WITH the default contour
/// on, so it fits inside its frame at any angle and never needs the caller to
/// leave padding for it. Sized from the outlined variant on purpose: the solid
/// one alone fits comfortably, and checking only that is how the outlined
/// version ends up clipped at the corners — which is exactly what happened
/// when the contour was made thick enough to survive at 11 pt.
///
/// The path is a union: the subpaths overlap and are wound the same way, so
/// filling with the non-zero rule gives one silhouette with no seam where a
/// lobe meets the shaft.
struct BoneGlyphShape: Shape {
    /// Grows every part by the same amount. Drawing the shape once fat and dark
    /// and again at rest on top is how the outlined style gets a clean contour
    /// — stroking the path itself would draw the internal circle edges too,
    /// straight across the shaft.
    var outset: CGFloat = 0

    /// Degrees clockwise. Negative leans the bone the way the reference does.
    var tilt: CGFloat = -38

    private static let lobeRadius: CGFloat = 0.137
    private static let lobeOffsetX: CGFloat = 0.115
    private static let lobeOffsetY: CGFloat = 0.281
    private static let shaftHalfWidth: CGFloat = 0.145

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radians = tilt * .pi / 180

        func place(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let rx = x * cos(radians) - y * sin(radians)
            let ry = x * sin(radians) + y * cos(radians)
            return CGPoint(x: centre.x + rx * side, y: centre.y + ry * side)
        }

        var path = Path()

        let r = (Self.lobeRadius + outset) * side
        for (dx, dy) in [(-Self.lobeOffsetX, -Self.lobeOffsetY),
                         (Self.lobeOffsetX, -Self.lobeOffsetY),
                         (-Self.lobeOffsetX, Self.lobeOffsetY),
                         (Self.lobeOffsetX, Self.lobeOffsetY)] {
            let c = place(dx, dy)
            path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }

        let w = Self.shaftHalfWidth + outset
        let h = Self.lobeOffsetY
        path.move(to: place(-w, -h))
        path.addLine(to: place(w, -h))
        path.addLine(to: place(w, h))
        path.addLine(to: place(-w, h))
        path.closeSubpath()

        return path
    }
}

/// The bone as an icon.
///
/// `.solid` is a single tinted silhouette, which is what survives at the 7–9 pt
/// the hierarchy draws it at — an outline and a fill at that size turn to mud.
/// `.outlined` is the two-tone version for anywhere it is shown large.
struct BoneGlyph: View {
    enum Style {
        /// One tinted silhouette.
        case solid
        /// A body with a contour around it.
        case outlined
    }

    var style: Style = .outlined
    var tint: Color = UM.boneAccent
    var fill: Color = UM.boneGlyphFill
    var border: Color = UM.boneGlyphBorder

    /// The colour weight paint gave this bone, if anything is bound to it.
    ///
    /// A bound bone wears it: the contour in that hue, and the body the same
    /// hue at low intensity so it glows rather than shouts. An unbound bone
    /// keeps the plain glyph, which is what makes the colour mean something.
    var boneColor: SIMD4<Float>?

    /// The panel is a little darker than the canvas, so the canvas's 0.26
    /// target lands at 2.90:1 here. 0.22 clears 3:1 at every hue.
    private static let contourLuminance: Float = 0.22

    private var resolvedBorder: Color {
        guard let boneColor else { return border }
        let ink = UM.contourInk(
            for: SIMD3<Float>(boneColor.x, boneColor.y, boneColor.z),
            targetLuminance: Self.contourLuminance
        )
        return Color(red: Double(ink.x), green: Double(ink.y), blue: Double(ink.z))
    }

    private var resolvedFill: Color {
        guard let boneColor else { return fill }
        return Color(red: Double(boneColor.x),
                     green: Double(boneColor.y),
                     blue: Double(boneColor.z))
            .opacity(0.22)
    }
    /// Contour thickness, as a fraction of the box. Measured at the sizes the
    /// hierarchy uses: below about 0.05 the contour falls under a pixel and the
    /// glyph reads as a pale smudge.
    var weight: CGFloat = 0.055
    var tilt: CGFloat = -38

    var body: some View {
        switch style {
        case .solid:
            BoneGlyphShape(tilt: tilt)
                .fill(tint, style: FillStyle(eoFill: false))
        case .outlined:
            ZStack {
                BoneGlyphShape(outset: weight, tilt: tilt)
                    .fill(resolvedBorder, style: FillStyle(eoFill: false))
                // White under the tint, so the body is the hue over paper
                // rather than the hue over whatever row stripe it lands on.
                BoneGlyphShape(tilt: tilt)
                    .fill(UM.boneGlyphFill, style: FillStyle(eoFill: false))
                BoneGlyphShape(tilt: tilt)
                    .fill(resolvedFill, style: FillStyle(eoFill: false))
            }
        }
    }
}
