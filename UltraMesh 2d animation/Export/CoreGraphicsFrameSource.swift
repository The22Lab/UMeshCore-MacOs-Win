import Foundation
import CoreGraphics
import ImageIO
import Metal
import simd

extension ImageBlendMode {
    /// CoreGraphics equivalent, so an exported frame composites the way the
    /// viewport does. `.plusLighter` is CoreGraphics's name for additive.
    var cgBlendMode: CGBlendMode {
        switch self {
        case .normal:   return .normal
        case .additive: return .plusLighter
        case .multiply: return .multiply
        case .screen:   return .screen
        }
    }
}

/// Offscreen renderer that composites animated sprites into a BGRA8 buffer using
/// CoreGraphics. Renders each image mesh triangle-by-triangle so that bone
/// skinning / mesh deformation matches the Metal viewport exactly.
///
/// Pipeline per image:
///   1. Resolve mesh (quad or custom) + skinned local vertices (LBS applied)
///   2. Transform local → world via shearedWorldTransform
///   3. World → canvas (Y-up CGContext pixel coords)
///   4. Per triangle: compute affine src→dst, clip to triangle, draw image patch
@MainActor
final class CoreGraphicsFrameSource: PNGFrameSource {

    private weak var scene: SceneManager?
    private weak var assets: AssetManager?
    private let store = CGAssetImageStore()

    init(scene: SceneManager, assets: AssetManager) {
        self.scene = scene
        self.assets = assets
    }

    func renderFrame(spec: PNGFrameSpec) async throws -> Data {
        guard let scene, let assets else { throw ExportError.rendererUnavailable }

        let width = spec.width
        let height = spec.height
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
                               | CGBitmapInfo.byteOrder32Little.rawValue

        let byteCount = bytesPerRow * height
        // Owned allocation rather than Data.withUnsafeMutableBytes: the context
        // outlives the closure, and a pointer borrowed from Data is only valid
        // inside it. Copied into Data once drawing is finished.
        let pixels = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        pixels.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        defer { pixels.deallocate() }

        guard let ctx = CGContext(
            data: pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else { throw ExportError.textureReadFailed }

        // Clear background
        let c = spec.clearColor
        ctx.setFillColor(red: CGFloat(c.x), green: CGFloat(c.y),
                         blue: CGFloat(c.z), alpha: CGFloat(c.w))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Smoothing: 0 = nearest neighbour for crisp pixel art,
        // higher values enable bilinear filtering at increasing quality.
        let smoothing = max(0, min(10, spec.smoothing))
        ctx.interpolationQuality = smoothing == 0 ? .none
            : (smoothing <= 3 ? .low : (smoothing <= 7 ? .medium : .high))
        ctx.setShouldAntialias(smoothing > 0)

        // "Images" render toggle — off yields a background-only frame.
        guard spec.renderImages else { return Data(bytes: pixels, count: byteCount) }

        let zoom   = CGFloat(spec.cameraZoom ?? 1.0)
        let camOrigin = spec.cameraOrigin ?? .zero
        let halfW  = CGFloat(width)  * 0.5
        let halfH  = CGFloat(height) * 0.5

        // REVERSED, like the Editor canvas and like Scene. Index 0 is the
        // front-most sprite, so the back has to go down first. Walked forwards,
        // as this was, every export came out with its draw order inverted —
        // which is to say nothing rendered out of UltraMesh has ever matched
        // what was on the canvas when it was authored.
        for image in scene.renderOrderedImages.reversed() where !image.isHidden {
            guard let asset = assets.asset(for: image.assetID) else { continue }
            // Tint is baked into the source image (CoreGraphics has no vertex
            // colours); opacity and blend mode ride on the graphics state.
            let cgImg = try store.tinted(store.cgImage(for: asset), rgb: image.tintColor, assetID: asset.id)

            let mesh      = ToolUtilities.resolvedMesh(for: image, assetSize: asset.size)
            let localVerts = scene.skinnedLocalVertices(for: image, assetSize: asset.size, showDeformed: true)
            let worldVerts = ToolUtilities.transformedVertices(for: image, localVertices: localVerts)

            let imgW   = CGFloat(asset.size.x)
            let imgH   = CGFloat(asset.size.y)
            let uvs    = mesh.uvs
            let indices = mesh.indices

            // World → Y-up canvas coordinates
            let canvasVerts: [CGPoint] = worldVerts.map { w in
                CGPoint(
                    x: CGFloat(w.x - camOrigin.x) * zoom + halfW,
                    y: CGFloat(w.y - camOrigin.y) * zoom + halfH
                )
            }

            var i = 0
            while i + 2 < indices.count {
                let i0 = Int(indices[i]), i1 = Int(indices[i + 1]), i2 = Int(indices[i + 2])
                i += 3
                guard i0 < canvasVerts.count, i1 < canvasVerts.count, i2 < canvasVerts.count,
                      i0 < uvs.count,         i1 < uvs.count,         i2 < uvs.count else { continue }

                let dst0 = canvasVerts[i0], dst1 = canvasVerts[i1], dst2 = canvasVerts[i2]

                // UV → UV-flipped image draw space.
                // In a Y-up CGContext, ctx.draw(image, in: rect) places UV.y=0 (top of image)
                // at rect's maximum-y edge, so the effective source y = (1-v)*imgH.
                let src0 = CGPoint(x: CGFloat(uvs[i0].x) * imgW, y: (1 - CGFloat(uvs[i0].y)) * imgH)
                let src1 = CGPoint(x: CGFloat(uvs[i1].x) * imgW, y: (1 - CGFloat(uvs[i1].y)) * imgH)
                let src2 = CGPoint(x: CGFloat(uvs[i2].x) * imgW, y: (1 - CGFloat(uvs[i2].y)) * imgH)

                guard let xform = TriangleAffine.transform(src: (src0, src1, src2),
                                                          dst: (dst0, dst1, dst2)) else { continue }

                ctx.saveGState()
                ctx.setAlpha(CGFloat(image.tintColor.w))
                ctx.setBlendMode(image.blendMode.cgBlendMode)
                ctx.beginPath()
                ctx.move(to: dst0)
                ctx.addLine(to: dst1)
                ctx.addLine(to: dst2)
                ctx.closePath()
                ctx.clip()
                ctx.concatenate(xform)
                ctx.draw(cgImg, in: CGRect(x: 0, y: 0, width: imgW, height: imgH))
                ctx.restoreGState()
            }
        }

        return Data(bytes: pixels, count: byteCount)
    }

    // MARK: - Helpers

}
