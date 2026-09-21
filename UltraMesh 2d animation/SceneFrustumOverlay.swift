import SwiftUI
import simd

/// The render camera's frustum, drawn over the fly view.
///
/// Without it, flying is composing blind: the whole point of leaving the front
/// view is to see where the cards sit in depth, and that is only useful next to
/// the pyramid that says which of them the shot actually contains.
///
/// Moved out of the raster for the same reason as the card outlines — the
/// picture is a Metal texture now, and the export reads that same texture, so
/// chrome that lives in the picture is chrome that could reach a file. On its
/// own layer it cannot.
struct SceneFrustumOverlay: View {
    let geometry: SceneFrameRenderer.FrustumGeometry
    /// Image pixels to view points, the same mapping every other overlay gets.
    let toView: (SIMD2<Float>) -> CGPoint

    var body: some View {
        Canvas { context, _ in
            // Yellow on cyan is hue contrast, not luminance contrast — it reads
            // only while nothing pale sits behind it, and in a Scene a pale card
            // can. So the contour pass goes under every line, as it does for the
            // handles.
            for pass in 0..<2 {
                draw(contour: pass == 0, in: &context)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(contour: Bool, in context: inout GraphicsContext) {
        let ink = UM.sceneFrustum
        let rgb = contour
            ? UM.contourInk(for: ink, targetLuminance: SceneFrameRenderer.contourLuminance)
            : ink
        let grow: CGFloat = contour ? SceneFrameRenderer.contourGrowPx : 0

        func colour(_ alpha: CGFloat) -> Color {
            Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
                .opacity(Double(contour ? SceneFrameRenderer.contourAlpha * alpha : alpha))
        }

        func outline(_ points: [SIMD2<Float>]) -> Path {
            var path = Path()
            guard let first = points.first else { return path }
            path.move(to: toView(first))
            for point in points.dropFirst() { path.addLine(to: toView(point)) }
            path.closeSubpath()
            return path
        }

        // The shot's frame, heaviest: it is the thing being composed.
        context.stroke(outline(geometry.frame), with: .color(colour(1)), lineWidth: 2 + grow)

        if let eye = geometry.eye {
            let from = toView(eye)
            var rays = Path()
            for corner in geometry.frame {
                rays.move(to: from)
                rays.addLine(to: toView(corner))
            }
            context.stroke(rays, with: .color(colour(1)), lineWidth: 1.4 + grow)

            let radius = 4 + grow / 2
            context.fill(Path(ellipseIn: CGRect(x: from.x - radius, y: from.y - radius,
                                                width: 2 * radius, height: 2 * radius)),
                         with: .color(colour(1)))
        }

        // The far plane, faint: it says where the pyramid ends without competing
        // with the frame for attention.
        guard geometry.far.count == geometry.frame.count else { return }
        var sides = Path()
        for index in geometry.frame.indices {
            sides.move(to: toView(geometry.frame[index]))
            sides.addLine(to: toView(geometry.far[index]))
        }
        context.stroke(sides, with: .color(colour(0.45)), lineWidth: 1 + grow)
        context.stroke(outline(geometry.far), with: .color(colour(0.45)), lineWidth: 1 + grow)
    }
}
