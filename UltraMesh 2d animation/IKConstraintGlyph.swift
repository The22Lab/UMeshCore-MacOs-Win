import SwiftUI

/// The mark an IK constraint wears: a two-bone chain.
///
/// Root joint, elbow, tip — drawn literally, as the reference does. Each bone
/// is a teardrop: a round joint at one end, tapering to a point at the other,
/// with a white dot marking the joint. The first bone's point lands ON the
/// elbow, which is the second bone's joint, so the two meet at one shared
/// point. Two darts that merely pass near each other are two darts, not a
/// chain, and that is the one thing this mark cannot get wrong.
///
/// The reference also carries three arrows along each bone and the letters IK
/// behind them. Neither survives at the size a hierarchy row gives an icon —
/// about fourteen points — so neither is drawn. What is kept is what still
/// reads there: two tapered bones, two joints, the bend, the two colours.
struct IKConstraintGlyphShape: Shape {

    /// Which half to draw. The two are separate shapes because they are two
    /// colours; the geometry that positions them is shared and stated once.
    enum Segment {
        case upper
        case lower
    }

    var segment: Segment = .upper

    /// Grows every part by the same amount, for the contour pass — the same
    /// two-pass build `BoneGlyphShape` uses.
    var outset: CGFloat = 0

    // The chain, in units of the box. y grows downward, as in view space.
    /// Chosen so the furthest point of the whole mark — a joint's rim plus
    /// the contour, or the far tip — lands at 0.497 of the box. `BoneGlyph`
    /// keeps 0.496 by the same reckoning, which is what lets both sit in a
    /// hierarchy row with no padding reserved for them.
    static let rootJoint = CGPoint(x: -0.265, y: -0.170)
    static let elbow = CGPoint(x: -0.015, y: 0.325)
    static let tip = CGPoint(x: 0.310, y: -0.315)
    static let rootJointRadius: CGFloat = 0.130
    static let elbowRadius: CGFloat = 0.115
    static let jointDotRadius: CGFloat = 0.050
    /// Matches `BoneGlyph`'s: below about 0.05 of the box a contour falls under
    /// a pixel and the glyph reads as a pale smudge.
    static let contourWeight: CGFloat = 0.052

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        func place(_ p: CGPoint) -> CGPoint {
            CGPoint(x: centre.x + p.x * side, y: centre.y + p.y * side)
        }

        let joint: CGPoint
        let point: CGPoint
        let radius: CGFloat
        switch segment {
        case .upper:
            joint = Self.rootJoint
            point = Self.elbow
            radius = Self.rootJointRadius + outset
        case .lower:
            joint = Self.elbow
            point = Self.tip
            radius = Self.elbowRadius + outset
        }

        // A teardrop: the half-circle behind the joint, then the two tangents
        // running forward to the point. Built from the tangent angle rather
        // than from hand-placed control points, so the sides meet the circle
        // without a kink at any length.
        var path = Path()
        let dx = point.x - joint.x
        let dy = point.y - joint.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > radius else { return path }
        let heading = atan2(dy, dx)
        // Where the tangent leaves the circle.
        let spread = acos(min(1, radius / length))

        let steps = 28
        // Round the back of the joint, from one tangent point to the other.
        let start = heading + spread
        let end = heading + (2 * .pi - spread)
        path.move(to: place(CGPoint(x: joint.x + radius * cos(start),
                                    y: joint.y + radius * sin(start))))
        for step in 1...steps {
            let t = start + (end - start) * CGFloat(step) / CGFloat(steps)
            path.addLine(to: place(CGPoint(x: joint.x + radius * cos(t),
                                           y: joint.y + radius * sin(t))))
        }
        // ...then out to the point, which the contour pass pushes forward so
        // the tip keeps its taper instead of being blunted.
        let extend = outset
        path.addLine(to: place(CGPoint(x: point.x + cos(heading) * extend,
                                       y: point.y + sin(heading) * extend)))
        path.closeSubpath()
        return path
    }
}

/// The joint dot, so it can be placed by the same numbers the bones use.
struct IKConstraintJointShape: Shape {
    var atElbow: Bool = false

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let joint = atElbow ? IKConstraintGlyphShape.elbow : IKConstraintGlyphShape.rootJoint
        let r = IKConstraintGlyphShape.jointDotRadius * side
        return Path(ellipseIn: CGRect(
            x: centre.x + joint.x * side - r,
            y: centre.y + joint.y * side - r,
            width: r * 2, height: r * 2
        ))
    }
}

/// The mark as it is drawn: a contour under both bones, the bones, the dots.
struct IKConstraintGlyph: View {
    var upper: Color = UM.ikGlyphUpper
    var lower: Color = UM.ikGlyphLower
    var contour: Color = UM.surface
    var joint: Color = .white
    /// Dimmed when the constraint is switched off, so the tree says so.
    var isEnabled: Bool = true

    var body: some View {
        let weight = IKConstraintGlyphShape.contourWeight
        ZStack {
            IKConstraintGlyphShape(segment: .upper, outset: weight).fill(contour)
            IKConstraintGlyphShape(segment: .lower, outset: weight).fill(contour)
            // The lower bone last of the two, so the elbow's joint sits on top
            // of the upper bone's point — which is what makes the two read as
            // hinged rather than crossed.
            IKConstraintGlyphShape(segment: .upper).fill(upper)
            IKConstraintGlyphShape(segment: .lower).fill(lower)
            IKConstraintJointShape().fill(joint)
            IKConstraintJointShape(atElbow: true).fill(joint)
        }
        .opacity(isEnabled ? 1.0 : 0.42)
        .aspectRatio(1, contentMode: .fit)
    }
}
