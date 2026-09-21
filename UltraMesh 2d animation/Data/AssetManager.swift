import Foundation
import Combine
import Metal
import MetalKit
import CoreGraphics
import ImageIO
import CryptoKit

final class AssetManager: ObservableObject {
    @Published private(set) var assets: [TextureAsset] = []

    struct AtlasPage {
        let texture: MTLTexture
        fileprivate var nextX: Int
        fileprivate var nextY: Int
        fileprivate var rowHeight: Int
    }

    private let device: MTLDevice
    private let textureLoader: MTKTextureLoader
    private let atlasPageSize = 4096
    private let atlasPadding = 2
    /// Published, though nothing in SwiftUI observes it. The canvas sleeps when
    /// nothing is happening and wakes on `objectWillChange`, and the renderer
    /// reads this array every frame — so an atlas rebuilt without a signal
    /// would land on a sleeping canvas and not appear until something else
    /// happened to wake it. Today every rebuild also writes `assets`, which
    /// does signal, but that is an argument rather than a guarantee, and the
    /// cost of the guarantee is a handful of extra sends during an import.
    @Published private(set) var atlasPages: [AtlasPage] = []
    private var assetsByID: [UUID: TextureAsset] = [:]
    /// Content digest to the asset holding it. What stops the same picture
    /// being imported twice. Rebuilt wholesale by `restoreAssets`, so an opened
    /// project deduplicates against what it actually contains rather than
    /// against whatever the last project left behind.
    private var assetsByDigest: [String: TextureAsset] = [:]
    private var alphaCaches: [UUID: (width: Int, height: Int, data: [UInt8])] = [:]
    /// The tight box around everything that is not transparent, in UV.
    /// `nil` means the asset is entirely transparent. Cached because it is
    /// derived from `alphaCaches` and asked for on every hover sample, and it
    /// shares that cache's lifetime exactly — both are keyed by asset id and
    /// neither is evicted, so they can never describe different pixels.
    private var opaqueBoundsCaches: [UUID: SIMD4<Float>?] = [:]
    /// Small previews for the pickers. `SIMD4<Float>?` and `[UInt8]` caches
    /// next door set the pattern: built once, kept for the project's life,
    /// cleared with them on restore.
    private var thumbnailCaches: [UUID: CGImage?] = [:]

    init(device: MTLDevice) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
    }

    /// Import PNGs, and DO NOT import the same picture twice.
    ///
    /// Importing a file the project already has now returns the asset it
    /// already has, rather than a second one that happens to look identical.
    /// Reported as "lo duplica en una carpeta y eso hace que la imagen se clone
    /// cada vez que lo importes", and the chain was exactly that:
    ///
    ///   1. every import wrote a fresh copy into `ImportedAssets/` under a NEW
    ///      UUID filename, so the same PNG imported twice was two files;
    ///   2. each got its own `TextureAsset`, so it was two atlas entries and
    ///      two rows in every list;
    ///   3. `makeBundledAssets` then wrote both into the `.umesh`, so the
    ///      saved project carried two copies of identical bytes.
    ///
    /// The fix is at the top of that chain: identity comes from the CONTENT.
    /// Two files with the same bytes are the same picture, whatever they are
    /// called and wherever they were dragged from, so they get one asset and
    /// one file on disk. Nothing downstream had to learn anything.
    ///
    /// Returned in the order asked for, INCLUDING the reused ones: a caller
    /// that imports three files and places three sprites must get three
    /// answers, even when two of them name the same texture. Deduplicating the
    /// texture is not the same as dropping the request.
    func importPNGs(urls: [URL]) throws -> [TextureAsset] {
        var imported: [TextureAsset] = []
        var freshlyAdded: [TextureAsset] = []

        for url in urls {
            // Preserve the original display name before any sandbox copy
            // changes the path.
            let name = url.deletingPathExtension().lastPathComponent
            let digest = try Self.contentDigest(of: url)

            if let existing = assetsByDigest[digest] {
                imported.append(existing)
                continue
            }

            #if os(iOS)
            // iOS fileImporter URLs are security-scoped and outside the
            // sandbox. Copy into the app's documents folder first so
            // Metal/CGImage can read them — named by the digest, so the copy
            // is written once however many times the file is imported.
            let assetURL = try copiedToSandbox(url: url, digest: digest)
            #else
            let assetURL = url
            #endif
            // THE ROLE COMES FROM THE FILE NAME, by SpriteKit's own
            // convention: `hero_n.png` beside `hero.png` is that sprite's
            // relief. Matched as a suffix on the whole stem, so `hero_north`
            // stays a drawing of a compass -- see `AssetRole.inferred`.
            let role = AssetRole.inferred(fromFileName: name)?.role ?? .albedo
            var asset = try loadAsset(id: UUID(), name: name, url: assetURL,
                                      role: role)
            // A NORMAL MAP DOES NOT GO IN THE ATLAS, and the reason is not
            // space. The atlas packs unrelated artwork edge to edge, and a
            // linear sampler at a card's boundary picks up its neighbour --
            // on an albedo page that is a faint fringe, on a normal page it is
            // a band of surface pointing somewhere else entirely. It is
            // sampled standalone with raw uv instead, which also spares it
            // every rect calculation.
            if role == .albedo {
                try insertIntoAtlas(&asset)
            }
            imported.append(asset)
            freshlyAdded.append(asset)
            assetsByDigest[digest] = asset
        }

        assets.append(contentsOf: freshlyAdded)
        for asset in freshlyAdded {
            assetsByID[asset.id] = asset
        }
        return imported
    }

    /// A file's identity: SHA-256 of its bytes.
    ///
    /// Of the CONTENT, not the path or the name. The same drawing dragged in
    /// twice from two folders is one picture; two different drawings that
    /// happen to share a filename are two. Hashing is the only thing that gets
    /// both of those right.
    static func contentDigest(of url: URL) throws -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

#if os(iOS)
    private func copiedToSandbox(url: URL, digest: String) throws -> URL {
        // Request access — returns false if the URL is already in-sandbox (e.g. temp dir).
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let assetsDir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ImportedAssets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        // NAMED BY THE DIGEST, not by a fresh UUID. A UUID made every import
        // of the same file a new file on disk, which is the folder filling up
        // that was reported. The digest makes the copy idempotent: import the
        // same PNG ten times and there is one file, written the first time.
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let dest = assetsDir.appendingPathComponent("\(digest).\(ext)")
        if !FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.copyItem(at: url, to: dest)
        }
        return dest
    }
#endif

    func restoreAssets(_ savedAssets: [SavedTextureAsset]) throws {
        atlasPages.removeAll()
        assetsByDigest.removeAll()
        alphaCaches.removeAll()
        opaqueBoundsCaches.removeAll()
        thumbnailCaches.removeAll()
        var restoredAssets: [TextureAsset] = []
        for savedAsset in savedAssets {
            // THE SAVED ROLE, not the name inferred again. An artist may
            // have overridden what the name claimed, and a project must reopen
            // as it was saved rather than as its filenames would have it.
            // Missing in an older file, where everything was artwork.
            let role = savedAsset.role.flatMap(AssetRole.init(rawValue:)) ?? .albedo
            var asset = try loadAsset(
                id: savedAsset.id,
                name: savedAsset.name,
                url: URL(fileURLWithPath: savedAsset.filePath),
                role: role
            )
            if role == .albedo {
                try insertIntoAtlas(&asset)
            }
            restoredAssets.append(asset)
        }
        assets = restoredAssets
        assetsByID = Dictionary(uniqueKeysWithValues: restoredAssets.map { ($0.id, $0) })
        // Digests for what was restored, so importing a file the project
        // already contains is recognised as a duplicate rather than becoming
        // one. Best effort: a file that cannot be read here is simply not
        // deduplicated against, which is the same behaviour as before.
        for asset in restoredAssets {
            if let digest = try? Self.contentDigest(of: asset.fileURL) {
                assetsByDigest[digest] = asset
            }
        }
    }

    func asset(for id: UUID) -> TextureAsset? {
        assetsByID[id]
    }

    /// The assets an artist can place: sprites and plates, never normal maps.
    ///
    /// A normal map has no atlas entry, so a card built from one would have no
    /// UV rect to sample through -- it would draw nothing, or worse, whatever
    /// happened to be at (0, 0, 0, 0) of a page. Filtering here rather than at
    /// each picker means a picker added later cannot forget.
    var placeableAssets: [TextureAsset] {
        assets.filter(\.isPlaceable)
    }

    /// The assets that can be chosen AS a normal map.
    var normalMapAssets: [TextureAsset] {
        assets.filter { $0.role == .normal }
    }

    /// A square of this asset's alpha, for the shadow atlas.
    ///
    /// FROM THE CACHE `alphaAt` ALREADY BUILDS, which is why this is cheap:
    /// that map exists for hit-testing, is already downsampled to at most
    /// `maxAlphaCacheSide` on its long side, and is already in memory for every
    /// sprite the artist has clicked. Nothing is decoded twice.
    ///
    /// SQUARE AND SMALL ON PURPOSE. A shadow does not need the artwork's
    /// resolution -- it needs its outline, and 128 across gives that for a
    /// character while keeping the whole atlas inside a megabyte and every
    /// sample inside the cache. The stretch back to the card's real aspect
    /// happens in the shader's uv, exactly as it does for the albedo.
    ///
    /// Nearest-sampled rather than averaged. The alpha map is already a
    /// downsample of a downsample, and averaging it again turns a hard outline
    /// into a grey fringe that reads as a blurry shadow rather than a soft one.
    func alphaTile(assetID: UUID, side: Int) -> [UInt8]? {
        // Force the map to exist; `alphaAt` builds and caches it.
        _ = alphaAt(assetID: assetID, u: 0.5, v: 0.5)
        guard side > 0, let cache = alphaCaches[assetID],
              cache.width > 0, cache.height > 0 else { return nil }
        var tile = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            let sourceY = min(cache.height - 1,
                              Int((Float(y) + 0.5) / Float(side) * Float(cache.height)))
            let sourceRow = sourceY * cache.width
            let destinationRow = y * side
            for x in 0..<side {
                let sourceX = min(cache.width - 1,
                                  Int((Float(x) + 0.5) / Float(side) * Float(cache.width)))
                tile[destinationRow + x] = cache.data[sourceRow + sourceX]
            }
        }
        return tile
    }

    /// A small preview of an asset, for a picker.
    ///
    /// FROM THE FILE, NOT FROM THE `MTLTexture`. Reading a Metal texture back
    /// means a blit, a staging buffer and a wait, on the main thread, to
    /// produce something ImageIO will decode straight to the size asked for —
    /// and for a normal map the texture was loaded with `.SRGB: false`, so
    /// reading it back would need the transfer function reapplied by hand to
    /// look like the file it came from.
    ///
    /// Cached, including the failures: an asset whose file has been moved
    /// should be asked about once, not on every layout pass of a menu.
    func thumbnail(assetID: UUID, maxPixel: Int = 64) -> CGImage? {
        if let cached = thumbnailCaches[assetID] { return cached }
        guard let asset = assetsByID[assetID] else { return nil }
        let accessed = asset.fileURL.startAccessingSecurityScopedResource()
        defer { if accessed { asset.fileURL.stopAccessingSecurityScopedResource() } }
        let made = CGImageSourceCreateWithURL(asset.fileURL as CFURL, nil).flatMap {
            CGImageSourceCreateThumbnailAtIndex($0, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ] as CFDictionary)
        }
        thumbnailCaches[assetID] = made
        return made
    }

    /// The normal map whose filename pairs with this artwork's, if one exists.
    ///
    /// SpriteKit's convention: `hero.png` and `hero_n.png` belong together, and
    /// an artist who has exported that pair should not then have to say so in
    /// a menu. Called when a sprite or a plate is CREATED, so the pairing lands
    /// as an ordinary editable value -- not resolved at render time, which
    /// would silently reinstate a map the artist had deliberately cleared.
    ///
    /// Matched on the whole stem, so `hero_north` pairs with nothing.
    func pairedNormalMapID(forArtworkNamed name: String) -> UUID? {
        let wanted = name.lowercased()
        for candidate in assets where candidate.role == .normal {
            if let inferred = AssetRole.inferred(fromFileName: candidate.name),
               inferred.pairedWith.lowercased() == wanted {
                return candidate.id
            }
        }
        return nil
    }

    /// The sprite's opaque extent in UV: `(minU, minV, maxU, maxV)`.
    ///
    /// This is what stops a click in the empty half of a sheet from selecting
    /// the sprite. Picking keeps a small reach around a sprite so a thin one
    /// stays grabbable, and that reach used to be measured from the FULL
    /// rectangle — so an arm traced out of a 512×512 sheet could be selected by
    /// clicking hundreds of points from any visible pixel, because the sheet's
    /// corner was within reach even though the art was nowhere near.
    ///
    /// Measured from the same downsampled alpha map `alphaAt` uses, so the two
    /// can never disagree about which pixels count, and cached beside it.
    /// Returns nil for art that is transparent everywhere — a sprite with
    /// nothing in it is not something a click can land on.
    func opaqueBounds(assetID: UUID) -> SIMD4<Float>? {
        if let cached = opaqueBoundsCaches[assetID] { return cached }

        // Force the alpha map to exist; `alphaAt` builds and caches it.
        _ = alphaAt(assetID: assetID, u: 0.5, v: 0.5)
        guard let cache = alphaCaches[assetID] else {
            opaqueBoundsCaches[assetID] = SIMD4<Float>(0, 0, 1, 1)
            return SIMD4<Float>(0, 0, 1, 1)
        }

        var minX = cache.width, minY = cache.height
        var maxX = -1, maxY = -1
        for y in 0..<cache.height {
            let row = y * cache.width
            for x in 0..<cache.width where cache.data[row + x] > opaqueCutoff {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else {
            // `updateValue(nil, forKey:)`, not `[key] = nil`. This is a
            // dictionary of optionals: subscript-assigning nil REMOVES the key,
            // so the scan would run again on every hover for a fully
            // transparent asset instead of being remembered once.
            opaqueBoundsCaches.updateValue(nil, forKey: assetID)
            return nil
        }

        // Half a cell of margin on each side: the map is downsampled, so a
        // texel that survived sampling stands for up to `step` source pixels
        // and the true edge can be just outside the cell that found it.
        let w = Float(cache.width), h = Float(cache.height)
        let bounds = SIMD4<Float>(
            max(0, (Float(minX) - 0.5) / w),
            max(0, (Float(minY) - 0.5) / h),
            min(1, (Float(maxX) + 1.5) / w),
            min(1, (Float(maxY) + 1.5) / h)
        )
        opaqueBoundsCaches[assetID] = bounds
        return bounds
    }

    /// The alpha at or below which a texel is "not the sprite". Shared by the
    /// bounds above and by `CanvasPicking`, so one number decides everywhere.
    static let opaqueCutoffFraction: Float = 0.05
    private var opaqueCutoff: UInt8 { UInt8(Self.opaqueCutoffFraction * 255) }

    func alphaAt(assetID: UUID, u: Float, v: Float) -> Float {
        if let cached = alphaCaches[assetID] {
            let px = min(max(Int(u * Float(cached.width)), 0), cached.width - 1)
            let py = min(max(Int(v * Float(cached.height)), 0), cached.height - 1)
            return Float(cached.data[py * cached.width + px]) / 255.0
        }
        guard let asset = assetsByID[assetID],
              let cgImage = try? loadCGImage(from: asset.fileURL),
              let bytes = try? rgbaBytes(for: cgImage) else { return 1.0 }
        let sourceW = cgImage.width
        let sourceH = cgImage.height
        guard sourceW > 0, sourceH > 0 else { return 1.0 }

        // Downsample the cached alpha instead of keeping it at full resolution.
        //
        // This map exists only to answer "is this pixel transparent?" when the
        // artist clicks a sprite. At full resolution it cost width × height
        // bytes per asset, forever — a 4096² sprite pinned 16 MB of RAM, and
        // nothing ever evicted it. Capping the long side keeps every asset
        // under ~1 MB. The precision lost is sub-pixel at normal zoom and a few
        // source pixels on very large art, which is invisible for hit-testing a
        // cursor.
        let longSide = max(sourceW, sourceH)
        let step = max(1, Int((Double(longSide) / Double(Self.maxAlphaCacheSide)).rounded(.up)))
        let w = max(1, (sourceW + step - 1) / step)
        let h = max(1, (sourceH + step - 1) / step)

        var alphaData = [UInt8](repeating: 255, count: w * h)
        bytes.withUnsafeBytes { ptr in
            guard ptr.count >= sourceW * sourceH * 4 else { return }
            for y in 0..<h {
                let sourceRow = min(y * step, sourceH - 1) * sourceW
                let destRow = y * w
                for x in 0..<w {
                    let sourceIndex = sourceRow + min(x * step, sourceW - 1)
                    // rgbaBytes uses premultipliedFirst|byteOrder32Little:
                    // BGRA in memory, alpha at byte 3.
                    alphaData[destRow + x] = ptr.load(fromByteOffset: sourceIndex * 4 + 3, as: UInt8.self)
                }
            }
        }
        alphaCaches[assetID] = (width: w, height: h, data: alphaData)
        let px = min(max(Int(u * Float(w)), 0), w - 1)
        let py = min(max(Int(v * Float(h)), 0), h - 1)
        return Float(alphaData[py * w + px]) / 255.0
    }

    /// Longest side of a cached alpha map. 1024 keeps any asset's map under
    /// ~1 MB while staying far finer than a cursor's precision.
    private static let maxAlphaCacheSide = 1024

    func atlasTexture(pageIndex: Int) -> MTLTexture? {
        guard atlasPages.indices.contains(pageIndex) else { return nil }
        return atlasPages[pageIndex].texture
    }

    var atlasPageCount: Int {
        atlasPages.count
    }

    private func loadAsset(id: UUID, name: String, url: URL,
                           role: AssetRole = .albedo) throws -> TextureAsset {
        // Mipmaps off for the same reason as the atlas pages: nothing samples
        // them (the shader's sampler has no mip_filter), so they were a third
        // of this texture's memory doing nothing.
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft,
            .generateMipmaps: false
        ]
        let texture = try textureLoader.newTexture(URL: url, options: options)
        let size = SIMD2<Float>(Float(texture.width), Float(texture.height))
        return TextureAsset(
            id: id,
            name: name,
            fileURL: url,
            texture: texture,
            size: size,
            role: role,
            atlasPageIndex: nil,
            atlasUVRect: nil
        )
    }

    private func insertIntoAtlas(_ asset: inout TextureAsset) throws {
        let cgImage = try loadCGImage(from: asset.fileURL)
        let bytes = try rgbaBytes(for: cgImage)

        let pageIndex = try pageIndexForImage(width: cgImage.width, height: cgImage.height)
        let placement = try place(cgImage: cgImage, bytes: bytes, onPageAt: pageIndex)

        asset.atlasPageIndex = pageIndex
        asset.atlasUVRect = SIMD4<Float>(
            Float(placement.x) / Float(atlasPageSize),
            Float(placement.y) / Float(atlasPageSize),
            Float(cgImage.width) / Float(atlasPageSize),
            Float(cgImage.height) / Float(atlasPageSize)
        )
    }

    private func pageIndexForImage(width: Int, height: Int) throws -> Int {
        let paddedWidth = width + atlasPadding * 2
        let paddedHeight = height + atlasPadding * 2
        guard paddedWidth <= atlasPageSize, paddedHeight <= atlasPageSize else {
            throw NSError(domain: "AssetManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Image too large for atlas page"])
        }

        for index in atlasPages.indices {
            if canFit(width: width, height: height, in: atlasPages[index]) {
                return index
            }
        }

        try atlasPages.append(makeAtlasPage())
        return atlasPages.count - 1
    }

    private func canFit(width: Int, height: Int, in page: AtlasPage) -> Bool {
        let paddedWidth = width + atlasPadding
        let paddedHeight = height + atlasPadding

        var testX = page.nextX
        var testY = page.nextY
        var testRowHeight = page.rowHeight

        if testX + paddedWidth > atlasPageSize {
            testX = atlasPadding
            testY += testRowHeight + atlasPadding
            testRowHeight = 0
        }

        return testY + paddedHeight <= atlasPageSize
    }

    private func makeAtlasPage() throws -> AtlasPage {
        // No mipmaps, deliberately.
        //
        // The only sampler in the project is
        //   sampler(mag_filter::linear, min_filter::linear)
        // with no `mip_filter`, which defaults to `mip_filter::none` — so no
        // mip level was ever read. Allocating them cost a third more VRAM per
        // page (a 4096² BGRA8 page goes from ~89 MB to ~67 MB without them),
        // and generating them ran a full-page GPU blit on every image import.
        //
        // This is not an oversight to "fix" by enabling mip sampling: regions
        // are packed 2 px apart, which is enough separation for level 0 only.
        // At lower mip levels neighbouring sprites would blend into each other
        // and bleed across region edges. Mipmapping a tightly packed atlas
        // needs padding that grows with the mip chain, which the packer does
        // not produce.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: atlasPageSize,
            height: atlasPageSize,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw NSError(domain: "AssetManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create atlas page texture"])
        }

        return AtlasPage(
            texture: texture,
            nextX: atlasPadding,
            nextY: atlasPadding,
            rowHeight: 0
        )
    }

    private func place(cgImage: CGImage, bytes: Data, onPageAt pageIndex: Int) throws -> (x: Int, y: Int) {
        var page = atlasPages[pageIndex]
        let width = cgImage.width
        let height = cgImage.height

        if page.nextX + width + atlasPadding > atlasPageSize {
            page.nextX = atlasPadding
            page.nextY += page.rowHeight + atlasPadding
            page.rowHeight = 0
        }

        guard page.nextY + height + atlasPadding <= atlasPageSize else {
            throw NSError(domain: "AssetManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "Atlas page overflowed"])
        }

        let originX = page.nextX
        let originY = page.nextY
        let region = MTLRegionMake2D(originX, originY, width, height)

        bytes.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress else { return }
            page.texture.replace(region: region, mipmapLevel: 0, withBytes: baseAddress, bytesPerRow: width * 4)
        }

        page.nextX += width + atlasPadding
        page.rowHeight = max(page.rowHeight, height)
        atlasPages[pageIndex] = page

        return (originX, originY)
    }

    private func loadCGImage(from url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "AssetManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to decode image at \(url.path)"])
        }
        return image
    }

    private func rgbaBytes(for image: CGImage) throws -> Data {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let result = data.withUnsafeMutableBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                  ) else {
                return false
            }

            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        if !result {
            throw NSError(domain: "AssetManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to rasterize image bytes"])
        }

        return data
    }
}
