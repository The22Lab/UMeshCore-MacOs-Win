import CoreGraphics
import Foundation
import ImageIO
import Metal

/// CGImage copies of the project's textures, cached, with tinting.
///
/// Extracted from `CoreGraphicsFrameSource` so the Scene renderer loads
/// through the same code — the loading order (file first, texture readback as
/// the fallback) and the tint semantics are behaviour, and two copies of
/// behaviour drift.
@MainActor
final class CGAssetImageStore {
    private var cgImageCache: [UUID: CGImage] = [:]
    private var tintedImageCache: [TintKey: CGImage] = [:]

    func cgImage(for asset: TextureAsset) throws -> CGImage {
        if let cached = cgImageCache[asset.id] { return cached }
        if let src = CGImageSourceCreateWithURL(asset.fileURL as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            cgImageCache[asset.id] = img
            return img
        }
        if let img = Self.cgImageFromTexture(asset.texture) {
            cgImageCache[asset.id] = img
            return img
        }
        throw ExportError.textureReadFailed
    }

    /// Returns `source` multiplied by an RGB tint, cached per (asset, colour).
    ///
    /// An opaque-white tint — the overwhelmingly common case — returns the
    /// original image untouched, so rigs that never use tint pay nothing. The
    /// tint's ALPHA is deliberately not applied here: it is per-draw opacity,
    /// and baking it in would make overlapping triangles of one sprite
    /// double-darken at their shared edges.
    func tinted(_ source: CGImage, rgb: SIMD4<Float>, assetID: UUID) throws -> CGImage {
        let r = CGFloat(max(0, min(1, rgb.x)))
        let g = CGFloat(max(0, min(1, rgb.y)))
        let b = CGFloat(max(0, min(1, rgb.z)))
        if r >= 0.999, g >= 0.999, b >= 0.999 { return source }

        let key = TintKey(assetID: assetID, r: Float(r), g: Float(g), b: Float(b))
        if let cached = tintedImageCache[key] { return cached }

        let w = source.width, h = source.height
        let bytesPerRow = w * 4
        let info: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
                         | CGBitmapInfo.byteOrder32Little.rawValue
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info) else {
            throw ExportError.textureReadFailed
        }

        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(source, in: rect)
        // Multiply the colour through, then restore the original coverage:
        // .multiply alone would drive the alpha of transparent pixels to 1.
        ctx.setBlendMode(.multiply)
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(rect)
        ctx.setBlendMode(.destinationIn)
        ctx.draw(source, in: rect)

        guard let out = ctx.makeImage() else { throw ExportError.textureReadFailed }
        tintedImageCache[key] = out
        return out
    }

    private struct TintKey: Hashable {
        let assetID: UUID
        let r: Float, g: Float, b: Float
    }

    private static func cgImageFromTexture(_ tex: MTLTexture) -> CGImage? {
        let w = tex.width, h = tex.height
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        tex.getBytes(&bytes, bytesPerRow: bytesPerRow,
                     from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info: UInt32 = CGImageAlphaInfo.premultipliedFirst.rawValue
                         | CGBitmapInfo.byteOrder32Little.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: cs,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
