import Foundation
import simd

/// Every size the mesh overlay is drawn and grabbed at.
///
/// One place, because the two readings had already drifted apart in the
/// making: the renderer grew the weight-paint node to 13 px while the hit test
/// kept its own 12 px, so in the one mode whose nodes are deliberately large,
/// the outer ring of every node was visible and not clickable. A node that
/// looks bigger than it is grabbable is worse than a small one — the artist
/// aims at what they can see.
///
/// Pixels, before the camera zoom divides them: the overlay is chrome and
/// keeps its weight on screen however far in or out the canvas is.
enum MeshOverlayMetrics {

    // MARK: - Nodes

    /// A plain mesh node.
    static let nodeRadiusPx: Float = 7.4
    /// ...and in weight paint, where the node carries a pie of bone colours
    /// that has to be readable at a glance.
    static let weightNodeRadiusPx: Float = 13.0

    /// The soft drop shadow, as a multiple of the node's radius.
    static let shadowScale: Float = 1.52
    /// The hard rim that gives the node its edge on artwork of any colour.
    static let rimScale: Float = 1.24
    /// Enough that the largest disc shows no flat side at 2x.
    static let segments = 24
    /// The weight-paint pie is drawn larger, so its rings get a few more.
    static let pieSegments = 28

    /// The soft ground the node sits on.
    static let shadowInk = SIMD4<Float>(0.04, 0.04, 0.05, 0.28)
    /// The hard edge. Near-opaque on purpose: a translucent rim is just a
    /// second shadow, which is what the node had before and why it smudged.
    /// Stated here rather than in each marker — it was written out twice, in
    /// `meshVertexMarker` and in `boneWeightPieMarker`, and two nodes that are
    /// meant to be the same object cannot be allowed to drift apart.
    static let rimInk = SIMD4<Float>(0.09, 0.07, 0.12, 0.94)

    // MARK: - Lines

    /// The silhouette. Heaviest, so the eye finds the outline first.
    static let contourWidthPx: Float = 3.5
    /// User-drawn internal edges.
    static let internalEdgeWidthPx: Float = 2.5
    /// The dashed triangle connections. Lightest: they are the texture, not
    /// the shape.
    static let connectionWidthPx: Float = 1.7

    // MARK: - Grabbing

    /// A little slop past the drawn edge, so aiming at a node is forgiving,
    /// and never less than the node actually drawn.
    static let grabSlopPx: Float = 2.0

    static func nodeRadiusPx(weightPainting: Bool) -> Float {
        weightPainting ? weightNodeRadiusPx : nodeRadiusPx
    }

    static func grabRadiusPx(weightPainting: Bool) -> Float {
        nodeRadiusPx(weightPainting: weightPainting) + grabSlopPx
    }
}
