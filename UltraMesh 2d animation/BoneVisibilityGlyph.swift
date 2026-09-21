import SwiftUI

/// The Show / Hide Bones button's mark: the project's own bone, with an eye
/// badged on it.
///
/// It was `Image(systemName: "eye.fill")` and `"eye.slash.fill"` — a stock
/// symbol, in a strip where the hierarchy's bones, sprites and meshes are all
/// shapes this project draws itself. It also showed no bone, so the only thing
/// saying what it hid was where it sat.
///
/// The eye is a LENS: two circular arcs meeting at two points. Given the box it
/// must span, the arc's radius and centre are forced — `r = (w² + h²) / 2h` —
/// so the shape closes exactly rather than being four hand-placed control
/// points that nearly meet.
///
/// It CLOSES when bones are hidden. It is not struck through: a diagonal across
/// an icon is the system idiom this was asked to stop looking like. Closing
/// changes two things at once — the lid flattens and the pupil goes — because
/// one signal at twenty points is a coin flip.
struct BoneVisibilityGlyphShape: Shape {

    /// Whether bones are shown. Drives the lid and the pupil together.
    var isOpen: Bool = true

    /// Grows every part by the same amount, for the contour pass. Same trick
    /// as `BoneGlyphShape`: draw it once fat and dark, once at rest on top.
    var outset: CGFloat = 0

    // The lens, in units of the box.
    static let eyeHalfWidth: CGFloat = 0.166
    static let eyeHalfHeight: CGFloat = 0.112
    static let pupilRadius: CGFloat = 0.055
    /// Thick enough to clear a device pixel in the 17pt frame the button
    /// gives it. At 0.050 it measured three quarters of a pixel at 1x, which
    /// is the smudge `BoneGlyph` warns about in its own contour.
    static let eyeStroke: CGFloat = 0.066
    /// Off the middle, so the bone and the eye read as two things rather than
    /// smearing into one blob.
    static let eyeCentreX: CGFloat = 0.150
    static let eyeCentreY: CGFloat = 0.185

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        func place(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: centre.x + x * side, y: centre.y + y * side)
        }

        var path = Path()

        // The bone, smaller than usual and pushed up-left, so the badge has a
        // corner to sit in.
        let boneSide = side * 0.80
        let boneRect = CGRect(
            x: centre.x - boneSide * 0.5 - side * 0.085,
            y: centre.y - boneSide * 0.5 - side * 0.085,
            width: boneSide, height: boneSide
        )
        path.addPath(BoneGlyphShape(outset: outset).path(in: boneRect))

        // The eye.
        let w = Self.eyeHalfWidth + outset
        let h = Self.eyeHalfHeight + outset
        let stroke = Self.eyeStroke + outset * 2
        let cx = Self.eyeCentreX
        let cy = Self.eyeCentreY

        if isOpen {
            // Two arcs through (±w, 0) and (0, ∓h), as one closed outline, and
            // the same outline shrunk to leave a ring of `stroke`.
            path.addPath(Self.lens(halfWidth: w, halfHeight: h,
                                   centreX: cx, centreY: cy, place: place))
            let innerWidth = max(w - stroke, w * 0.05)
            let innerHeight = max(h - stroke, h * 0.05)
            path.addPath(Self.lens(halfWidth: innerWidth, halfHeight: innerHeight,
                                   centreX: cx, centreY: cy, place: place)
                            .reversedForEvenOdd())
            // The pupil, which the lid takes away when it closes.
            let r = Self.pupilRadius + outset
            path.addEllipse(in: CGRect(x: place(cx - r, cy - r).x,
                                       y: place(cx - r, cy - r).y,
                                       width: r * 2 * side, height: r * 2 * side))
        } else {
            // Closed: the lower lid alone, a shallow bow. No pupil.
            let lid = Self.lens(halfWidth: w, halfHeight: h * 0.42,
                                centreX: cx, centreY: cy + h * 0.30, place: place)
            let inner = Self.lens(halfWidth: max(w - stroke, w * 0.05),
                                  halfHeight: max(h * 0.42 - stroke, h * 0.04),
                                  centreX: cx, centreY: cy + h * 0.30, place: place)
            path.addPath(lid)
            path.addPath(inner.reversedForEvenOdd())
        }
        return path
    }

    /// A lens: the upper arc and the lower arc, closed.
    ///
    /// The radius is not a free choice. An arc through (±w, 0) and (0, h) has
    /// r = (w² + h²) / 2h, centred at (0, -(r - h)). Anything else does not
    /// pass through its own corners.
    private static func lens(halfWidth w: CGFloat,
                             halfHeight h: CGFloat,
                             centreX cx: CGFloat,
                             centreY cy: CGFloat,
                             place: (CGFloat, CGFloat) -> CGPoint) -> Path {
        var path = Path()
        guard w > 0, h > 0 else { return path }
        let r = (w * w + h * h) / (2 * h)
        let d = r - h
        let half = asin(min(1, w / r))

        // Upper arc, left corner to right corner, bowing to (0, -h) in view
        // coordinates where y grows downward.
        path.move(to: place(cx - w, cy))
        let steps = 24
        for step in 1...steps {
            let t = -half + 2 * half * CGFloat(step) / CGFloat(steps)
            path.addLine(to: place(cx + r * sin(t), cy + d - r * cos(t)))
        }
        // Lower arc back, mirrored.
        for step in 1...steps {
            let t = half - 2 * half * CGFloat(step) / CGFloat(steps)
            path.addLine(to: place(cx + r * sin(t), cy - d + r * cos(t)))
        }
        path.closeSubpath()
        return path
    }
}

private extension Path {
    /// The same outline, wound the other way, so filling the pair with the
    /// non-zero rule leaves a ring rather than a solid.
    func reversedForEvenOdd() -> Path {
        var points: [CGPoint] = []
        forEach { element in
            switch element {
            case .move(let to): points.append(to)
            case .line(let to): points.append(to)
            case .quadCurve(_, let to): points.append(to)
            case .curve(_, _, let to): points.append(to)
            case .closeSubpath: break
            }
        }
        var reversed = Path()
        guard let first = points.last else { return reversed }
        reversed.move(to: first)
        for point in points.dropLast().reversed() {
            reversed.addLine(to: point)
        }
        reversed.closeSubpath()
        return reversed
    }
}

/// The mark as the button draws it: a contour pass under a body pass, the same
/// two-pass build `BoneGlyph` uses.
struct BoneVisibilityGlyph: View {
    var isOpen: Bool
    var tint: Color
    var contour: Color
    /// Contour thickness as a fraction of the box, matching `BoneGlyph`'s.
    var weight: CGFloat = 0.048

    var body: some View {
        ZStack {
            BoneVisibilityGlyphShape(isOpen: isOpen, outset: weight)
                .fill(contour, style: FillStyle(eoFill: false))
            BoneVisibilityGlyphShape(isOpen: isOpen)
                .fill(tint, style: FillStyle(eoFill: false))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
