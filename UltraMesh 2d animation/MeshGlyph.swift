import SwiftUI

/// The geodesic ball, wherever UltraMesh names a mesh.
///
/// The reference drawing is a frequency-3 geodesic sphere, around 500 struts.
/// HOW MUCH OF IT RENDERS IS A FUNCTION OF SIZE, and the number decides it
/// rather than a judgement. What matters is the device pixels between the two
/// closest struts on a 2x display: a strut is one pixel, so anything under
/// about 3 px of separation closes up into a smudge.
///
///     frequency   closest pair, as a fraction of the box
///        0              0.1625
///        1              0.0496
///        2              0.0190
///        3              0.0048     <- the reference
///
/// At the hierarchy's 13 pt (26 px) only frequency 0 clears it: 4.2 px against
/// frequency 1's 1.3. At the canvas button's 26 pt (52 px) frequency 1 clears
/// it at 2.6 px, and frequency 2 does not at 1.0. The reference's own density
/// would need a ball about 52 pt across before its struts separated at all.
///
/// So both lattices are the SAME construction — an icosahedron normalised onto
/// the unit sphere, front hemisphere, projected down its 2-fold axis — and each
/// surface draws the finest one its size can carry.
struct MeshGlyphShape: Shape {
    enum Part {
        /// The sphere's outline.
        case rim
        /// The lattice: struts as thin capsules.
        case struts
        /// The joints where struts meet.
        case nodes
    }

    /// How finely the sphere is divided. `coarse` is the bare icosahedron,
    /// `fine` one subdivision of it.
    enum Lattice {
        case coarse
        case fine
    }

    var lattice: Lattice = .coarse
    var part: Part

    /// The silhouette, as a fraction of the box.
    ///
    /// The fine ball is drawn LARGER, and for room rather than for looks: its
    /// beads are smaller, so it can spend on radius what the coarse one spends
    /// on them. Ball plus bead comes to 0.470 and 0.496 of the box, so both fit
    /// their frame with nothing asked of the caller — the same property the
    /// bone and image glyphs have.
    static func ballRadius(_ lattice: Lattice) -> CGFloat {
        lattice == .coarse ? 0.425 : 0.470
    }

    /// Thinner and smaller on the fine lattice: sixty struts in the same circle
    /// have a quarter of the room fifteen do.
    static func strutWidth(_ lattice: Lattice) -> CGFloat {
        lattice == .coarse ? 0.042 : 0.021
    }

    static func nodeRadius(_ lattice: Lattice) -> CGFloat {
        lattice == .coarse ? 0.045 : 0.026
    }

    static func nodes(_ lattice: Lattice) -> [CGPoint] {
        lattice == .coarse ? coarseNodes : fineNodes
    }

    static func struts(_ lattice: Lattice) -> [(Int, Int)] {
        lattice == .coarse ? coarseStruts : fineStruts
    }

    /// Which nodes are drawn as beads.
    ///
    /// All of them on the coarse ball. On the fine one only the rim: its
    /// interior joints sit 1.94 pt apart at 26 pt, so a bead big enough to see
    /// would be a bead big enough to touch its neighbour. The rim ones have
    /// 5.86 pt, and they are what the reference makes a feature of anyway.
    static func beads(_ lattice: Lattice) -> [CGPoint] {
        let all = nodes(lattice)
        guard lattice == .fine else { return all }
        return all.filter { hypot($0.x, $0.y) >= 0.47 }
    }

    /// The front hemisphere of an icosahedron on the unit sphere, projected
    /// along +Z and halved, so the outermost sit at 0.5 before scaling.
    static let coarseNodes: [CGPoint] = [
        CGPoint(x: -0.2629, y: -0.4253),
        CGPoint(x: 0.2629, y: -0.4253),
        CGPoint(x: -0.2629, y: 0.4253),
        CGPoint(x: 0.2629, y: 0.4253),
        CGPoint(x: 0.0000, y: 0.2629),
        CGPoint(x: 0.0000, y: -0.2629),
        CGPoint(x: 0.4253, y: 0.0000),
        CGPoint(x: -0.4253, y: 0.0000),
    ]

    static let coarseStruts: [(Int, Int)] = [
        (0, 1), (0, 5), (0, 7), (1, 5), (1, 6), (2, 3), (2, 4), (2, 7), (3, 4),
        (3, 6), (4, 5), (4, 6), (4, 7), (5, 6), (5, 7),
    ]

    /// The same solid, subdivided once. 25 nodes, 60 struts.
    static let fineNodes: [CGPoint] = [
        CGPoint(x: -0.2629, y: -0.4253),
        CGPoint(x: 0.2629, y: -0.4253),
        CGPoint(x: -0.2629, y: 0.4253),
        CGPoint(x: 0.2629, y: 0.4253),
        CGPoint(x: 0.0000, y: 0.2629),
        CGPoint(x: 0.0000, y: -0.2629),
        CGPoint(x: 0.4253, y: 0.0000),
        CGPoint(x: -0.4253, y: 0.0000),
        CGPoint(x: -0.4045, y: -0.2500),
        CGPoint(x: -0.2500, y: -0.1545),
        CGPoint(x: -0.1545, y: -0.4045),
        CGPoint(x: 0.1545, y: -0.4045),
        CGPoint(x: 0.0000, y: -0.5000),
        CGPoint(x: -0.5000, y: 0.0000),
        CGPoint(x: 0.2500, y: -0.1545),
        CGPoint(x: 0.4045, y: -0.2500),
        CGPoint(x: -0.2500, y: 0.1545),
        CGPoint(x: 0.0000, y: 0.0000),
        CGPoint(x: -0.4045, y: 0.2500),
        CGPoint(x: 0.4045, y: 0.2500),
        CGPoint(x: 0.2500, y: 0.1545),
        CGPoint(x: 0.1545, y: 0.4045),
        CGPoint(x: -0.1545, y: 0.4045),
        CGPoint(x: 0.0000, y: 0.5000),
        CGPoint(x: 0.5000, y: 0.0000),
    ]

    static let fineStruts: [(Int, Int)] = [
        (0, 8), (0, 10), (0, 12), (1, 11), (1, 12), (1, 15), (2, 18), (2, 22),
        (2, 23), (3, 19), (3, 21), (3, 23), (4, 16), (4, 17), (4, 20), (4, 21),
        (4, 22), (5, 9), (5, 10), (5, 11), (5, 14), (5, 17), (6, 14), (6, 15),
        (6, 19), (6, 20), (6, 24), (7, 8), (7, 9), (7, 13), (7, 16), (7, 18),
        (8, 9), (8, 10), (8, 13), (9, 10), (9, 16), (9, 17), (10, 11), (10, 12),
        (11, 12), (11, 14), (11, 15), (13, 18), (14, 15), (14, 17), (14, 20),
        (15, 24), (16, 17), (16, 18), (16, 22), (17, 20), (18, 22), (19, 20),
        (19, 21), (19, 24), (20, 21), (21, 22), (21, 23), (22, 23),
    ]

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        // The lattice is generated on a 0.5 sphere; bring it in to the rim so
        // the nodes on the silhouette sit ON the outline rather than past it.
        let scale = Self.ballRadius(lattice) / 0.5

        func place(_ p: CGPoint) -> CGPoint {
            CGPoint(x: centre.x + p.x * scale * side,
                    y: centre.y + p.y * scale * side)
        }

        var path = Path()

        switch part {
        case .rim:
            let r = (Self.ballRadius(lattice) - Self.strutWidth(lattice) / 2) * side
            path.addEllipse(in: CGRect(x: centre.x - r, y: centre.y - r,
                                       width: r * 2, height: r * 2))

        case .struts:
            let nodes = Self.nodes(lattice)
            for (a, b) in Self.struts(lattice) {
                path.move(to: place(nodes[a]))
                path.addLine(to: place(nodes[b]))
            }

        case .nodes:
            let r = Self.nodeRadius(lattice) * side
            for node in Self.beads(lattice) {
                let c = place(node)
                path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r,
                                           width: r * 2, height: r * 2))
            }
        }
        return path
    }
}

/// The mesh as an icon.
///
/// A wireframe has no body to fill, so unlike the bone and the image glyphs
/// this one is a single colour throughout: rim and struts stroked, nodes
/// filled. Its amber sits at the same luminance as the other two contours, so
/// no glyph in a row of all three is the fainter one.
struct MeshGlyph: View {
    var tint: Color = UM.meshGlyphInk
    /// Coarse in the 13 pt hierarchy row, fine on the 26 pt canvas button.
    /// Which one a size can carry is measured, not chosen — see the note on
    /// `MeshGlyphShape`.
    var lattice: MeshGlyphShape.Lattice = .coarse

    var body: some View {
        let width = MeshGlyphShape.strutWidth(lattice)

        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                MeshGlyphShape(lattice: lattice, part: .rim)
                    .stroke(tint, lineWidth: width * side)
                MeshGlyphShape(lattice: lattice, part: .struts)
                    .stroke(tint, style: StrokeStyle(lineWidth: width * side,
                                                     lineCap: .round))
                MeshGlyphShape(lattice: lattice, part: .nodes)
                    .fill(tint)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
