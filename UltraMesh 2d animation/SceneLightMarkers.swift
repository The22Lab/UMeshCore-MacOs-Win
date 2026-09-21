import SwiftUI
import simd

/// A small mark on the canvas for every light in the scene.
///
/// Separate from `SceneGizmoOverlay`, and the reason is a chicken-and-egg one:
/// the gizmo only exists for the SELECTED object, so a light that is not
/// selected would have nothing on screen — and then there would be no way to
/// select it by clicking, because there is nothing to click. A light is not a
/// card; it draws no pixels of its own, so without a mark it is invisible.
///
/// So this is always on, and it is deliberately quiet: a small ring in the
/// light's own colour and nothing else. The moment a light IS selected the
/// gizmo draws its full diagram — the influence ring, the cone, the handles —
/// and this steps back to avoid drawing the same centre twice.
///
/// EDITOR CHROME. SwiftUI over the rendered image; the renderer never sees it
/// and an export cannot contain it.
struct SceneLightMarkers: View {
    let markers: [SceneFrameRenderer.LightMarker]
    /// The selected light, whose full diagram the gizmo is already drawing.
    let selectedLightID: UUID?
    /// Image pixels to view points — the same mapping the gizmo uses, passed in
    /// rather than recomputed, so a mark and a handle cannot land in different
    /// places.
    let toView: (SIMD2<Float>) -> CGPoint

    /// The drawn radius of a mark.
    static let visualRadius: CGFloat = 5.5
    /// How near a tap has to be to take one. Bigger than the mark, and bigger
    /// again on a touch screen, because the mark is deliberately small and a
    /// fingertip is not.
    static let grabRadius: CGFloat = {
        #if os(iOS)
        return 26
        #else
        return 16
        #endif
    }()

    var body: some View {
        Canvas { context, _ in
            for marker in markers where marker.id != selectedLightID {
                let p = toView(marker.screen)
                let tint = marker.isEnabled
                    ? Color(red: Double(marker.color.x), green: Double(marker.color.y),
                            blue: Double(marker.color.z))
                    : Color.white
                let opacity = marker.isEnabled ? 0.8 : 0.35
                let r = Self.visualRadius
                let ring = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r,
                                                  width: 2 * r, height: 2 * r))
                context.stroke(ring, with: .color(tint.opacity(opacity)), lineWidth: 1.4)
                let core: CGFloat = 2
                context.fill(Path(ellipseIn: CGRect(x: p.x - core, y: p.y - core,
                                                    width: 2 * core, height: 2 * core)),
                             with: .color(tint.opacity(opacity)))
            }
        }
        // The marks are a picture, not a target: the viewport owns picking, so
        // that a tap on a light and a tap on a card go through ONE decision
        // about what was hit rather than racing two gesture recognisers.
        .allowsHitTesting(false)
    }

    /// The light under a point, nearest first. Nil when none is near enough.
    ///
    /// NEAREST, not first: two lights at the same depth can overlap on screen,
    /// and taking the first in the list would mean the one you get depends on
    /// the order they were created rather than on where you clicked.
    static func pick(_ markers: [SceneFrameRenderer.LightMarker],
                     at point: CGPoint,
                     toView: (SIMD2<Float>) -> CGPoint) -> UUID? {
        var best: (UUID, CGFloat)?
        for marker in markers {
            let p = toView(marker.screen)
            let d = hypot(point.x - p.x, point.y - p.y)
            guard d <= grabRadius else { continue }
            if best == nil || d < best!.1 { best = (marker.id, d) }
        }
        return best?.0
    }
}
