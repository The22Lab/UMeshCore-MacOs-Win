import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The UltraMesh logo: a "U" drawn as a triangulated mesh, violet on the left
/// running to magenta on the right.
///
/// Vector rather than a bitmap. It is drawn at 26 pt in the toolbar and would
/// also want to be an app icon and a document icon, and a path stays sharp at
/// every one of those sizes with no @1x/@2x/@3x set to keep in step.
///
/// If the original artwork is added to the asset catalog as `ultramesh_mark`,
/// this view uses it instead — see `UltraMeshMarkView`. The path below is a
/// transcription of that artwork's topology, not a substitute for it.
struct UltraMeshMark: View {

    // Normalised to the artwork's bounding box. The mark is symmetric about
    // x = 0.5, so only the left half and the centre node are written out and
    // the right half is mirrored — a hand-typed mirror is how a logo ends up
    // subtly lopsided.
    private struct Node {
        let x: CGFloat
        let y: CGFloat
        let r: CGFloat
    }

    /// Outer contour of the U, top to bottom: the left edge and the bowl.
    private static let outerLeft: [Node] = [
        Node(x: 0.116, y: 0.052, r: 0.050),   // top-left, the largest node
        Node(x: 0.116, y: 0.331, r: 0.042),
        Node(x: 0.116, y: 0.614, r: 0.046),
        Node(x: 0.236, y: 0.846, r: 0.042),
        Node(x: 0.434, y: 0.921, r: 0.044)
    ]

    /// Inner contour, top to bottom: the left inside edge and the inner bowl.
    private static let innerLeft: [Node] = [
        Node(x: 0.335, y: 0.118, r: 0.042),
        Node(x: 0.335, y: 0.429, r: 0.042),
        Node(x: 0.372, y: 0.701, r: 0.042)
    ]

    /// The single node on the axis, at the bottom of the inner bowl.
    private static let centre = Node(x: 0.500, y: 0.752, r: 0.033)

    private static func mirrored(_ n: Node) -> Node {
        Node(x: 1 - n.x, y: n.y, r: n.r)
    }

    private static var allNodes: [Node] {
        outerLeft + innerLeft + [centre]
            + outerLeft.map(mirrored) + innerLeft.map(mirrored)
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let stroke = side * 0.028

            LinearGradient(
                colors: [Color(hex: 0x7A2FF2), Color(hex: 0xA32BEE), Color(hex: 0xFF16D1)],
                startPoint: .leading, endPoint: .trailing
            )
            .mask {
                ZStack {
                    Self.edges(in: proxy.size)
                        .stroke(style: StrokeStyle(lineWidth: stroke,
                                                   lineCap: .round, lineJoin: .round))
                    ForEach(Array(Self.allNodes.enumerated()), id: \.offset) { _, node in
                        Circle()
                            .frame(width: node.r * 2 * side, height: node.r * 2 * side)
                            .position(x: node.x * proxy.size.width,
                                      y: node.y * proxy.size.height)
                    }
                }
            }
        }
        .aspectRatio(0.95, contentMode: .fit)
        .accessibilityLabel("UltraMesh")
    }

    // MARK: - Edges

    private static func edges(in size: CGSize) -> Path {
        func point(_ n: Node) -> CGPoint {
            CGPoint(x: n.x * size.width, y: n.y * size.height)
        }

        // Bowl segments bulge away from the middle of the U so they read as one
        // arc rather than a chain of chords.
        func arc(_ path: inout Path, _ a: Node, _ b: Node, bulge: CGFloat) {
            let p = point(a), q = point(b)
            let mid = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)
            let pivot = CGPoint(x: 0.5 * size.width, y: 0.42 * size.height)
            let dx = mid.x - pivot.x, dy = mid.y - pivot.y
            let length = max(sqrt(dx * dx + dy * dy), 0.0001)
            let control = CGPoint(x: mid.x + dx / length * bulge * size.width,
                                  y: mid.y + dy / length * bulge * size.height)
            path.move(to: p)
            path.addQuadCurve(to: q, control: control)
        }

        func line(_ path: inout Path, _ a: Node, _ b: Node) {
            path.move(to: point(a))
            path.addLine(to: point(b))
        }

        var path = Path()

        let o = outerLeft, i = innerLeft, c = centre
        let mo = o.map(mirrored), mi = i.map(mirrored)

        // Left outer: two straight segments down the side, then into the bowl.
        line(&path, o[0], o[1])
        line(&path, o[1], o[2])
        arc(&path, o[2], o[3], bulge: 0.040)
        arc(&path, o[3], o[4], bulge: 0.030)

        // Right outer, mirrored.
        line(&path, mo[0], mo[1])
        line(&path, mo[1], mo[2])
        arc(&path, mo[2], mo[3], bulge: 0.040)
        arc(&path, mo[3], mo[4], bulge: 0.030)

        // The bottom of the outer bowl, crossing the axis.
        arc(&path, o[4], mo[4], bulge: 0.026)

        // Left inner: straight down, then the inner bowl into the centre node.
        line(&path, i[0], i[1])
        arc(&path, i[1], i[2], bulge: -0.018)
        arc(&path, i[2], c, bulge: -0.014)

        // Right inner, mirrored.
        line(&path, mi[0], mi[1])
        arc(&path, mi[1], mi[2], bulge: -0.018)
        arc(&path, mi[2], c, bulge: -0.014)

        // Cross-bracing: the triangles that make it a mesh rather than an
        // outline. Each one ties the inner contour to the outer.
        line(&path, o[0], i[0])   // top chord
        line(&path, i[0], o[1])
        line(&path, o[1], i[1])
        line(&path, i[1], o[2])
        line(&path, o[2], i[2])
        line(&path, i[2], o[4])
        line(&path, c, o[4])

        line(&path, mo[0], mi[0])
        line(&path, mi[0], mo[1])
        line(&path, mo[1], mi[1])
        line(&path, mi[1], mo[2])
        line(&path, mo[2], mi[2])
        line(&path, mi[2], mo[4])
        line(&path, c, mo[4])

        return path
    }
}

/// The mark, preferring the real artwork when the asset catalog has it.
///
/// Drop the original into Assets.xcassets as an image set named
/// `ultramesh_mark` and this switches to it with no code change. Until then it
/// draws the vector transcription, which is honest about being a transcription
/// rather than quietly looking like a finished decision.
struct UltraMeshMarkView: View {
    var body: some View {
        if Self.hasArtwork {
            Image("ultramesh_mark")
                .resizable()
                .scaledToFit()
                .accessibilityLabel("UltraMesh")
        } else {
            UltraMeshMark()
        }
    }

    private static let hasArtwork: Bool = {
        #if canImport(AppKit)
        return NSImage(named: "ultramesh_mark") != nil
        #elseif canImport(UIKit)
        return UIImage(named: "ultramesh_mark") != nil
        #else
        return false
        #endif
    }()
}
