import Foundation
import CoreGraphics
import simd

/// World-space axis-aligned bounds of a scene's visible content.
///
/// This is what the exporter's "Crop" option needs: rather than rendering the
/// full viewport,
/// the exporter measures where the art actually is and frames exactly that.
/// Bounds are computed from the same skinned, deformed, world-transformed
/// vertices the renderer draws, so the measured box is the true silhouette —
/// not a loose approximation from sprite origins.
struct ContentBounds: Equatable {
    var minX: Float
    var minY: Float
    var maxX: Float
    var maxY: Float

    var width: Float { max(maxX - minX, 0) }
    var height: Float { max(maxY - minY, 0) }
    var centerX: Float { (minX + maxX) * 0.5 }
    var centerY: Float { (minY + maxY) * 0.5 }
    var isEmpty: Bool { maxX <= minX || maxY <= minY }

    static let empty = ContentBounds(minX: .greatestFiniteMagnitude,
                                     minY: .greatestFiniteMagnitude,
                                     maxX: -.greatestFiniteMagnitude,
                                     maxY: -.greatestFiniteMagnitude)

    mutating func expand(toInclude point: SIMD2<Float>) {
        guard point.x.isFinite, point.y.isFinite else { return }
        minX = Swift.min(minX, point.x)
        minY = Swift.min(minY, point.y)
        maxX = Swift.max(maxX, point.x)
        maxY = Swift.max(maxY, point.y)
    }

    mutating func formUnion(_ other: ContentBounds) {
        guard !other.isEmpty else { return }
        if isEmpty {
            self = other
            return
        }
        minX = Swift.min(minX, other.minX)
        minY = Swift.min(minY, other.minY)
        maxX = Swift.max(maxX, other.maxX)
        maxY = Swift.max(maxY, other.maxY)
    }

    /// Grows the box by `amount` on every side (crop padding).
    func inset(by amount: Float) -> ContentBounds {
        guard !isEmpty else { return self }
        return ContentBounds(minX: minX - amount, minY: minY - amount,
                             maxX: maxX + amount, maxY: maxY + amount)
    }

    // MARK: - Measurement

    /// Measures the visible content of the scene **at its current frame**.
    ///
    /// Walks exactly the geometry the renderer draws: render-ordered, non-hidden
    /// sprites, resolved meshes, skinned/deformed local vertices, transformed to
    /// world space. Sprites whose asset is missing are skipped, matching the
    /// renderer's own guard.
    @MainActor
    static func measure(scene: SceneManager, assets: AssetManager) -> ContentBounds {
        var bounds = ContentBounds.empty
        for image in scene.renderOrderedImages where !image.isHidden {
            guard let asset = assets.asset(for: image.assetID) else { continue }
            let localVertices = scene.skinnedLocalVertices(
                for: image, assetSize: asset.size, showDeformed: true)
            let worldVertices = ToolUtilities.transformedVertices(
                for: image, localVertices: localVertices)
            for vertex in worldVertices {
                bounds.expand(toInclude: vertex)
            }
        }
        return bounds
    }
}

/// The camera framing derived from measured content bounds.
///
/// Kept separate from `ContentBounds` because the exporter needs *one* framing
/// for the whole sequence: every PNG in a sequence must share dimensions, so the
/// bounds are unioned across frames first and converted once.
struct CropFraming: Equatable {
    /// World-space point the camera centers on.
    var cameraOrigin: SIMD2<Float>
    /// Output pixel width.
    var width: Int
    /// Output pixel height.
    var height: Int

    /// Converts world bounds to a pixel framing at a given zoom.
    ///
    /// - Parameters:
    ///   - bounds: unioned content bounds, already padded.
    ///   - zoom: world-units → pixels factor (the export's effective zoom).
    ///   - maxDimension: hard ceiling so a runaway rig can't request a
    ///     multi-gigapixel surface; the zoom is reduced to fit instead.
    static func from(bounds: ContentBounds,
                     zoom: Float,
                     maxDimension: Int = 16_384) -> CropFraming? {
        guard !bounds.isEmpty, zoom > 0 else { return nil }

        var effectiveZoom = zoom
        var pixelWidth = Int((bounds.width * effectiveZoom).rounded(.up))
        var pixelHeight = Int((bounds.height * effectiveZoom).rounded(.up))

        // Clamp to the ceiling by shrinking zoom, preserving aspect ratio.
        let largest = max(pixelWidth, pixelHeight)
        if largest > maxDimension {
            let shrink = Float(maxDimension) / Float(largest)
            effectiveZoom *= shrink
            pixelWidth = Int((bounds.width * effectiveZoom).rounded(.up))
            pixelHeight = Int((bounds.height * effectiveZoom).rounded(.up))
        }

        return CropFraming(
            cameraOrigin: SIMD2<Float>(bounds.centerX, bounds.centerY),
            width: max(1, pixelWidth),
            height: max(1, pixelHeight)
        )
    }
}
