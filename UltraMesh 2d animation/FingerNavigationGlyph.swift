import SwiftUI

/// The finger-lock button's mark: a pointing hand, and what that hand is
/// allowed to do.
///
/// The gesture it names is the one Clip Studio Paint puts behind a finger icon.
/// With it on, a finger can only move the canvas — pan and pinch — and the
/// Apple Pencil does everything else. Off, a finger is a tool again and the
/// two-finger gestures navigate, which is how this app has always behaved.
///
/// TWO SIGNALS, NOT ONE, for the reason `BoneVisibilityGlyph` gives: at
/// seventeen points a single difference is a coin flip. Locked, the hand grows
/// a pair of horizontal arrows — it slides things — AND the button fills with
/// the accent. Unlocked, the arrows go and the fill goes.
///
/// Not a diagonal slash. A strike-through would read as "finger disabled",
/// which is the opposite of the truth: the finger is not disabled, it is
/// promoted to the only thing that navigates. The arrows say that; a slash
/// would say the button had turned touch off.
struct FingerNavigationGlyphShape: Shape {

    /// Finger restricted to navigation. Drives the arrows.
    var isLocked: Bool = false

    /// Grows every part by the same amount, for the contour pass — the same
    /// trick `BoneGlyphShape` and `BoneVisibilityGlyphShape` use.
    var outset: CGFloat = 0

    // The hand, in units of the box. A palm and one extended index finger:
    // enough to read as a pointing hand at the size this is drawn, and few
    // enough parts that it does not turn to mud.
    static let palmWidth: CGFloat = 0.38
    static let palmHeight: CGFloat = 0.30
    static let palmCentreY: CGFloat = 0.16
    static let fingerWidth: CGFloat = 0.145
    /// From the finger's rounded tip to where it meets the palm.
    static let fingerTop: CGFloat = -0.36
    static let thumbWidth: CGFloat = 0.125
    static let thumbLength: CGFloat = 0.20

    // The arrows, only drawn when locked.
    static let arrowInset: CGFloat = 0.30      // from the centre, outwards
    static let arrowReach: CGFloat = 0.46
    static let arrowStroke: CGFloat = 0.055
    static let arrowHead: CGFloat = 0.085

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        func place(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: centre.x + x * side, y: centre.y + y * side)
        }

        var path = Path()

        // Palm.
        let palmW = (Self.palmWidth + outset * 2) * side
        let palmH = (Self.palmHeight + outset * 2) * side
        path.addRoundedRect(
            in: CGRect(
                x: centre.x - palmW * 0.5,
                y: centre.y + (Self.palmCentreY * side) - palmH * 0.5,
                width: palmW, height: palmH
            ),
            cornerSize: CGSize(width: palmW * 0.34, height: palmW * 0.34)
        )

        // Index finger: a capsule from inside the palm up past the top of it,
        // so the two fuse into one silhouette instead of meeting at a seam.
        let fingerW = (Self.fingerWidth + outset * 2) * side
        let fingerTopY = centre.y + (Self.fingerTop - outset) * side
        let fingerBottomY = centre.y + (Self.palmCentreY + 0.04) * side
        path.addRoundedRect(
            in: CGRect(
                x: centre.x - fingerW * 0.5 - side * 0.045,
                y: fingerTopY,
                width: fingerW, height: fingerBottomY - fingerTopY
            ),
            cornerSize: CGSize(width: fingerW * 0.5, height: fingerW * 0.5)
        )

        // Thumb, off the left of the palm, tilted out.
        let thumbW = (Self.thumbWidth + outset * 2) * side
        let thumbL = (Self.thumbLength + outset) * side
        var thumb = Path()
        thumb.addRoundedRect(
            in: CGRect(x: -thumbW * 0.5, y: -thumbL * 0.5, width: thumbW, height: thumbL),
            cornerSize: CGSize(width: thumbW * 0.5, height: thumbW * 0.5)
        )
        let thumbAt = place(-0.20, 0.10)
        path.addPath(thumb.applying(
            CGAffineTransform(rotationAngle: -0.62)
                .concatenating(CGAffineTransform(translationX: thumbAt.x, y: thumbAt.y))
        ))

        guard isLocked else { return path }

        // Two arrows, level with the palm, saying the hand slides the canvas.
        let stroke = (Self.arrowStroke + outset) * side
        let head = (Self.arrowHead + outset * 0.5) * side
        let y = centre.y + Self.palmCentreY * side
        for direction in [CGFloat(-1), 1] {
            let inner = centre.x + direction * Self.arrowInset * side
            let outer = centre.x + direction * Self.arrowReach * side
            path.addRoundedRect(
                in: CGRect(
                    x: min(inner, outer), y: y - stroke * 0.5,
                    width: abs(outer - inner), height: stroke
                ),
                cornerSize: CGSize(width: stroke * 0.5, height: stroke * 0.5)
            )
            // A solid triangular head, pointing outwards.
            var tip = Path()
            tip.move(to: CGPoint(x: outer + direction * head * 0.55, y: y))
            tip.addLine(to: CGPoint(x: outer - direction * head * 0.45, y: y - head * 0.72))
            tip.addLine(to: CGPoint(x: outer - direction * head * 0.45, y: y + head * 0.72))
            tip.closeSubpath()
            path.addPath(tip)
        }

        return path
    }
}

struct FingerNavigationGlyph: View {
    var isLocked: Bool
    var tint: Color
    var contour: Color
    /// Contour thickness as a fraction of the box, matching the other glyphs'.
    var weight: CGFloat = 0.048

    var body: some View {
        ZStack {
            FingerNavigationGlyphShape(isLocked: isLocked, outset: weight)
                .fill(contour, style: FillStyle(eoFill: false))
            FingerNavigationGlyphShape(isLocked: isLocked)
                .fill(tint, style: FillStyle(eoFill: false))
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
