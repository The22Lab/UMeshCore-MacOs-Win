import SwiftUI
import simd

/// Every layer's outline, and the selected one's handles.
///
/// ## Why this is a layer and not part of the picture
///
/// `SceneFrameRenderer.drawCardOverlay` drew these INTO the raster, and took
/// care to do it only from the two view entry points so that `renderImage` —
/// the one the export calls — could never pick up a handle. That worked by
/// keeping two entry points honest. Drawing the chrome on a separate layer
/// makes it structural instead: the export renders the same texture the canvas
/// does now, so "the file must never contain a handle" stops being a rule
/// somebody has to keep and becomes something the arrangement cannot violate.
/// It is the same move the light markers already made, for the same reason.
///
/// ## The handles stop shrinking
///
/// In the raster these were sized in IMAGE pixels, so the adaptive resolution
/// ladder shrank them exactly when the artist was dragging — which is when a
/// handle most needs to be grabbable. Here they are in view points and hold
/// their size at every rung.
struct SceneCardOutlines: View {
    let quads: [SceneFrameRenderer.LayerQuad]
    let selectedLayerID: UUID?
    /// Image pixels to view points — the same mapping the gizmo and the light
    /// markers are given, passed in rather than recomputed so an outline and a
    /// handle cannot land in different places.
    let toView: (SIMD2<Float>) -> CGPoint

    var body: some View {
        Canvas { context, _ in
            for quad in quads {
                draw(quad, in: &context)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ quad: SceneFrameRenderer.LayerQuad,
                      in context: inout GraphicsContext) {
        // THREE TO FIVE CORNERS, not four. The near plane cutting a card
        // replaces one corner with two or removes one, and assuming four is
        // what once made the selection box disappear along with the card.
        let corners = quad.corners
        guard corners.count >= 3 else { return }

        let selected = quad.id == selectedLayerID
        let ink = selected ? UM.sceneCardSelected : UM.sceneCardHandle
        let width: CGFloat = selected ? 2 : 1.2
        let side: CGFloat = selected
            ? SceneFrameRenderer.selectedHandlePx
            : SceneFrameRenderer.handlePx

        var path = Path()
        path.move(to: toView(corners[0]))
        for corner in corners.dropFirst() { path.addLine(to: toView(corner)) }
        path.closeSubpath()

        var handles = corners
        if selected {
            // Edge midpoints as well as corners, over the corners there ACTUALLY
            // are rather than over a count of four.
            for i in corners.indices {
                handles.append((corners[i] + corners[(i + 1) % corners.count]) * 0.5)
            }
        }

        // Contour first, fatter and dark; then the ink. The same trick the
        // glyphs, the mesh markers and the selection rim use, and here it is
        // what makes a lavender handle readable over lavender art and a pale
        // outline readable over the pale void.
        for pass in 0..<2 {
            let contour = pass == 0
            let rgb = contour
                ? UM.contourInk(for: ink, targetLuminance: SceneFrameRenderer.contourLuminance)
                : ink
            let alpha: CGFloat = contour
                ? SceneFrameRenderer.contourAlpha
                : (selected ? 1 : 0.92)
            let colour = Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
                .opacity(Double(alpha))
            let grow = contour ? SceneFrameRenderer.contourGrowPx : 0

            context.stroke(path, with: .color(colour), lineWidth: width + grow)
            for handle in handles {
                let point = toView(handle)
                let box = CGRect(x: point.x - (side + grow) / 2,
                                 y: point.y - (side + grow) / 2,
                                 width: side + grow, height: side + grow)
                context.fill(Path(box), with: .color(colour))
            }
        }
    }
}
